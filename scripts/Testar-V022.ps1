# Teste local apos upgrade v0.2.2. Nao altera a instalacao.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
try {
    $nome = 'SgbLabDiagnostico'
    $servico = Get-Service -Name $nome -ErrorAction Stop
    if ($servico.Status -ne 'Running') { throw "$nome nao esta Running." }
    $exe = Join-Path ${env:ProgramFiles} 'SGB-LAB\Agent\SgbService.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Binario ausente: $exe" }
    Write-Host '[TESTE] Dependencias internas...'
    & $exe --preflight | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Preflight falhou.' }
    Write-Host '[TESTE] Coleta v0.2.2...'
    $saida = & $exe --once
    if ($LASTEXITCODE -ne 0) { throw 'Execucao --once falhou.' }
    $dados = ($saida -join [Environment]::NewLine) | ConvertFrom-Json
    if ($dados.VersaoAgente -ne '0.2.2') { throw "Versao incorreta: $($dados.VersaoAgente)" }
    foreach ($campo in @('CPU','Volumes','Sistema','Rede','TelasAzuis90','Discos','ErrosColeta','AnaliseLocal')) {
        if (-not $dados.PSObject.Properties[$campo]) { throw "Campo ausente: $campo" }
    }
    if (-not $dados.Sistema.PSObject.Properties['IncidentesDesligamentoInesperado90']) {
        throw 'Nao foi encontrado o contador de incidentes correlacionados.'
    }
    $snapshot = Join-Path $env:ProgramData 'SGB-LAB\Diagnosticos\ultimo.json'
    if (-not (Test-Path -LiteralPath $snapshot)) { throw 'Snapshot nao encontrado.' }
    $gravado = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    if ($gravado.VersaoAgente -ne '0.2.2') { throw 'Snapshot periodico nao e da versao 0.2.2.' }
    $historico = Join-Path $env:ProgramData ('SGB-LAB\Historico\{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'))
    if (-not (Test-Path -LiteralPath $historico)) { throw "Historico diario ausente: $historico" }
    $linha = Get-Content -LiteralPath $historico -Tail 1 | ConvertFrom-Json
    if ($linha.VersaoAgente -ne '0.2.2') { throw 'Ultima linha do historico nao corresponde a versao instalada.' }
    Write-Host '[OK] Servico Running, versao, preflight, snapshot e historico validados.' -ForegroundColor Green
    Write-Host ('CPU={0} | Volumes={1} | Rede={2} | Incidentes90={3} | AlertaLocal={4} | Erros={5}' -f `
        $dados.CPU.Modelo, @($dados.Volumes).Count, @($dados.Rede.Interfaces).Count, `
        $dados.Sistema.IncidentesDesligamentoInesperado90, $dados.AnaliseLocal.EstadoSugerido, @($dados.ErrosColeta).Count)
    Write-Host "[OK] Historico: $historico"
    Write-Host "[OK] Log: $(Join-Path $env:ProgramData 'SGB-LAB\Logs\agente.log')"
} catch {
    Write-Error "SGB-LAB teste 0.2.2: $($_.Exception.Message)"
    exit 1
}
