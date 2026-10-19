# SGB-LAB v0.2.2: instalacao e atualizacao transacional com rollback.
# Windows PowerShell 5.1, Windows x64. Backup local preservado em ProgramData.
[CmdletBinding()]
param(
    [switch]$VerificarApenas,
    [switch]$SemInstalarSdk
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Wait-SnapshotNovo {
    param([string]$Caminho, [datetime]$Anterior, [int]$Segundos = 90, [string]$VersaoEsperada = '0.2.2')
    $fim = [DateTime]::UtcNow.AddSeconds($Segundos)
    do {
        if (Test-Path -LiteralPath $Caminho -PathType Leaf) {
            $atual = (Get-Item -LiteralPath $Caminho).LastWriteTimeUtc
            if ($atual -gt $Anterior) {
                try {
                    $json = Get-Content -LiteralPath $Caminho -Raw | ConvertFrom-Json
                    if ($json.Nome_Maquina -and $json.DataColeta -and $json.VersaoAgente -eq $VersaoEsperada) { return $true }
                } catch { }
            }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $fim)
    return $false
}

$servicoNome = 'SgbLabDiagnostico'
$pastaInstalacao = Join-Path ${env:ProgramFiles} 'SGB-LAB\Agent'
$exeDestino = Join-Path $pastaInstalacao 'SgbService.exe'
$pastaBase = Join-Path $env:ProgramData 'SGB-LAB'
$pastaDados = Join-Path $pastaBase 'Diagnosticos'
$arquivoSnapshot = Join-Path $pastaDados 'ultimo.json'
$backupDir = $null
$servicoExistente = $false
$alteracaoIniciada = $false
$servicoCriado = $false

try {
    Assert-WindowsX64
    if ($VerificarApenas) {
        Write-Host '[MODO LEITURA] Nenhuma dependencia sera instalada ou alterada.'
        $ok = Test-WindowsDependencies
        $sdk = Find-Dotnet10Sdk
        if ($null -ne $sdk) { Write-Host "[OK] SDK para build: $sdk" }
        else { Write-Host '[INFO] SDK ausente; desnecessario com executavel self-contained.' }
        $raiz = Split-Path -Parent $PSScriptRoot
        if (Test-Path -LiteralPath (Join-Path $raiz 'payload\win-x64\SgbService.exe')) {
            Write-Host '[OK] Payload precompilado disponivel.'
        } else { Write-Host '[INFO] Build a partir do fonte sera necessario.' }
        if (-not $ok) { exit 2 }
        exit 0
    }

    if (-not (Test-IsAdministrator)) {
        Write-Host '[UAC] Solicitando privilegios de Administrador...'
        $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
        if ($SemInstalarSdk) { $argumentos += '-SemInstalarSdk' }
        $elevado = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentos -Verb RunAs -Wait -PassThru
        exit $elevado.ExitCode
    }

    if (-not (Test-WindowsDependencies -Repair)) {
        throw 'Dependencias nativas criticas indisponiveis. Verifique permissao/GPO.'
    }

    # Sempre validar e publicar antes de parar o servico em producao.
    $payload = Get-SgbPayload -NoSdkInstall:$SemInstalarSdk
    $exeOrigem = Join-Path $payload 'SgbService.exe'
    Invoke-SgbPreflight -Exe $exeOrigem
    Write-Host '[TESTE] Coleta de validacao do novo binario (antes da atualizacao)...'
    & $exeOrigem --once | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Novo executavel nao passou no teste --once.' }

    New-Item -ItemType Directory -Path $pastaBase, $pastaDados -Force | Out-Null
    # O inventario e os backups contêm dados internos; somente SYSTEM/Administradores.
    & icacls.exe $pastaBase '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger pasta SGB-LAB.' }
    & icacls.exe $pastaDados '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger snapshots.' }

    $servico = Get-Service -Name $servicoNome -ErrorAction SilentlyContinue
    $servicoExistente = ($null -ne $servico)
    if ($servicoExistente) {
        $registro = Get-CimInstance Win32_Service -Filter "Name='$servicoNome'"
        if ($null -ne $registro -and $registro.PathName -notlike "*$exeDestino*") {
            throw "Servico $servicoNome aponta para outro binario: $($registro.PathName)"
        }
        if ($servico.Status -ne 'Stopped') {
            Write-Host '[UPGRADE] Parando servico existente...'
            Stop-Service -Name $servicoNome -ErrorAction Stop
            $alteracaoIniciada = $true # reverte inclusive timeout de parada
            (Get-Service -Name $servicoNome).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40))
        }
        $alteracaoIniciada = $true # tambem recupera falhas no BACKUP apos parar o servico
        # Copia exatamente os arquivos do Agent, preservando a configuracao atual.
        $backupDir = Join-Path (Join-Path $pastaBase 'Backups') ("Agent-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $pastaInstalacao)) {
            throw 'Servico existente sem pasta de instalacao; atualizacao cancelada.'
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $pastaInstalacao -Force)) {
            Copy-Item -LiteralPath $item.FullName -Destination $backupDir -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $backupDir 'SgbService.exe'))) {
            throw 'Nao foi possivel criar backup do binario anterior.'
        }
        Write-Host "[BACKUP] Versao anterior salva em: $backupDir" -ForegroundColor Green
    } else {
        Write-Host '[INSTALACAO] Servico nao encontrado; criando uma nova instalacao.'
    }

    $alteracaoIniciada = $true
    New-Item -ItemType Directory -Path $pastaInstalacao -Force | Out-Null
    # Binario self-contained + possiveis arquivos auxiliares da publicacao.
    foreach ($arquivo in @(Get-ChildItem -LiteralPath $payload -File)) {
        if ($arquivo.Name -in @('appsettings.json', 'manifesto.json')) { continue }
        Copy-Item -LiteralPath $arquivo.FullName -Destination (Join-Path $pastaInstalacao $arquivo.Name) -Force
    }
    $configOrigem = Join-Path $payload 'appsettings.json'
    $configDestino = Join-Path $pastaInstalacao 'appsettings.json'
    if ((Test-Path -LiteralPath $configOrigem) -and -not (Test-Path -LiteralPath $configDestino)) {
        Copy-Item -LiteralPath $configOrigem -Destination $configDestino -Force
    } else {
        Write-Host '[OK] Configuracao appsettings.json existente preservada.'
    }

    if (-not $servicoExistente) {
        New-Service -Name $servicoNome -BinaryPathName ('"' + $exeDestino + '"') `
            -DisplayName 'SGB-LAB Diagnostico' -Description 'Agente local de diagnostico SGB-LAB' `
            -StartupType Automatic | Out-Null
        $servicoCriado = $true
    } else {
        Set-Service -Name $servicoNome -StartupType Automatic
    }

    & sc.exe failure $servicoNome 'reset=' '86400' 'actions=' 'restart/60000/restart/60000/none/0' | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Nao foi possivel configurar recuperacao de falhas.' }

    $tempoSnapshotAnterior = [datetime]::MinValue
    if (Test-Path -LiteralPath $arquivoSnapshot) {
        $tempoSnapshotAnterior = (Get-Item -LiteralPath $arquivoSnapshot).LastWriteTimeUtc
    }

    Write-Host '[UPGRADE] Iniciando servico atualizado...'
    Start-Service -Name $servicoNome -ErrorAction Stop
    (Get-Service -Name $servicoNome).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
    Write-Host '[VALIDACAO] Aguardando novo snapshot da v0.2.2 (ate 90 segundos)...'
    if (-not (Wait-SnapshotNovo -Caminho $arquivoSnapshot -Anterior $tempoSnapshotAnterior)) {
        throw 'O novo Worker nao atualizou ultimo.json em 90 segundos.'
    }
    if ((Get-Service -Name $servicoNome).Status -ne 'Running') {
        throw 'Servico deixou de executar durante a validacao.'
    }

    Write-Host '[OK] Servico atualizado e snapshot v0.2.2 validado.' -ForegroundColor Green
    Write-Host "[OK] Binario: $exeDestino"
    Write-Host "[OK] Snapshot: $arquivoSnapshot"
    if ($servicoExistente) { Write-Host "[OK] Backup de reversao preservado: $backupDir" }
} catch {
    $mensagemOriginal = $_.Exception.Message
    if ($alteracaoIniciada) {
        Write-Warning "Atualizacao falhou: $mensagemOriginal. Tentando rollback..."
        try {
            $emExecucao = Get-Service -Name $servicoNome -ErrorAction SilentlyContinue
            if ($null -ne $emExecucao -and $emExecucao.Status -ne 'Stopped') {
                Stop-Service -Name $servicoNome -ErrorAction Stop
                (Get-Service -Name $servicoNome).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            }
            if ($servicoExistente -and $backupDir -and (Test-Path -LiteralPath (Join-Path $backupDir 'SgbService.exe'))) {
                foreach ($item in @(Get-ChildItem -LiteralPath $pastaInstalacao -Force)) {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force
                }
                foreach ($item in @(Get-ChildItem -LiteralPath $backupDir -Force)) {
                    Copy-Item -LiteralPath $item.FullName -Destination $pastaInstalacao -Recurse -Force
                }
                Start-Service -Name $servicoNome -ErrorAction Stop
                (Get-Service -Name $servicoNome).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
                Write-Host '[ROLLBACK OK] Versao anterior restaurada e servico em execucao.' -ForegroundColor Yellow
            } elseif ($servicoCriado) {
                & sc.exe delete $servicoNome | Out-Host
                Write-Warning 'Servico recem-criado removido; arquivos de instalacao permanecem para diagnostico.'
            } elseif ($servicoExistente -and (Test-Path -LiteralPath $exeDestino)) {
                # Antes da copia do binario novo, o binario antigo ainda esta intacto.
                Start-Service -Name $servicoNome -ErrorAction Stop
                (Get-Service -Name $servicoNome).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
                Write-Warning 'Backup nao concluido; o servico anterior foi religado sem substituicao.'
            } else {
                Write-Warning 'Sem backup validado; verificar manualmente a instalacao.'
            }
        } catch {
            Write-Warning "[ROLLBACK FALHOU] $($_.Exception.Message). Verifique o servico e backups em $pastaBase\Backups"
        }
    }
    # Lancar o erro encerra o script, nao a sessao interativa do administrador.
    throw "SGB-LAB: $mensagemOriginal"
}
