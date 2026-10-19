# Primeiro teste sem instalar o Windows Service. Executar no Windows:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Testar-SgbLab.ps1
[CmdletBinding()]
param([switch]$SemInstalarSdk)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
try {
    Assert-WindowsX64
    $ok = Test-WindowsDependencies
    if (-not $ok) {
        Write-Warning 'Algumas verificacoes do Windows falharam; rode o instalador como Administrador para tentar reparar o WMI.'
    }
    $payload = Get-SgbPayload -NoSdkInstall:$SemInstalarSdk
    $exe = Join-Path $payload 'SgbService.exe'
    Invoke-SgbPreflight -Exe $exe
    Write-Host '[TESTE] Coletando hardware e BugCheck dos ultimos 90 dias...'
    & $exe --once
    if ($LASTEXITCODE -ne 0) { throw "Coleta falhou: codigo $LASTEXITCODE" }
    Write-Host '[OK] Coleta concluida. Examine ErrosColeta no JSON acima.' -ForegroundColor Green
} catch {
    Write-Error "SGB-LAB: $($_.Exception.Message)"
    exit 1
}
