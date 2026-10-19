# SGB-LAB v0.3.2: instalador de servidor Windows separado, com primeiro acesso local.
# Requer binario autocontido e React publicado; nunca cria uma CA ou altera o AD.
[CmdletBinding()]
param(
  [string]$BackupBanco = '',
  [string]$ServerIp = '',
  [string]$RedePermitida = '',
  [ValidateRange(1024,65535)][int]$Porta = 5443,
  [switch]$PermitirBuildLocal,
  [switch]$NaoCriarCertificadoLocal
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$admin=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Execute como Administrador. Nao sera aberta nova janela.' }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'Windows x64 obrigatorio.' }
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bin=Join-Path $root 'publicado-v030\Server'
$exe=Join-Path $bin 'SgbServer.exe'
$index=Join-Path $bin 'wwwroot\index.html'
if (-not (Test-Path $exe) -or -not (Test-Path $index)) {
  if (-not $PermitirBuildLocal -or -not (Test-Path (Join-Path $root 'src\SgbServer\SgbServer.csproj'))) { throw 'Pacote publicado ausente. Gere o pacote em Gerar-Distribuicao.ps1 na maquina de build ou use -PermitirBuildLocal no projeto-fonte.' }
  & (Join-Path $root 'scripts\server\Publicar-v030.ps1') | Out-Host
  if (-not (Test-Path $exe) -or -not (Test-Path $index)) { throw 'Falha ao publicar API/React.' }
}
$existing=Get-Service SgbLabServer -ErrorAction SilentlyContinue
if ($existing) { throw 'SgbLabServer ja instalado. Este instalador nao sobrescreve a versao ativa; utilize o atualizador versionado.' }
. (Join-Path $root 'scripts\Instalacao\BackupServidor.ps1')
Assert-SgbDatabaseTool $exe
if (-not $BackupBanco) {
    $choice=Read-Host 'Deseja recuperar um backup de banco antigo? [S/N] (ENTER=N)'
    if ($choice -match '^(?i:s|sim)$') {
        $BackupBanco=(Read-Host 'Informe o caminho da pasta de backup ou do arquivo .db').Trim().Trim('"')
        if (-not $BackupBanco) { throw 'Caminho de backup nao informado. Instalacao cancelada.' }
    } elseif ($choice -and $choice -notmatch '^(?i:n|nao|não)$') { throw 'Resposta invalida. Instalacao cancelada.' }
}
if ($BackupBanco) { $BackupBanco=Resolve-SgbDatabaseBackup -Tool $exe -Path $BackupBanco }
foreach ($portToCheck in @(5080,$Porta)) {
  if (Get-NetTCPConnection -State Listen -LocalPort $portToCheck -ErrorAction SilentlyContinue) {
    throw "Porta $portToCheck ocupada. Encerre o DEV com Iniciar-TI.ps1 -Acao Parar antes do piloto."
  }
}
# Descoberta somente leitura; emissao local feita por modulo separado e apenas
# durante a instalacao efetiva (nunca em -SomenteDiagnostico).
. (Join-Path $root 'scripts\Instalacao\Descoberta.ps1')
. (Join-Path $root 'scripts\Instalacao\CertificadoLocal.ps1')
if ($RedePermitida -and -not (Test-SgbPrivateCidr -Cidr $RedePermitida)) { throw 'RedePermitida deve ser um CIDR inteiramente privado, com prefixo valido.' }
$fqdn = Get-SgbLocalFqdn
$ServerIp = Resolve-SgbLocalServerIp -Fqdn $fqdn -RequestedIp $ServerIp
$matching = @(Get-SgbMatchingHostnameCertificates -Fqdn $fqdn)
if ($matching.Count -eq 0 -and -not $NaoCriarCertificadoLocal) {
  $null = New-SgbLocalHttpsCertificate -Fqdn $fqdn
}
# Se havia SAN compativel, mas o certificado nao e valido/confiavel,
# Find-SgbServerCertificate falhara SEM criar um substituto.
$selected = Find-SgbServerCertificate -Fqdn $fqdn
$cert = $selected.Certificate
$certStore = $selected.Store
$certSubject = $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
Write-Host "[AUTO] FQDN: $fqdn | IPv4: $ServerIp | Certificado: $($cert.Thumbprint) | Store: $certStore" -ForegroundColor Green
# O FQDN selecionado precisa resolver para este servidor para que a validacao HTTPS funcione.
# A chave privada precisa ser acessivel por LocalSystem, identidade padrao de SgbLabServer.

$serverDir=Join-Path $env:ProgramFiles 'SGB-LAB\Server'
$dataDir=Join-Path $env:ProgramData 'SGB-LAB\Server'
$logs=Join-Path $dataDir 'Logs'
Assert-SgbBackupPath $dataDir
Assert-SgbBackupPath $serverDir
New-Item -ItemType Directory -Force -Path $serverDir,$dataDir,$logs | Out-Null
& icacls.exe $dataDir /inheritance:r '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger o banco e os logs.' }
$database=Join-Path $dataDir 'sgblab.db'
if ($BackupBanco) {
    if (Test-Path -LiteralPath $database) {
        Write-Host '[ATENCAO] Ja existe banco local. Ele recebera backup antes da substituicao.' -ForegroundColor Yellow
        if ((Read-Host 'Digite RESTAURAR para substituir pelo backup escolhido') -cne 'RESTAURAR') { throw 'Restauracao cancelada; banco existente preservado.' }
    }
    Restore-SgbServerDatabase -Tool $exe -Source $BackupBanco -Destination $database -Config (Join-Path $serverDir 'appsettings.json')
} elseif (Test-Path -LiteralPath $database) {
    Write-Host '[BANCO] Mantendo banco local existente (nao sera criada uma base vazia).'
}
Copy-Item -Path (Join-Path $bin '*') -Destination $serverDir -Recurse -Force
$installed=Join-Path $serverDir 'SgbServer.exe'
# Bootstrap local: sem endpoint HTTPS no appsettings durante a ativacao inicial.
$configFile=Join-Path $serverDir 'appsettings.json'
$settings=Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$settings.PSObject.Properties.Remove('Kestrel')
$settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configFile -Encoding UTF8
$savedEnvironment = @{}
foreach ($name in @('ASPNETCORE_ENVIRONMENT','DOTNET_ENVIRONMENT','ASPNETCORE_URLS','ASPNETCORE_CONTENTROOT','SGB_DB_PATH')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$env:SGB_DB_PATH = Join-Path $dataDir 'sgblab.db'
$env:ASPNETCORE_CONTENTROOT = $serverDir
$env:DOTNET_ENVIRONMENT='Development'
$env:ASPNETCORE_ENVIRONMENT='Development' 
$env:ASPNETCORE_URLS='http://127.0.0.1:5080'
Write-Host '[SETUP] Verificando se o primeiro administrador ja foi cadastrado localmente...' -ForegroundColor Cyan
$proc=$null
try {
$proc=Start-Process -FilePath $installed -WorkingDirectory $serverDir -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logs 'setup.out.log') -RedirectStandardError (Join-Path $logs 'setup.err.log')
  for ($attempt=0; $attempt -lt 30; $attempt++) {
    if ($proc.HasExited) { break }
    try {
      $probe=[Net.WebRequest]::Create('http://127.0.0.1:5080/api/setup/status')
      $probe.Proxy=$null; $probe.Timeout=1000
      $probeResponse=$probe.GetResponse(); $probeResponse.Close(); break
    } catch { Start-Sleep -Seconds 1 }
  }
  if ($proc.HasExited) { throw "API encerrou. Confira $logs\setup.err.log" }
  $url='http://127.0.0.1:5080/api/setup/status'
  $req=[Net.WebRequest]::Create($url);$req.Proxy=$null;$req.Timeout=4000
  $resp=$req.GetResponse()
  try { $reader=New-Object IO.StreamReader($resp.GetResponseStream());$status=($reader.ReadToEnd()|ConvertFrom-Json) } finally { $resp.Close() }
  if (-not $status.configured) {
    $code=Get-Content (Join-Path $logs 'setup.out.log') -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Codigo de ativacao temporario' } | Select-Object -Last 1
    if ($code) { Write-Host "[ATIVACAO] $code" -ForegroundColor Yellow }
    Write-Host '[ACAO AUTORIZADA] Crie a primeira conta em http://127.0.0.1:5080 no navegador do servidor.' -ForegroundColor Yellow
    Read-Host 'Apos concluir o cadastro do administrador, pressione ENTER'
    $req=[Net.WebRequest]::Create($url);$req.Proxy=$null;$req.Timeout=4000
    $resp=$req.GetResponse()
    try { $reader=New-Object IO.StreamReader($resp.GetResponseStream());$status=($reader.ReadToEnd()|ConvertFrom-Json) } finally { $resp.Close() }
  } else { Write-Host '[AUTO] Administrador existente confirmado; sem nova interacao.' -ForegroundColor Green }
  if (-not $status.configured) { throw 'Primeiro acesso ainda nao concluido; instalacao abortada antes de criar o servico.' }
} finally {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
# Escreva HTTPS SOMENTE apos encerrar bootstrap HTTP.
$settings | Add-Member -NotePropertyName Kestrel -NotePropertyValue @{
  Endpoints=@{Https=@{Url="https://${ServerIp}:$Porta";Certificate=@{Subject=$certSubject;Store=$certStore;Location='LocalMachine';AllowInvalid=$false}}}
} -Force
$settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configFile -Encoding UTF8
New-Service -Name 'SgbLabServer' -DisplayName 'SGB-LAB Servidor Central' -BinaryPathName ('"'+$installed+'" --contentRoot "'+$serverDir+'" --environment Production') -StartupType Automatic | Out-Null
& sc.exe failure SgbLabServer reset= 86400 actions= restart/60000/restart/60000/none/0 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar recuperacao do servico SgbLabServer.' }
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SgbLabServer' -Name Environment -PropertyType MultiString -Value @(('SGB_DB_PATH=' + (Join-Path $dataDir 'sgblab.db')), 'ASPNETCORE_ENVIRONMENT=Production', 'DOTNET_ENVIRONMENT=Production') -Force | Out-Null
Start-Service SgbLabServer
(Get-Service SgbLabServer).WaitForStatus('Running',[TimeSpan]::FromSeconds(30))
$ready=$false
for ($i=0; $i -lt 20; $i++) {
  if (Test-SgbServerHttps -ServerUrl "https://${fqdn}:$Porta") { $ready=$true; break }
  if ((Get-Service SgbLabServer).Status -ne 'Running') { break }
  Start-Sleep -Seconds 1
}
if (-not $ready) {
  Write-Warning 'HTTPS nao passou na verificacao TLS/identidade. Tentando parar o servico recem-criado.'
  try { Stop-Service SgbLabServer -ErrorAction Stop } catch { Write-Warning "Nao foi possivel parar o servico: $($_.Exception.Message)" }
  throw "Servico criado mas HTTPS ${fqdn}:$Porta nao validado. Nao libere em producao."
}

if ($RedePermitida) {
  New-NetFirewallRule -DisplayName 'SGB-LAB HTTPS privado' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Porta -Profile Domain,Private -RemoteAddress $RedePermitida | Out-Null
  Write-Host "[FIREWALL] Porta $Porta permitida somente para $RedePermitida" -ForegroundColor Green
} else { Write-Warning 'Nenhuma excecao de firewall criada; informe -RedePermitida depois de validar a subrede autorizada.' }
Write-Host "[OK] Servico SgbLabServer instalado em https://${fqdn}:$Porta" -ForegroundColor Green
Write-Host '[INFO] Verifique DNS, cadeia do certificado e acesso HTTPS de outras maquinas antes da implantacao.'
