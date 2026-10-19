# SGB-LAB v0.2.2: atualizacao no MESMO processo PowerShell.
# Não inicia nova janela e não usa Start-Process -Wait.
[CmdletBinding()]
param([switch]$SemInstalarSdk)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-IsAdministrator)) {
    throw 'Abra o Windows PowerShell com Executar como administrador e execute novamente. Nenhuma janela adicional foi aberta.'
}
if ($null -eq (Get-Service -Name 'SgbLabDiagnostico' -ErrorAction SilentlyContinue)) {
    throw 'SgbLabDiagnostico nao instalado; use Instalar-SgbLab.ps1 para a primeira instalacao.'
}
$instalador = Join-Path $PSScriptRoot 'Instalar-SgbLab.ps1'
Write-Host '[UPGRADE] Executando no terminal atual (sem abrir outra janela).'
# Invocação direta. O script instalador mantém o próprio tratamento de rollback.
& $instalador -SemInstalarSdk:$SemInstalarSdk
