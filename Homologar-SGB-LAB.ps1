# SGB-LAB 0.3.2.2: homologacao de ponta a ponta por etapas, sem alterar o AD ou o Windows.
# Windows PowerShell 5.1+. Modos Fonte, Distribuicao e Instalado. -GerarDistribuicao e opt-in.
[CmdletBinding()]
param(
    [ValidateSet('Fonte','Distribuicao','Instalado')][string]$Modo = 'Fonte',
    [ValidateSet('Servidor','Laboratorio','TI')][string]$Perfil = 'Servidor',
    [switch]$GerarDistribuicao,
    [string]$Pacote,
    [string]$Url = '',
    [string]$DcFqdn = '',
    [string]$Relatorio = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$raiz = $PSScriptRoot
if (-not $Pacote) { $Pacote = if (Test-Path (Join-Path $raiz 'src')) { Join-Path $raiz 'SGB-LAB-DIST\SGB-LAB' } else { $raiz } }
if (-not $Relatorio) {
    $Relatorio = Join-Path ([IO.Path]::GetTempPath()) ('SGB-LAB-homologacao-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}
$script:resultados = New-Object 'System.Collections.Generic.List[object]'
function Registrar([string]$Etapa, [bool]$Ok, [string]$Detalhe) {
    $script:resultados.Add([pscustomobject]@{ Etapa = $Etapa; Ok = $Ok; Detalhe = $Detalhe })
    if ($Ok) { Write-Host "[OK] $Etapa - $Detalhe" -ForegroundColor Green }
    else { Write-Host "[FALHA] $Etapa - $Detalhe" -ForegroundColor Red }
}
function Existe([string]$Relativo, [string]$Pasta) {
    return (Test-Path -LiteralPath (Join-Path $Pasta $Relativo) -PathType Leaf)
}
function Verificar-Scripts([string]$Pasta) {
    $arquivos = @(Get-ChildItem -LiteralPath $Pasta -Filter '*.ps1' -Recurse -File)
    $erros = New-Object 'System.Collections.Generic.List[string]'
    foreach ($arquivo in $arquivos) {
        $tokens = $null; $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($arquivo.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($e in @($parseErrors | Where-Object { $null -ne $_ })) { $erros.Add("$($arquivo.Name): linha $($e.Extent.StartLineNumber) - $($e.Message)") }
    }
    Registrar 'Sintaxe de PowerShell' ($erros.Count -eq 0) "$($arquivos.Count) scripts; erros: $($erros -join ' | ')"
}
function Verificar-Distribuicao([string]$Pasta) {
    $arquivos = @(
        'Instalar-SGB-LAB.ps1', 'scripts\Perfis\Instalar-Servidor.ps1', 'scripts\Perfis\Instalar-Laboratorio.ps1', 'scripts\Perfis\Instalar-TI.ps1',
        'publicado-v030\Server\SgbServer.exe', 'publicado-v030\Server\wwwroot\index.html',
        'publicado-v030\Relay\SgbRelay.exe', 'payload\win-x64\SgbService.exe',
        'payload\win-x64\appsettings.json', 'payload\win-x64\manifesto.json'
    )
    $faltantes = @($arquivos | Where-Object { -not (Existe $_ $Pasta) })
    Registrar 'Arquivos da distribuicao' ($faltantes.Count -eq 0) $(if ($faltantes.Count) { 'Ausentes: ' + ($faltantes -join ', ') } else { '10/10 arquivos esperados' })
    if ($faltantes.Count) { return }
    try {
        $folder = Join-Path $Pasta 'payload\win-x64'
        $manifesto = Get-Content -LiteralPath (Join-Path $folder 'manifesto.json') -Raw | ConvertFrom-Json
        $comparacoes = @(
            [pscustomobject]@{ Nome = 'SgbService.exe'; Hash = $manifesto.SHA256 },
            [pscustomobject]@{ Nome = 'appsettings.json'; Hash = $manifesto.ConfigSHA256 }
        )
        $divergentes = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $comparacoes) {
            $real = (Get-FileHash -LiteralPath (Join-Path $folder $item.Nome) -Algorithm SHA256).Hash
            if ($real -ne $item.Hash) { $divergentes.Add($item.Nome) }
        }
        foreach ($p in $manifesto.Arquivos.PSObject.Properties) {
            if (-not (Existe $p.Name $folder)) { $divergentes.Add($p.Name); continue }
            $real = (Get-FileHash -LiteralPath (Join-Path $folder $p.Name) -Algorithm SHA256).Hash
            if ($real -ne $p.Value) { $divergentes.Add($p.Name) }
        }
        Registrar 'Manifesto SHA-256' ($divergentes.Count -eq 0) $(if ($divergentes.Count) { 'Divergencias: ' + ($divergentes -join ', ') } else { 'Arquivos verificados' })
    } catch { Registrar 'Manifesto SHA-256' $false $_.Exception.Message }
    Verificar-Scripts $Pasta
}
function Verificar-HTTPS([string]$Uri) {
    try {
        $alvo = [Uri]$Uri
        if (-not $alvo.IsAbsoluteUri -or $alvo.Scheme -ne 'https') { throw 'Exige URL https:// com hostname do certificado.' }
        $req = [System.Net.WebRequest]::Create($alvo)
        $req.Proxy = $null; $req.Timeout = 7000
        $resp = $req.GetResponse()
        try {
            Registrar 'HTTPS da API' ([int]$resp.StatusCode -eq 200) "HTTP $([int]$resp.StatusCode); certificado validado pelo Windows"
        } finally { $resp.Close() }
    } catch { Registrar 'HTTPS da API' $false $_.Exception.Message }
}
function Verificar-LDAPS([string]$Dns) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($Dns, 636)
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
        try {
            $ssl.AuthenticateAsClient($Dns)
            Registrar 'LDAPS do controlador' $true "TLS $($ssl.SslProtocol); certificado confiavel"
        } finally { $ssl.Dispose() }
    } catch { Registrar 'LDAPS do controlador' $false $_.Exception.Message }
    finally { $client.Close() }
}
try {
    Registrar 'Windows x64' ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [Environment]::Is64BitOperatingSystem) 'Windows 64 bits necessario para instalacao e testes reais'
    if ($Modo -eq 'Fonte') {
        foreach ($f in @('Gerar-Distribuicao.ps1', 'src\SgbServer\SgbServer.csproj', 'src\SgbRelay\SgbRelay.csproj', 'web\dashboard\package.json')) {
            Registrar "Fonte: $f" (Existe $f $raiz) 'Arquivo esperado'
        }
        Verificar-Scripts $raiz
        if ($GerarDistribuicao) {
            $gerador = Join-Path $raiz 'Gerar-Distribuicao.ps1'
            try {
                & $gerador -Destino $Pacote | Out-Host
                Registrar 'Gerar distribuicao' (Existe 'publicado-v030\Server\SgbServer.exe' $Pacote) 'Geracao concluida'
                Verificar-Distribuicao $Pacote
            } catch { Registrar 'Gerar distribuicao' $false $_.Exception.Message }
        } else {
            Write-Host '[INFO] Para compilar e testar distribuicao use -GerarDistribuicao na maquina de BUILD.'
        }
    } elseif ($Modo -eq 'Distribuicao') {
        Verificar-Distribuicao $Pacote
    } else {
        $servicos = switch ($Perfil) {
            'Servidor' { @('SgbLabServer') }
            'Laboratorio' { @('SgbLabDiagnostico','SgbLabRelay') }
            'TI' { @() }
        }
        foreach ($servico in $servicos) {
            $obj = Get-Service -Name $servico -ErrorAction SilentlyContinue
            $ok = $null -ne $obj -and $obj.Status -eq 'Running'
            Registrar "Servico $servico" $ok $(if ($obj) { $obj.Status.ToString() } else { 'Nao instalado nesta maquina' })
        }
        if ($Perfil -eq 'Laboratorio') {
        $snapshot = Join-Path $env:ProgramData 'SGB-LAB\Diagnosticos\ultimo.json'
        $valido = $false
        if (Test-Path -LiteralPath $snapshot -PathType Leaf) {
            try { $dados = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json; $valido = [bool]($dados.Nome_Maquina -and $dados.DataColeta) } catch { }
        }
        Registrar 'Snapshot diagnostico' $valido 'Ultimo JSON local interpretado'
        }
    }
    if ($Url) { Verificar-HTTPS $Url }
    if ($DcFqdn) { Verificar-LDAPS $DcFqdn }
} catch {
    Registrar 'Execucao do validador' $false $_.Exception.Message
} finally {
    $total = $script:resultados.Count
    $falhas = @($script:resultados | Where-Object { -not $_.Ok }).Count
    $objeto = [pscustomobject]@{
        VersaoValidador = '0.3.3-rc.1'; DataUtc = [DateTime]::UtcNow.ToString('O');
        Modo = $Modo; Perfil = $Perfil; Total = $total; Falhas = $falhas; Resultados = $script:resultados.ToArray()
    }
    $pastaRelatorio = Split-Path -Parent $Relatorio
    if ($pastaRelatorio -and -not (Test-Path -LiteralPath $pastaRelatorio)) { New-Item -ItemType Directory -Path $pastaRelatorio -Force | Out-Null }
    $objeto | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Relatorio -Encoding UTF8
    Write-Host "[RELATORIO] $Relatorio - total=$total falhas=$falhas" -ForegroundColor Cyan
    if ($falhas -gt 0) { exit 2 }
}
