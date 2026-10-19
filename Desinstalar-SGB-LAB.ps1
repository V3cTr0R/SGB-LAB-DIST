# Windows PowerShell 5.1. Sem -Aplicar, somente apresenta o plano.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Laboratorio','Servidor','TI')][string]$Perfil,
    [switch]$Aplicar
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Execute no Windows da maquina a desinstalar.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use PowerShell de 64 bits.' }
$items=@()
if ($Perfil -eq 'Laboratorio') {
    $items=@(@{Name='SgbLabRelay';Folder='Relay';Exe='SgbRelay.exe'},@{Name='SgbLabDiagnostico';Folder='Agent';Exe='SgbService.exe'})
} elseif ($Perfil -eq 'Servidor') {
    $items=@(@{Name='SgbLabServer';Folder='Server';Exe='SgbServer.exe'})
}
$base=Join-Path $env:ProgramFiles 'SGB-LAB'
# Rejeitar junctions antes de mover qualquer pasta, inclusive nos ancestrais.
function Assert-SgbPlainPath([string]$Path) {
    $cursor=$Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Link/junction nao permitido: $cursor" }
        }
        $cursor=Split-Path -Path $cursor -Parent
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($entry in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Link/junction nao permitido: $($entry.FullName)" }
        }
    }
}
foreach ($item in $items) {
    $dir=Join-Path $base $item.Folder
    Assert-SgbPlainPath $dir
    $svc=Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $item.Name)
    if ($svc) {
        $expected=Join-Path $dir $item.Exe
        $pattern='^\s*"'+[regex]::Escape($expected)+'"(?:\s|$)'
        if ($svc.PathName -notmatch $pattern -and $svc.PathName -ine $expected) { throw "Caminho inesperado para $($item.Name). Nenhuma alteracao realizada." }
    }
    Write-Host "[PLANO] Remover servico $($item.Name); arquivar pasta $dir se existir."
}
$shortcut=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'SGB-LAB - Dashboard TI.url'
if ($Perfil -eq 'Servidor') { Write-Host '[PLANO] Parar servidor, criar backup SQLite validado em ProgramData\SGB-LAB\Backups\Servidor e somente depois remover o servico.' }
if ($Perfil -eq 'TI') { Write-Host "[PLANO] Remover somente o atalho do usuario atual: $shortcut" }
Write-Host '[PRESERVADO] Banco, diagnosticos, tokens/configuracoes em ProgramData, certificados, regras de firewall e cadastro remoto.'
if (-not $Aplicar) { Write-Host '[PREVIA] Nenhuma alteracao. Use -Aplicar para executar; -Aplicar -WhatIf para simular.'; return }
if (-not $PSCmdlet.ShouldProcess("$env:COMPUTERNAME / $Perfil",'Desinstalar SGB-LAB e preservar dados')) { return }
if ($Perfil -eq 'TI') {
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    Write-Host '[OK] Perfil TI removido para o usuario atual.'
    return
}
$admin=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra o PowerShell como Administrador.' }
$database=Join-Path $env:ProgramData 'SGB-LAB\Server\sgblab.db'
$tool=Join-Path $PSScriptRoot 'publicado-v030\Server\SgbServer.exe'
if ($Perfil -eq 'Servidor') {
    . (Join-Path $PSScriptRoot 'scripts\Instalacao\BackupServidor.ps1')
    Assert-SgbDatabaseTool $tool
    $serviceKey='HKLM:\SYSTEM\CurrentControlSet\Services\SgbLabServer'
    if (Test-Path $serviceKey) {
        $props=Get-ItemProperty -LiteralPath $serviceKey
        if ($props.PSObject.Properties['Environment']) {
            foreach ($value in @($props.Environment)) {
                if ($value -like 'SGB_DB_PATH=*') { $database=$value.Substring(12) }
            }
        }
    }
    if (-not [IO.Path]::IsPathRooted($database)) { throw 'Caminho do banco deve ser absoluto.' }
    Assert-SgbBackupPath $database
    if (-not (Test-Path -LiteralPath $database -PathType Leaf)) { throw 'Banco do servidor ausente. Desinstalacao bloqueada: nao e possivel criar backup.' }
}
# Arquivo protegido no mesmo volume dos binarios: Move-Item preserva todo o conteudo.
$archive=Join-Path $base ('Desinstalados\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
Assert-SgbPlainPath (Join-Path $base 'Desinstalados')
New-Item -ItemType Directory -Path $archive -Force | Out-Null
& icacls.exe $archive /inheritance:r '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger arquivo de recuperacao. Servicos nao foram alterados.' }
Write-Host "[ARQUIVO DE RECUPERACAO] $archive"
$restartOnFailure=$false
try {
    if ($Perfil -eq 'Servidor') {
        $current=Get-Service SgbLabServer -ErrorAction SilentlyContinue
        $restartOnFailure=($current -and $current.Status -eq 'Running')
        if ($current) { $current.Dispose() }
    }
# Parar todos antes de remover qualquer registro ou mover arquivos.
foreach ($item in $items) {
    $svc=Get-Service -Name $item.Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $item.Name -ErrorAction Stop
        $svc.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
    }
    if ($svc) { $svc.Dispose() }
}
    if ($Perfil -eq 'Servidor') {
        $backupFolder=New-SgbServerDatabaseBackup -Tool $tool -Database $database -Config (Join-Path $base 'Server\appsettings.json')
        Write-Host "[RECUPERACAO] Na reinstalacao, informe esta pasta: $backupFolder" -ForegroundColor Cyan
    }
} catch {
    if ($restartOnFailure) {
        try { Start-Service SgbLabServer -ErrorAction Stop; Write-Warning 'Backup/parada falhou. Servidor reiniciado; desinstalacao cancelada.' }
        catch { Write-Warning "Nao foi possivel reiniciar SgbLabServer: $($_.Exception.Message)" }
    }
    throw
}
foreach ($item in $items) {
    if (Get-Service -Name $item.Name -ErrorAction SilentlyContinue) {
        & sc.exe delete $item.Name | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Falha ao remover $($item.Name). Operacao parcial; arquivos preservados." }
        if (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $item.Name)) { throw 'Servico marcado para exclusao. Feche services.msc, reinicie se necessario e execute novamente. Arquivos preservados.' }
    }
    $dir=Join-Path $base $item.Folder
    if (Test-Path -LiteralPath $dir) { Move-Item -LiteralPath $dir -Destination (Join-Path $archive $item.Folder) -ErrorAction Stop }
}
Write-Host "[OK] Perfil $Perfil desinstalado. Binarios/configuracoes arquivados em $archive. Dados operacionais preservados."
Write-Host '[INFO] Revogue o token da estacao no Dashboard se ela foi retirada de uso. A remocao local nao revoga credenciais remotas.'
