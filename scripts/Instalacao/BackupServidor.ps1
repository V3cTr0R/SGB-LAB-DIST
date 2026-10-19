# Backup SQLite consistente pela API nativa; nunca copiar apenas o .db ativo.
function Assert-SgbBackupPath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Link/junction nao permitido: $cursor" }
        $cursor=Split-Path $cursor -Parent
    }
}
function Assert-SgbDatabaseTool([string]$Tool) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) { throw 'Gere a distribuicao da revisao 6 na TI: ferramenta de backup ausente.' }
    $markerFile=Join-Path (Split-Path $Tool -Parent) 'database-tool.json'
    if (-not (Test-Path -LiteralPath $markerFile)) { throw 'Pacote antigo/incompleto: database-tool.json ausente. Nenhum executavel foi iniciado.' }
    $marker=Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json
    if ($marker.Format -ne 'SGB-DATABASE-TOOL-1' -or $marker.SHA256 -ne (Get-FileHash -LiteralPath $Tool -Algorithm SHA256).Hash) { throw 'Binario/manifesto de backup divergentes. Gere uma nova distribuicao completa.' }
    $result=& $Tool --sgb-db-tool probe
    if ($LASTEXITCODE -ne 0 -or ($result -join '').Trim() -ne 'SGB-DATABASE-TOOL-1') { throw 'Binario sem suporte ao backup. Use a distribuicao completa da revisao 6.' }
}
function Invoke-SgbDatabaseBackup([string]$Tool,[string]$Source,[string]$Destination) {
    & $Tool --sgb-db-tool backup $Source $Destination | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Backup SQLite falhou. Nenhum banco existente deve ser substituido.' }
}
function New-SgbProtectedBackupDirectory {
    $path=Join-Path $env:ProgramData ('SGB-LAB\Backups\Servidor\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    Assert-SgbBackupPath $path
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    & icacls.exe $path /inheritance:r '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel proteger a pasta de backup.' }
    return $path
}
function New-SgbServerDatabaseBackup([string]$Tool,[string]$Database,[string]$Config='') {
    Assert-SgbBackupPath $Database
    $folder=New-SgbProtectedBackupDirectory
    $target=Join-Path $folder 'sgblab.db'
    Invoke-SgbDatabaseBackup -Tool $Tool -Source $Database -Destination $target
    $configHash=''
    if ($Config -and (Test-Path -LiteralPath $Config -PathType Leaf)) {
        Assert-SgbBackupPath $Config
        Copy-Item -LiteralPath $Config -Destination (Join-Path $folder 'appsettings.json') -ErrorAction Stop
        $configHash=(Get-FileHash -LiteralPath (Join-Path $folder 'appsettings.json') -Algorithm SHA256).Hash
        if ($configHash -ne (Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash) { throw 'Configuracao mudou durante o backup.' }
    }
    $manifest=[ordered]@{ Format='SGB-LAB-DatabaseBackup-1'; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Computer=$env:COMPUTERNAME; OriginalDatabase=$Database; DatabaseSHA256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash; ConfigSHA256=$configHash }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'backup.json') -Encoding UTF8
    # Read back the manifest and hash before reporting a usable backup.
    $null=Resolve-SgbDatabaseBackup -Tool $Tool -Path $folder
    Write-Host "[BACKUP VALIDADO] $folder" -ForegroundColor Green
    return $folder
}
function Resolve-SgbDatabaseBackup([string]$Tool,[string]$Path) {
    $path=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (Test-Path -LiteralPath $path -PathType Container) { $path=Join-Path $path 'sgblab.db' }
    Assert-SgbBackupPath $path
    $manifestFile=Join-Path (Split-Path $path -Parent) 'backup.json'
    if (Test-Path -LiteralPath $manifestFile) {
        $manifest=Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        if ($manifest.Format -ne 'SGB-LAB-DatabaseBackup-1' -or $manifest.DatabaseSHA256 -ne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) { throw 'Manifesto do backup ou SHA-256 divergente. Restauracao bloqueada.' }
    } else { Write-Warning 'Banco sem manifesto: a estrutura/integridade SQLite sera verificada, mas a procedencia deve ser conferida pelo administrador.' }
    & $Tool --sgb-db-tool validate $path | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Banco invalido ou estrutura SGB-LAB incompativel.' }
    return $path
}
function Restore-SgbServerDatabase([string]$Tool,[string]$Source,[string]$Destination,[string]$Config='') {
    if (Get-Service SgbLabServer -ErrorAction SilentlyContinue) { throw 'Restauracao permitida somente sem o servico instalado.' }
    Assert-SgbBackupPath $Destination
    $sourcePath=Resolve-SgbDatabaseBackup -Tool $Tool -Path $Source
    $temp=$Destination+'.restore-'+[guid]::NewGuid().ToString('N')
    $previous=$null
    try {
        Invoke-SgbDatabaseBackup -Tool $Tool -Source $sourcePath -Destination $temp
        if (Test-Path -LiteralPath $Destination) {
            # Mandatory, verified safety copy before replacing any existing database.
            $previous=New-SgbServerDatabaseBackup -Tool $Tool -Database $Destination -Config $Config
        }
        # Refuse an open database/sidecar (for example a separate development process).
        foreach ($suffix in @('','-wal','-shm','-journal')) {
            $candidate=$Destination+$suffix
            Assert-SgbBackupPath $candidate
            if (Test-Path -LiteralPath $candidate) {
                $handle=[IO.File]::Open($candidate,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                $handle.Dispose()
            }
        }
        # Sidecars belong to the OLD database and must never accompany the restored one.
        $held=@()
        $committed=$false
        try {
            foreach ($suffix in @('','-wal','-shm','-journal')) {
                $old=$Destination+$suffix
                Assert-SgbBackupPath $old
                if (Test-Path -LiteralPath $old) {
                    $saved=$old+'.before-restore-'+[guid]::NewGuid().ToString('N')
                    Move-Item -LiteralPath $old -Destination $saved -ErrorAction Stop
                    $held+=@{Old=$old;Saved=$saved}
                }
            }
            Move-Item -LiteralPath $temp -Destination $Destination -ErrorAction Stop
            $committed=$true
        } finally {
            if (-not $committed) {
                foreach ($entry in $held) { Move-Item -LiteralPath $entry.Saved -Destination $entry.Old -ErrorAction Stop }
            } else {
                foreach ($entry in $held) { Write-Host "[ORIGINAL PRESERVADO] $($entry.Saved)" }
            }
        }
        Write-Host '[OK] Banco restaurado. Configuracao HTTPS sera definida para este servidor; appsettings antigo nao e aplicado automaticamente.' -ForegroundColor Green
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}
