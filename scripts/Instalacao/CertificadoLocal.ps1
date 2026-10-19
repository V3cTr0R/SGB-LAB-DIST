# Provisionamento HTTPS local do SGB-LAB. Este modulo ESCREVE no Windows SOMENTE
# quando New-SgbLocalHttpsCertificate e chamado pelo instalador do servidor.
# A descoberta (Descoberta.ps1) e o -SomenteDiagnostico continuam read-only.
Set-StrictMode -Version Latest

function Get-SgbMatchingHostnameCertificates {
    param([Parameter(Mandatory=$true)][string]$Fqdn)
    $found = @(
        foreach ($store in @('My', 'WebHosting')) {
            $path = 'Cert:\LocalMachine\' + $store
            if (-not (Test-Path -LiteralPath $path)) { continue }
            foreach ($cert in @(Get-ChildItem -LiteralPath $path -ErrorAction Stop)) {
                $hasSan = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Count -gt 0
                if (-not $hasSan) { continue }
                $match = @($cert.DnsNameList | Where-Object {
                    Test-SgbCertificateDnsName -DnsName $_.Unicode -Hostname $Fqdn
                })
                if ($match.Count -gt 0) { $cert }
            }
        }
    )
    return $found
}

function Assert-SgbCanIssueLocalCertificate {
    param([Parameter(Mandatory=$true)][string]$Fqdn)
    $existing = @(Get-SgbMatchingHostnameCertificates -Fqdn $Fqdn)
    if ($existing.Count -gt 0) {
        throw "Ja existe certificado com SAN compativel para $Fqdn, mas ele nao passou na validacao. Nao sera gerado outro certificado para mascarar falhas de confianca, validade ou acesso a chave."
    }
    # Kestrel seleciona por Subject: nunca introduzir nomes ambiguos.
    foreach ($store in @('My','WebHosting')) {
        $path = 'Cert:\LocalMachine\' + $store
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($cert in @(Get-ChildItem -LiteralPath $path -ErrorAction Stop)) {
            $subjectName = $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            if ($subjectName -ieq $Fqdn) {
                throw "Ja existe certificado com Subject $Fqdn em LocalMachine/$store; geracao local bloquearia a selecao inequivoca do Kestrel."
            }
        }
    }
    foreach ($command in @('New-SelfSignedCertificate','Export-Certificate','Import-Certificate')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Windows sem cmdlet necessario ao provisionamento local: $command"
        }
    }
}

function New-SgbLocalHttpsCertificate {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Fqdn)
    $current = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'A emissao local de certificado requer PowerShell elevado (Administrador).'
    }
    Assert-SgbCanIssueLocalCertificate -Fqdn $Fqdn
    Write-Warning "Nenhuma PKI adequada localizada. Criando certificado LOCAL para $Fqdn; clientes remotos NAO confiarao nele automaticamente."
    # Nao e uma CA, nao exporta chave privada e nao introduz certificado coringa.
    $cert = New-SelfSignedCertificate -DnsName $Fqdn -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Type SSLServerAuthentication -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable -KeyUsage DigitalSignature,KeyEncipherment `
        -NotAfter ((Get-Date).AddYears(2)) -FriendlyName 'SGB-LAB HTTPS local automatico' `
        -ErrorAction Stop
    if (-not $cert -or -not $cert.HasPrivateKey) { throw 'A criacao do certificado local falhou ou nao produziu chave privada.' }
    $folder = Join-Path $env:ProgramData 'SGB-LAB\Certificados'
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    $publicPath = Join-Path $folder ('SGB-LAB-Servidor-' + $cert.Thumbprint + '.cer')
    # Exporta SOMENTE a parte publica; nunca um PFX ou chave privada.
    $null = Export-Certificate -Cert $cert -FilePath $publicPath -Type CERT -ErrorAction Stop
    $publicCert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicPath)
    if ($publicCert.Thumbprint -ne $cert.Thumbprint) { throw 'A copia publica nao corresponde ao certificado emitido.' }
    # A maquina servidora precisa confiar NO certificado que ela mesma acabou
    # de criar para que a verificacao TLS HTTPS local use a validacao normal.
    # Esta operacao afeta SOMENTE o Windows do servidor, nao DNS, GPO ou clientes.
    $null = Import-Certificate -FilePath $publicPath -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop
    $inRoot = @(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\Root' | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })
    if ($inRoot.Count -ne 1) { throw 'Certificado emitido, mas sua ancora de confianca local nao foi instalada corretamente.' }
    Write-Host "[AUTO/HTTPS] Certificado local criado: $($cert.Thumbprint)" -ForegroundColor Green
    Write-Host "[AUTO/HTTPS] Parte PUBLICA para distribuicao administrada: $publicPath" -ForegroundColor Cyan
    Write-Host "[SHA256 DO CER] $((Get-FileHash -LiteralPath $publicPath -Algorithm SHA256).Hash)" -ForegroundColor Cyan
    Write-Warning 'Outras maquinas precisam confiar explicitamente neste certificado publico (por GPO/PKI ou distribuicao administrada) para acessar o Dashboard sem erros TLS.'
    return $cert
}
