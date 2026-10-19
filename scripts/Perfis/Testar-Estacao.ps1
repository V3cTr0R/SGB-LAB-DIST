# Verificacao integrada: envia a coleta local e confirma leitura no banco remoto.
# Nao altera configuracoes; atualiza heartbeat/snapshot da propria estacao.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach ($name in @('SgbLabDiagnostico','SgbLabRelay')) {
 $service=Get-Service $name -ErrorAction Stop
 if ($service.Status -ne 'Running') { throw "Servico $name nao esta em execucao." }
}
$snapshot=Join-Path $env:ProgramData 'SGB-LAB\Diagnosticos\ultimo.json'
$data=Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
if ($data.Nome_Maquina -ine $env:COMPUTERNAME) { throw 'Snapshot pertence a outra maquina.' }
$collected=[DateTimeOffset]::Parse($data.DataColeta)
if ($collected -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or $collected -lt [DateTimeOffset]::UtcNow.AddMinutes(-10)) { throw 'Coleta com mais de 10 minutos ou relogio divergente. Reinicie SgbLabDiagnostico e aguarde nova coleta antes de homologar.' }
$relay=Join-Path $env:ProgramFiles 'SGB-LAB\Relay\SgbRelay.exe'
& $relay --once | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Relay nao confirmou o diagnostico persistido no servidor. Confira HTTPS, token e logs do servico.' }
Write-Host "[OK] $env:COMPUTERNAME | coleta $($data.DataColeta) | envio e leitura no servidor confirmados." -ForegroundColor Green
