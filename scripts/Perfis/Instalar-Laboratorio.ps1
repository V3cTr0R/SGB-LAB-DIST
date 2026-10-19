# Instala diagnostico autocontido e Relay preservando dados locais.
[CmdletBinding()]
param([string]$ServerUrl = '', [switch]$SolicitarToken)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$admin=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra como Administrador. Nao ha elevacao oculta.' }
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (Get-Service SgbLabRelay -ErrorAction SilentlyContinue) {
    throw 'Relay ja instalado. Esta candidata exige estacao piloto sem Relay anterior; atualizacao de Relay existente ainda nao homologada. Nenhum servico foi alterado.'
}
. (Join-Path $root 'scripts\Instalacao\Descoberta.ps1')
# Preflight antes de instalar o agente: nao deixar instalacao parcial por falta de URL/token.
$ServerUrl = Resolve-SgbServerUrl -RequestedUrl $ServerUrl
$relayToken = if ($SolicitarToken) { Read-SgbRelayToken } else { Get-SgbProvisionedRelayToken -ServerUrl $ServerUrl -HostName $env:COMPUTERNAME }
Test-SgbAgentCredential -ServerUrl $ServerUrl -HostName $env:COMPUTERNAME -Token $relayToken
$payload=Join-Path $root 'payload\win-x64\SgbService.exe'
$relay=Join-Path $root 'publicado-v030\Relay\SgbRelay.exe'
if (-not (Test-Path $payload) -or -not (Test-Path $relay)) { throw 'Faltam os executaveis autocontidos. Gere a distribuicao na maquina de build usando Gerar-Distribuicao.ps1.' }
Write-Host '[1/3] Verificando WMI, Event Viewer e instalando agente...' -ForegroundColor Cyan
& (Join-Path $root 'scripts\Instalar-SgbLab.ps1') -SemInstalarSdk
if (-not (Get-Service SgbLabDiagnostico -ErrorAction SilentlyContinue)) { throw 'SgbLabDiagnostico nao encontrado apos instalacao.' }
Write-Host '[2/3] Instalando Relay e configurando HTTPS/token individual...' -ForegroundColor Cyan
& (Join-Path $root 'scripts\server\Instalar-Relay.ps1') -ServerUrl $ServerUrl -Token $relayToken -SemCompilar
if (-not (Get-Service SgbLabRelay -ErrorAction SilentlyContinue)) { throw 'SgbLabRelay nao encontrado apos instalacao.' }
Write-Host '[3/3] Validando os servicos...' -ForegroundColor Cyan
$services=Get-Service SgbLabDiagnostico,SgbLabRelay
$services | Format-Table -AutoSize
if (@($services | Where-Object Status -ne 'Running').Count -gt 0) { throw 'Um ou mais servicos nao estao em execucao.' }
& (Join-Path $root 'scripts\Perfis\Testar-Estacao.ps1')
Remove-Variable relayToken -ErrorAction SilentlyContinue
Write-Host '[OK] Servicos ativos e diagnostico confirmado no banco do servidor. Confira a maquina e a coleta no Dashboard.' -ForegroundColor Green
