# Execute no servidor onde o HTTPS ja e confiavel. Exporta somente a parte publica.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ServerUrl,
    [string]$Destino
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$uri=[uri]$ServerUrl
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
    throw 'Informe https://nome-do-servidor:porta sem caminho ou credenciais.'
}
if (-not $Destino) { $Destino=Join-Path ([Environment]::GetFolderPath('Desktop')) ($uri.DnsSafeHost + '.cer') }
$Destino=[IO.Path]::GetFullPath($Destino)
if (Test-Path -LiteralPath $Destino) { throw "Destino ja existe: $Destino. Escolha outro nome para preservar o certificado anterior." }
$tcp=New-Object Net.Sockets.TcpClient
$tls=$null
$cert=$null
try {
    $connection=$tcp.ConnectAsync($uri.DnsSafeHost,$uri.Port)
    if (-not $connection.Wait(15000)) { throw 'Tempo esgotado conectando ao servidor.' }
    $tls=New-Object Net.Security.SslStream($tcp.GetStream(),$false)
    $handshake=$tls.AuthenticateAsClientAsync($uri.DnsSafeHost)
    if (-not $handshake.Wait(15000)) { throw 'Tempo esgotado validando HTTPS.' }
    $cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($tls.RemoteCertificate)
    $bytes=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $output=[IO.File]::Open($Destino,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $output.Write($bytes,0,$bytes.Length) } finally { $output.Dispose() }
    $hash=(Get-FileHash -LiteralPath $Destino -Algorithm SHA256).Hash
    Write-Host '[OK] Certificado publico do endpoint HTTPS validado; nenhuma chave privada exportada.' -ForegroundColor Green
    [pscustomobject]@{ ArquivoCer=$Destino; Sha256Esperado=$hash; ServerUrl=$ServerUrl; Thumbprint=$cert.Thumbprint; Validade=$cert.NotAfter } | Format-List
} finally {
    if ($cert) { $cert.Dispose() }
    if ($tls) { $tls.Dispose() }
    $tcp.Dispose()
}
