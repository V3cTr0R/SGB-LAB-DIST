# Instala SgbLabRelay de forma independente; não altera SgbLabDiagnostico.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ServerUrl,
    [string]$HostName = $env:COMPUTERNAME,
    [string]$Token = '',
    [switch]$SemCompilar
)
$ErrorActionPreference = 'Stop'
$admin = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra o PowerShell como Administrador. O instalador nao abre janela extra.' }
if (-not (Get-Service SgbLabDiagnostico -ErrorAction SilentlyContinue)) { throw 'Instale primeiro o agente v0.2.2 (SgbLabDiagnostico).' }
if ($HostName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { throw 'Hostname invalido.' }
try { $uri = [Uri]$ServerUrl } catch { throw 'ServerUrl invalida.' }
if (-not $uri.IsAbsoluteUri -or ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback))) {
    throw 'HTTPS e obrigatorio na rede. HTTP aceito somente em localhost para teste.'
}
# Token deve ter sido provisionado de forma autorizada e segura; nunca solicitado em prompt.
if (-not $Token) {
    . (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\Instalacao')).Path 'Descoberta.ps1')
    $Token = Get-SgbProvisionedRelayToken -ServerUrl $uri.AbsoluteUri.TrimEnd('/') -HostName $HostName
}
if (Get-Service SgbLabRelay -ErrorAction SilentlyContinue) { throw 'Relay existente: atualizacao de binario ainda nao homologada nesta candidata.' }
. (Join-Path $PSScriptRoot '..\Instalacao\Descoberta.ps1')
Test-SgbAgentCredential -ServerUrl $uri.AbsoluteUri.TrimEnd('/') -HostName $HostName -Token $Token
$token = $Token
if ($token.Length -lt 24) { throw 'Token muito curto.' }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$bin = Join-Path $env:ProgramFiles 'SGB-LAB\Relay'
$data = Join-Path $env:ProgramData 'SGB-LAB\Relay'
$service = Get-Service -Name 'SgbLabRelay' -ErrorAction SilentlyContinue
# Arquivos sensiveis devem ser legiveis apenas por SYSTEM e Administradores.
New-Item -ItemType Directory -Force -Path $data | Out-Null
& icacls.exe $data /inheritance:r '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar ACL da pasta de credenciais.' }
$config = @{ Relay = @{ ServerUrl=$uri.AbsoluteUri.TrimEnd('/'); HostName=$HostName; ApiToken=$token; IntervaloSegundos=60; SnapshotPath=(Join-Path $env:ProgramData 'SGB-LAB\Diagnosticos\ultimo.json') } }
$file = Join-Path $data 'relaysettings.json'
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
& icacls.exe $file /inheritance:r '/grant:r' '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger token. Remova o arquivo e verifique permissoes.' }
Remove-Variable token -ErrorAction SilentlyContinue
if (-not $service) {
    $published = Join-Path $repo 'publicado-v030\Relay'
    if (-not (Test-Path (Join-Path $published 'SgbRelay.exe'))) {
        if ($SemCompilar -or -not (Test-Path (Join-Path $repo 'src\SgbRelay\SgbRelay.csproj'))) { throw 'SgbRelay.exe nao encontrado em publicado-v030\Relay.' }
        . (Join-Path $PSScriptRoot 'Prerequisitos.ps1')
        $dotnet = Ensure-DotnetSgb
        $published = Join-Path $env:TEMP ('SgbRelay-Publish-' + [Guid]::NewGuid().ToString('N'))
        & $dotnet publish (Join-Path $repo 'src\SgbRelay\SgbRelay.csproj') -c Release -r win-x64 --self-contained true -o $published '-p:PublishSingleFile=true' '-p:PublishTrimmed=false' | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Compilacao do Relay falhou.' }
    }
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -Path (Join-Path $published '*') -Destination $bin -Recurse -Force
    $exe = Join-Path $bin 'SgbRelay.exe'
    # New-Service preserva as aspas do caminho com espacos no Windows PowerShell 5.1.
    New-Service -Name 'SgbLabRelay' -BinaryPathName ('"{0}"' -f $exe) -DisplayName 'SGB-LAB Relay' -StartupType Automatic -ErrorAction Stop | Out-Null
    & sc.exe failure SgbLabRelay reset= 86400 actions= restart/60000/restart/60000/none/0 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Relay criado, mas a recuperacao automatica falhou. Configure a recuperacao antes de homologar.' }
    Start-Service SgbLabRelay
} else {
    Write-Host '[INFO] Relay instalado; atualizando SOMENTE configuracao e reiniciando o servico.'
    Restart-Service SgbLabRelay
}
Start-Sleep -Seconds 4
Get-Service SgbLabDiagnostico,SgbLabRelay | Format-Table -AutoSize
Write-Host "[OK] Configuracao protegida: $file" -ForegroundColor Green
Write-Host "[INFO] Teste com: & '`"$(Join-Path $bin 'SgbRelay.exe')`"' --once"
