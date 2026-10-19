# Atualizacao local 0.3.2-setup1 -> 0.3.3-rc.1. Windows PowerShell 5.1 x64.
# Sem -Aplicar: somente leitura. Nao cria/exclui certificados nem altera o registro do servico.
[CmdletBinding()]
param(
    [string]$Distribuicao = '',
    [Parameter(Mandatory=$true)][string]$ServerUrl,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$ThumbprintEsperado,
    [switch]$Aplicar
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-SgbJson {
    param([string]$Url)
    $request=[Net.WebRequest]::Create($Url)
    $request.Proxy=$null; $request.Timeout=5000
    $response=$request.GetResponse()
    try {
        $reader=New-Object IO.StreamReader($response.GetResponseStream())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}
function Get-SgbTlsThumbprint {
    param([uri]$Uri)
    $tcp=New-Object Net.Sockets.TcpClient
    $ssl=$null
    try {
        $pending=$tcp.BeginConnect($Uri.DnsSafeHost,$Uri.Port,$null,$null)
        try {
            if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw 'Timeout de conexao TLS.' }
            $tcp.EndConnect($pending)
        } finally { $pending.AsyncWaitHandle.Close() }
        $ssl=New-Object Net.Security.SslStream($tcp.GetStream(),$false)
        $ssl.ReadTimeout=5000; $ssl.WriteTimeout=5000
        # Sem callback permissivo: cadeia e hostname validados pelo Windows.
        $ssl.AuthenticateAsClient($Uri.DnsSafeHost)
        $cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        try { return $cert.Thumbprint } finally { $cert.Dispose() }
    } finally { if($ssl){$ssl.Dispose()}; $tcp.Close() }
}
function Assert-SgbTree {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Caminho com link/junction nao suportado: $Path" }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Link/junction nao suportado: $($child.FullName)" }
    }
}
function Copy-SgbTree {
    param([string]$From,[string]$To)
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $To -Recurse -Force
    }
}
function Assert-SgbCopy {
    param([string]$From,[string]$To)
    foreach ($file in @(Get-ChildItem -LiteralPath $From -File -Recurse -Force)) {
        $relative=$file.FullName.Substring($From.TrimEnd('\','/').Length).TrimStart('\','/')
        $copy=Join-Path $To $relative
        if (-not (Test-Path -LiteralPath $copy -PathType Leaf) -or
            (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
            throw "Copia nao conferida: $relative"
        }
    }
}
function Stop-SgbUpdateService {
    $service=Get-Service SgbLabServer
    if ($service.Status -ne 'Stopped') {
        Stop-Service SgbLabServer -ErrorAction Stop
        (Get-Service SgbLabServer).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(40))
    }
}
function Wait-SgbUpdateHealthy {
    param([string]$Version,[uri]$Uri,[string]$Thumbprint)
    $last='API ainda nao respondeu.'
    for ($attempt=0; $attempt -lt 12; $attempt++) {
        try {
            if ((Get-Service SgbLabServer).Status -ne 'Running') { throw 'Servico nao esta Running.' }
            $health=Get-SgbJson ($Uri.AbsoluteUri.TrimEnd('/')+'/api/health')
            if ($health.service -cne 'SGB-LAB' -or $health.status -cne 'ok' -or $health.version -cne $Version) { throw 'Versao/identidade da API diferente da esperada.' }
            if ((Get-SgbTlsThumbprint $Uri) -ine $Thumbprint) { throw 'O certificado apresentado mudou.' }
            $setup=Get-SgbJson ($Uri.AbsoluteUri.TrimEnd('/')+'/api/setup/status')
            if (-not $setup.configured -or $setup.localSetup) { throw 'Administrador ausente ou servico em modo de configuracao local.' }
            return
        } catch { $last=$_.Exception.Message }
        Start-Sleep -Seconds 2
    }
    throw "Validacao pos-inicio falhou: $last"
}
function Invoke-SgbUpdateTransaction {
    param([string]$Installed,[string]$Data,[string]$Published,[string]$BackupRoot,
          [uri]$Uri,[string]$Thumbprint,[string]$PreviousVersion,[string]$TargetVersion)
    $id=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $backup=Join-Path $BackupRoot $id
    $backupBin=Join-Path $backup 'Server'
    $backupData=Join-Path $backup 'Data'
    $stage=Join-Path (Split-Path $Installed -Parent) ('Server-stage-'+$id)
    $previous=Join-Path (Split-Path $Installed -Parent) ('Server-anterior-'+$id)
    $stopped=$false; $backedUp=$false; $movedOld=$false; $activated=$false; $startedNew=$false
    try {
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        & icacls.exe $backup /inheritance:r '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel proteger o backup.' }
        Write-Host '[1/5] Parando o servico para obter backup consistente do SQLite...' -ForegroundColor Cyan
        # Marcado antes da chamada: se a parada parcial falhar, a recuperacao ainda tenta religar.
        $stopped=$true
        Stop-SgbUpdateService
        Write-Host '[2/5] Copiando e conferindo binarios, configuracoes e dados...' -ForegroundColor Cyan
        Copy-SgbTree $Installed $backupBin
        Copy-SgbTree $Data $backupData
        Assert-SgbCopy $Installed $backupBin
        Assert-SgbCopy $Data $backupData
        $backedUp=$true
        # Clone preserva arquivos locais, inclusive configuracoes de ambiente.
        Copy-SgbTree $Installed $stage
        Copy-SgbTree $Published $stage
        foreach ($config in @(Get-ChildItem -LiteralPath $Installed -Filter 'appsettings*.json' -File)) {
            Copy-Item -LiteralPath $config.FullName -Destination $stage -Force
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $Published -Recurse -File)) {
            $rel=$file.FullName.Substring($Published.TrimEnd('\','/').Length).TrimStart('\','/')
            if ($rel -match '^appsettings[^\\/]*\.json$') { continue }
            if ((Get-FileHash -LiteralPath (Join-Path $stage $rel)).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw "Stage divergente: $rel" }
        }
        foreach ($config in @(Get-ChildItem -LiteralPath $Installed -Filter 'appsettings*.json' -File)) {
            if ((Get-FileHash -LiteralPath $config.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $stage $config.Name)).Hash) { throw 'Configuracao nao preservada.' }
        }
        Write-Host '[3/5] Ativando os arquivos publicados...' -ForegroundColor Cyan
        Move-Item -LiteralPath $Installed -Destination $previous
        $movedOld=$true
        Move-Item -LiteralPath $stage -Destination $Installed
        $activated=$true
        Write-Host '[4/5] Reiniciando o servico...' -ForegroundColor Cyan
        $startedNew=$true
        Start-Service SgbLabServer
        (Get-Service SgbLabServer).WaitForStatus('Running',[TimeSpan]::FromSeconds(40))
        Write-Host '[5/5] Validando versao, administrador e certificado HTTPS...' -ForegroundColor Cyan
        Wait-SgbUpdateHealthy $TargetVersion $Uri $Thumbprint
        Write-Host "[OK] API $TargetVersion em $($Uri.AbsoluteUri); mesmo certificado e administrador configurado." -ForegroundColor Green
        Write-Host "[BACKUP] $backup"
        Write-Host "[BINARIOS ANTERIORES] $previous"
        Write-Host '[PROXIMO] Abra o Dashboard HTTPS e confira login, inventario e mapeamentos AD.'
    } catch {
        $reason=$_.Exception.Message
        if ($stopped) {
            Write-Warning "Atualizacao interrompida: $reason. Tentando recuperar a versao anterior."
            try {
                Stop-SgbUpdateService
                if ($activated) {
                    # Mantem arquivos novos para diagnostico; nao apaga a arvore anterior.
                    Move-Item -LiteralPath $Installed -Destination ($Installed+'-falha-'+$id)
                }
                if ($movedOld) { Move-Item -LiteralPath $previous -Destination $Installed }
                if ($startedNew -and $backedUp) {
                    # Preserva tambem dados que a nova API possa ter escrito antes da falha.
                    Move-Item -LiteralPath $Data -Destination ($Data+'-falha-'+$id)
                    Copy-SgbTree $backupData $Data
                    Assert-SgbCopy $backupData $Data
                    & icacls.exe $Data /inheritance:r '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger dados restaurados.' }
                }
                Start-Service SgbLabServer
                (Get-Service SgbLabServer).WaitForStatus('Running',[TimeSpan]::FromSeconds(40))
                Wait-SgbUpdateHealthy $PreviousVersion $Uri $Thumbprint
                Write-Warning "[ROLLBACK OK] Versao $PreviousVersion restaurada. Backup: $backup"
            } catch { throw "ROLLBACK NAO CONFIRMADO: $($_.Exception.Message). Erro inicial: $reason. Backup: $backup. Nao remova os arquivos de recuperacao." }
        }
        throw "Atualizacao nao concluida: $reason"
    } finally {
        # Nenhum backup ou arvore de falha e removido automaticamente.
        if (Test-Path -LiteralPath $stage) { Write-Host "[STAGE PRESERVADO] $stage" }
    }
}

# PRECHECKS: nenhuma escrita ate a chamada transacional com -Aplicar.
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) { throw 'Requer Windows x64.' }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra o PowerShell como Administrador.' }
if (-not $Distribuicao) { $Distribuicao=$PSScriptRoot }
$Distribuicao=(Resolve-Path -LiteralPath $Distribuicao).Path
$published=Join-Path $Distribuicao 'publicado-v030\Server'
$metadata=Get-Content -LiteralPath (Join-Path $Distribuicao 'release.json') -Raw | ConvertFrom-Json
$targetVersion='0.3.3-rc.1'
if ($metadata.version -cne $targetVersion) { throw 'Este atualizador aceita somente a distribuicao 0.3.3-rc.1.' }
$newExe=Join-Path $published 'SgbServer.exe'
foreach ($file in @($newExe,(Join-Path $published 'wwwroot\index.html'),(Join-Path $published 'appsettings.json'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Distribuicao incompleta: $file" }
}
$productVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($newExe).ProductVersion
if (-not $productVersion -or $productVersion.Split('+')[0] -cne $targetVersion) { throw "Executavel nao identifica a versao $targetVersion. Gere novamente na TI." }
$service=Get-CimInstance Win32_Service -Filter "Name='SgbLabServer'"
if (-not $service -or $service.State -ne 'Running' -or $service.StartName -ne 'LocalSystem') { throw 'Requer SgbLabServer Running como LocalSystem.' }
$installed=Join-Path $env:ProgramFiles 'SGB-LAB\Server'
$installedExe=Join-Path $installed 'SgbServer.exe'
# Escopo conhecido: instalaçao padrao sem parametros adicionais.
if ($service.PathName.Trim().Trim('"') -ine $installedExe) { throw 'Caminho/argumentos do servico fora do escopo deste atualizador. Nenhuma alteracao feita.' }
$data=Join-Path $env:ProgramData 'SGB-LAB\Server'
$dbPath=Join-Path $data 'sgblab.db'
$effectiveDb=[Environment]::GetEnvironmentVariable('SGB_DB_PATH','Machine')
$registry=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\SgbLabServer'
$entry=$registry.PSObject.Properties['Environment']
if ($entry) {
    foreach ($line in @($entry.Value)) { if ($line -match '^SGB_DB_PATH=(.*)$') { $effectiveDb=$Matches[1] } }
}
if ($effectiveDb -and [IO.Path]::GetFullPath($effectiveDb) -ine [IO.Path]::GetFullPath($dbPath)) { throw 'Banco em caminho personalizado: backup precisa de revisao. Nenhuma alteracao feita.' }
if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { throw 'Banco esperado ausente; atualizacao bloqueada.' }
$config=Get-Content -LiteralPath (Join-Path $installed 'appsettings.json') -Raw | ConvertFrom-Json
$endpoint=$config.Kestrel.Endpoints.Https
$certificate=$endpoint.Certificate
if ($certificate.Store -ine 'My' -or $certificate.Location -ine 'LocalMachine') { throw 'Configuracao de certificado fora do escopo suportado.' }
if ($certificate.PSObject.Properties['Path'] -and $certificate.Path) { throw 'Certificado em arquivo exige revisao especifica.' }
$uri=[uri]$ServerUrl
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'Informe a URL HTTPS raiz com nome DNS.' }
$binding=[uri]$endpoint.Url
if ($binding.Port -ne $uri.Port) { throw 'Porta divergente do endpoint instalado.' }
$localIps=@(Get-NetIPAddress -AddressFamily IPv4 | Select-Object -ExpandProperty IPAddress)
if ($binding.Host -notin $localIps) { throw 'Endpoint nao pertence a uma interface local.' }
$resolved=@([Net.Dns]::GetHostAddresses($uri.DnsSafeHost) | ForEach-Object { $_.ToString() })
if ($binding.Host -notin $resolved) { throw 'DNS nao aponta para o endpoint instalado.' }
$owned=@(Get-NetTCPConnection -State Listen -LocalPort $uri.Port | Where-Object { $_.OwningProcess -eq $service.ProcessId })
if ($owned.Count -eq 0) { throw 'Porta HTTPS nao pertence ao processo do servico.' }
$thumbprint=$ThumbprintEsperado.ToUpperInvariant()
if ((Get-SgbTlsThumbprint $uri) -cne $thumbprint) { throw 'Certificado ativo diferente do informado. Nenhuma alteracao feita.' }
$certPath='Cert:\LocalMachine\My\'+$thumbprint
$cert=Get-Item -LiteralPath $certPath
if (-not $cert.HasPrivateKey) { throw 'Certificado ativo sem chave privada no armazenamento local.' }
$health=Get-SgbJson ($uri.AbsoluteUri.TrimEnd('/')+'/api/health')
if ($health.service -cne 'SGB-LAB' -or $health.status -cne 'ok') { throw 'API atual nao esta saudavel.' }
if ($health.version -ceq $targetVersion) { Write-Host '[OK] A versao de destino ja esta ativa; nada foi alterado.'; return }
if ($health.version -cne '0.3.2-setup1') { throw 'Origem fora da versao revisada: exige analise antes de atualizar.' }
$setup=Get-SgbJson ($uri.AbsoluteUri.TrimEnd('/')+'/api/setup/status')
if (-not $setup.configured -or $setup.localSetup) { throw 'Administrador/configuracao de producao nao confirmado.' }
foreach ($tree in @($published,$installed,$data)) { Assert-SgbTree $tree }
Write-Host "[OK] Origem: $($health.version) | Destino: $targetVersion | Banco: $dbPath" -ForegroundColor Green
Write-Host "[OK] HTTPS validado; certificado ativo: $thumbprint" -ForegroundColor Green
Write-Host '[INFO] Configuracao por Subject sera preservada; certificados duplicados nao serao removidos.'
if (-not $Aplicar) { Write-Host '[DIAGNOSTICO OK] Nenhum arquivo ou servico alterado. Use -Aplicar para iniciar a atualizacao com breve indisponibilidade.' -ForegroundColor Cyan; return }
$backupRoot=Join-Path $env:ProgramData 'SGB-LAB\Backups\Server'
Invoke-SgbUpdateTransaction -Installed $installed -Data $data -Published $published -BackupRoot $backupRoot -Uri $uri -Thumbprint $thumbprint -PreviousVersion $health.version -TargetVersion $targetVersion
