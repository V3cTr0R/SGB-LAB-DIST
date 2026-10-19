# Somente para o certificado LOCAL autoassinado emitido pelo SGB-LAB.
# Certificados de PKI devem ser distribuidos pela administracao da PKI/GPO.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$ArquivoCer,
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$Sha256Esperado,
 [Parameter(Mandatory=$true)][string]$ServerUrl
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'scripts\Instalacao\Descoberta.ps1')
$admin=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra como Administrador para configurar a confianca dos servicos.' }
$uri=[uri]$ServerUrl
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'Informe https://nome-do-servidor:porta sem caminho ou credenciais.' }
$bytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ArquivoCer).Path)
$sha=[Security.Cryptography.SHA256]::Create()
try { $actual=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
if ($actual -ine $Sha256Esperado) { throw 'SHA-256 divergente. Nada foi importado. Confira o hash diretamente no servidor.' }
if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($bytes) -ne [Security.Cryptography.X509Certificates.X509ContentType]::Cert) { throw 'Exige certificado publico CER, nao PFX ou pacote.' }
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
$added=$false
$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine')
try {
 if ($cert.HasPrivateKey -or $cert.Subject -ne $cert.Issuer) { throw 'Este fluxo aceita apenas certificado publico local autoassinado.' }
 if ($cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)) { throw 'Certificado fora da validade.' }
 $dnsExtension=@($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })
 # X509Certificate2 carregado de bytes nao tem DnsNameList do provider Cert:.
 # GetNameInfo resolve o DNS SAN do certificado local de nome unico emitido pelo SGB-LAB.
 $dns=$cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::DnsName,$false)
 if ($dnsExtension.Count -eq 0 -or $dns -ine $uri.DnsSafeHost) { throw 'Nome DNS do certificado nao corresponde ao servidor.' }
 $eku=@($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
 if ($eku.Count -ne 1 -or '1.3.6.1.5.5.7.3.1' -notin @($eku[0].EnhancedKeyUsages | ForEach-Object { $_.Value })) { throw 'Certificado sem uso de autenticacao de servidor.' }
 $bc=@($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
 if ($bc.Count -gt 0 -and $bc[0].CertificateAuthority) { throw 'Este fluxo nao instala autoridades certificadoras.' }
 $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
 if ($store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$cert.Thumbprint,$false).Count -eq 0) { $store.Add($cert); $added=$true }
 if (-not (Test-SgbServerHttps -ServerUrl $ServerUrl)) { throw 'HTTPS/API nao validou apos importar. Confira DNS, porta, firewall e servidor.' }
 Write-Host '[OK] HTTPS/API validado com confianca normal do Windows.' -ForegroundColor Green
} catch {
 if ($added) { $store.Remove($cert); Write-Warning 'A importacao feita por esta execucao foi revertida.' }
 throw
} finally { $store.Close(); $cert.Dispose() }
