# Funcoes compartilhadas pelos scripts de teste, build e instalacao.
# Compativel com Windows PowerShell 5.1 ou superior.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-WindowsX64 {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'SGB-LAB Modulo 2 suporta apenas Windows.'
    }
    if (-not [Environment]::Is64BitOperatingSystem -or
        [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
        throw 'Este pacote e para Windows x64. Publicar separadamente para win-arm64 se necessario.'
    }
    Write-Host '[OK] Windows x64 detectado.' -ForegroundColor Green
}

function Test-IsAdministrator {
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidade)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WindowsDependencies {
    param([switch]$Repair)

    $valido = $true
    foreach ($nome in @('winmgmt', 'EventLog')) {
        $servico = Get-Service -Name $nome -ErrorAction SilentlyContinue
        if ($null -eq $servico) {
            Write-Warning "Dependencia nativa ausente: $nome"
            $valido = $false
            continue
        }
        if ($servico.Status -ne 'Running') {
            if ($Repair -and $nome -eq 'winmgmt' -and $servico.StartType -ne 'Disabled') {
                try {
                    Write-Host '[AUTO] Iniciando Windows Management Instrumentation...'
                    Start-Service -Name 'winmgmt' -ErrorAction Stop
                    (Get-Service -Name 'winmgmt').WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
                    $servico = Get-Service -Name 'winmgmt'
                } catch {
                    Write-Warning "WMI nao pode ser iniciado: $($_.Exception.Message)"
                }
            }
            if ($servico.Status -ne 'Running') {
                Write-Warning "$nome esta parado. Nao alteramos servicos desativados por politica."
                $valido = $false
            }
        }
        if ($servico.Status -eq 'Running') {
            Write-Host "[OK] Servico nativo $nome em execucao." -ForegroundColor Green
        }
    }

    try {
        $null = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        Write-Host '[OK] Namespace WMI root/cimv2 acessivel.' -ForegroundColor Green
    } catch {
        Write-Warning "Falha de consulta WMI: $($_.Exception.Message)"
        $valido = $false
    }

    try {
        $null = Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop
        Write-Host '[OK] Namespace WMI Storage acessivel.' -ForegroundColor Green
    } catch {
        Write-Warning 'WMI Storage indisponivel; o agente tentara Win32_DiskDrive (tipo pode ficar DESCONHECIDO).'
    }

    try {
        $registro = Get-WinEvent -ListLog System -ErrorAction Stop
        if (-not $registro.IsEnabled) {
            Write-Warning 'Log System esta desabilitado. A coleta de BugCheck nao sera confiavel.'
            $valido = $false
        } else {
            Write-Host '[OK] Log de eventos System habilitado.' -ForegroundColor Green
        }
    } catch {
        Write-Warning "Log de eventos System indisponivel: $($_.Exception.Message)"
        $valido = $false
    }
    return $valido
}

function Find-Dotnet10Sdk {
    # Find the SDK executable on a new Windows computer, not the copied SSD.
    # The standard x64 path is C:\Program Files\dotnet\dotnet.exe
    # (NOT C:\Program Files\dotnet.exe).
    $candidatos = New-Object 'System.Collections.Generic.List[string]'
    $roots = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrWhiteSpace($env:SGB_DOTNET_EXE)) {
        $candidatos.Add($env:SGB_DOTNET_EXE)
    }
    foreach ($base in @($env:DOTNET_ROOT_X64, $env:DOTNET_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($base)) { $roots.Add($base) }
    }
    foreach ($programFiles in @($env:ProgramW6432, ${env:ProgramFiles})) {
        if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
            $roots.Add((Join-Path $programFiles 'dotnet'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $roots.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'))
    }
    # The registry may specify a non-default SDK install directory.
    foreach ($regPath in @(
        'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64',
        'HKCU:\SOFTWARE\dotnet\Setup\InstalledVersions\x64'
    )) {
        try {
            $instalado = (Get-ItemProperty -LiteralPath $regPath -Name InstallLocation -ErrorAction Stop).InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($instalado)) { $roots.Add($instalado) }
        } catch { }
    }
    foreach ($base in ($roots | Select-Object -Unique)) {
        $exe = Join-Path $base 'dotnet.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { $candidatos.Add($exe) }
    }
    # PATH can be stale in the same PowerShell session after WinGet install.
    $cmd = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $candidatos.Add($cmd.Source) }

    foreach ($exe in ($candidatos | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        try {
            $versoes = @(& $exe --list-sdks 2>$null)
            if ($LASTEXITCODE -eq 0 -and
                @($versoes | Where-Object { $_ -match '^10\.' }).Count -gt 0) {
                return $exe
            }
        } catch { }
    }
    return $null
}

function Ensure-Dotnet10Sdk {
    param([switch]$NoSdkInstall)
    $exe = Find-Dotnet10Sdk
    if ($null -ne $exe) {
        Write-Host "[OK] SDK .NET 10 encontrado em $exe" -ForegroundColor Green
        return $exe
    }

    if ($NoSdkInstall) {
        throw 'SDK .NET 10 nao encontrado. Instale-o no computador de build ou remova -SemInstalarSdk.'
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw 'SDK .NET 10 ausente e WinGet indisponivel. Use um pacote SGB-LAB ja publicado em modo self-contained, ou instale o SDK pelo site oficial da Microsoft.'
    }

    Write-Host '[AUTO] Instalando SDK oficial Microsoft.DotNet.SDK.10 pelo WinGet.' -ForegroundColor Yellow
    Write-Host 'Esta etapa pode exigir internet e autorizacao do Windows (UAC).'
    # Saida do WinGet deve aparecer no console, NAO no valor retornado pela funcao.
    & $winget.Source install --id Microsoft.DotNet.SDK.10 --exact --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
    $codigoWinget = $LASTEXITCODE
    # Alguns instaladores retornam codigo de aviso mesmo com SDK existente.
    # Revalidamos antes de determinar se a instalacao falhou.
    if ($codigoWinget -ne 0) {
        $sdkAposWinget = Find-Dotnet10Sdk
        if ($sdkAposWinget) {
            Write-Warning "WinGet retornou $codigoWinget, mas o SDK .NET 10 foi confirmado em $sdkAposWinget."
            return $sdkAposWinget
        }
        throw "WinGet nao concluiu a instalacao do SDK (codigo $codigoWinget). Procure suporte de TI em maquinas gerenciadas."
    }
    # Evita depender do PATH antigo e aguarda o fim da disponibilizacao dos binarios.
    $exe = $null
    for ($tentativa = 1; $tentativa -le 6; $tentativa++) {
        $exe = Find-Dotnet10Sdk
        if ($null -ne $exe) { break }
        if ($tentativa -lt 6) { Start-Sleep -Seconds 2 }
    }
    if ($null -eq $exe) {
        throw 'WinGet reportou sucesso, mas o SDK .NET 10 nao foi localizado. Verifique C:\Program Files\dotnet\dotnet.exe --list-sdks; em computador corporativo, consulte a equipe de TI antes de instalar.'
    }
    Write-Host '[OK] SDK .NET 10 instalado.' -ForegroundColor Green
    return $exe
}

function Publish-SgbService {
    param([switch]$NoSdkInstall)
    [string]$dotnet = Ensure-Dotnet10Sdk -NoSdkInstall:$NoSdkInstall
    if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
        throw "SDK encontrado, mas dotnet.exe nao existe no caminho: $dotnet"
    }
    $raiz = Split-Path -Parent $PSScriptRoot
    $projeto = Join-Path $raiz 'src\SgbService\SgbService.csproj'
    if (-not (Test-Path -LiteralPath $projeto)) {
        throw "Projeto nao encontrado: $projeto"
    }
    $saida = Join-Path ([IO.Path]::GetTempPath()) ("SgbLab-Publish-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $saida -Force | Out-Null
    Write-Host "[BUILD] Publicando win-x64 self-contained em $saida"
    # Saida do dotnet deve aparecer no console, NAO no valor retornado pela funcao.
    & $dotnet publish $projeto -c Release -r win-x64 --self-contained true -o $saida '-p:PublishSingleFile=true' '-p:PublishTrimmed=false' '-p:DebugType=None' | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Falha no dotnet publish (codigo $LASTEXITCODE). Verifique internet/NuGet e log acima."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $saida 'SgbService.exe'))) {
        throw 'Publicacao nao gerou SgbService.exe.'
    }
    return $saida
}

function Get-SgbPayload {
    param([switch]$NoSdkInstall)
    $raiz = Split-Path -Parent $PSScriptRoot
    $precompilado = Join-Path $raiz 'payload\win-x64'
    $exe = Join-Path $precompilado 'SgbService.exe'
    if (Test-Path -LiteralPath $exe) {
        $manifesto = Join-Path $precompilado 'manifesto.json'
        if (-not (Test-Path -LiteralPath $manifesto)) {
            throw 'Executavel precompilado sem manifesto SHA-256. Pacote de distribuicao invalido.'
        }
        $manifest = Get-Content -LiteralPath $manifesto -Raw | ConvertFrom-Json
        $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        if ($hash -ne $manifest.SHA256) {
            throw 'Hash SHA-256 divergente para SgbService.exe: pacote corrompido ou alterado.'
        }
        $config = Join-Path $precompilado 'appsettings.json'
        if (-not (Test-Path -LiteralPath $config)) {
            throw 'Configuracao appsettings.json ausente no pacote.'
        }
        $configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
        if ($configHash -ne $manifest.ConfigSHA256) {
            throw 'Hash SHA-256 divergente para appsettings.json.'
        }
        # Manifestos v0.2.2 conferem tambem dependencias auxiliares da publicacao.
        if ($null -ne $manifest.PSObject.Properties['Arquivos']) {
            foreach ($entrada in $manifest.Arquivos.PSObject.Properties) {
                $caminhoArquivo = Join-Path $precompilado $entrada.Name
                if (-not (Test-Path -LiteralPath $caminhoArquivo -PathType Leaf)) {
                    throw "Arquivo do pacote ausente: $($entrada.Name)"
                }
                $shaAtual = (Get-FileHash -LiteralPath $caminhoArquivo -Algorithm SHA256).Hash
                if ($shaAtual -ne [string]$entrada.Value) {
                    throw "SHA-256 divergente: $($entrada.Name)"
                }
            }
        }
        Write-Host '[OK] Pacote self-contained validado pelo SHA-256.' -ForegroundColor Green
        return $precompilado
    }
    Write-Host '[INFO] Nenhum executavel publicado incluido; compilando a partir do codigo-fonte.'
    return Publish-SgbService -NoSdkInstall:$NoSdkInstall
}

function Invoke-SgbPreflight {
    param([Parameter(Mandatory=$true)][string]$Exe)
    Write-Host '[TESTE] Verificando dependencias com o proprio agente...'
    & $Exe --preflight
    if ($LASTEXITCODE -ne 0) {
        throw "Preflight do agente falhou (codigo $LASTEXITCODE). Instalacao interrompida."
    }
    Write-Host '[OK] Preflight concluido.' -ForegroundColor Green
}
