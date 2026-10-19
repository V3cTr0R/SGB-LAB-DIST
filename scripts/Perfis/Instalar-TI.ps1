# Perfil da estacao TI: Dashboard web por HTTPS sem privilegios SYSTEM.
[CmdletBinding()]
param([string]$ServerUrl = '')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Aceita configuracao administrada ou DNS SRV; valida TLS e identidade da API.
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'scripts\Instalacao\Descoberta.ps1')
$ServerUrl = Resolve-SgbServerUrl -RequestedUrl $ServerUrl
$uri = [Uri]$ServerUrl
$desktop=[Environment]::GetFolderPath('DesktopDirectory')
$file=Join-Path $desktop 'SGB-LAB - Dashboard TI.url'
@('[InternetShortcut]',('URL=' + $uri.AbsoluteUri.TrimEnd('/'))) | Set-Content -LiteralPath $file -Encoding ASCII
Write-Host "[OK] Atalho criado no desktop: $file" -ForegroundColor Green
Write-Host '[INFO] Abra o atalho e entre com usuario autorizado. Nenhuma senha fica no computador.'
Write-Host '[INFO] Diagnostico local na estacao TI podera ser instalado separadamente quando autorizado.'
