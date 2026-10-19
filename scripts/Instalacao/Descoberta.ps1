# SGB-LAB: descoberta do ambiente. Somente leitura (nao altera DNS, certificados ou GPO).
# Requer Windows PowerShell 5.1 no Windows de destino.
Set-StrictMode -Version Latest

function Get-SgbLocalFqdn {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $hostName = [string]$env:COMPUTERNAME
    if ($cs.PartOfDomain -and -not [string]::IsNullOrWhiteSpace([string]$cs.Domain)) {
        return ($hostName + '.' + [string]$cs.Domain).ToLowerInvariant()
    }
    $domain = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    if (-not [string]::IsNullOrWhiteSpace($domain)) {
        return ($hostName + '.' + $domain).ToLowerInvariant()
    }
    return $hostName.ToLowerInvariant()
}

function Test-SgbPrivateIpv4 {
    param([Parameter(Mandatory=$true)][string]$Address)
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $oct = $ip.GetAddressBytes()
    return (($oct[0] -eq 10) -or ($oct[0] -eq 172 -and $oct[1] -ge 16 -and $oct[1] -le 31) -or
            ($oct[0] -eq 192 -and $oct[1] -eq 168))
}

function Select-SgbLocalIpv4Candidate {
    # Funcao pura: decide entre IPs JA confirmados simultaneamente no DNS e no host.
    # Nunca escolhe por ordem de retorno do DNS ou por menor endereco numerico.
    param([Parameter(Mandatory=$true)][object[]]$Candidates)
    $pool = @($Candidates | Sort-Object IPAddress -Unique)
    if ($pool.Count -eq 0) { throw 'Nenhum IPv4 candidato pertence ao host e ao DNS simultaneamente.' }
    if ($pool.Count -eq 1) { return $pool[0] }

    # Ordem de evidencias: dominio autenticado, rota padrao ativa, NIC fisica.
    # Interfaces virtuais NAO sao descartadas: em uma VM elas podem ser a interface principal.
    foreach ($field in @('DomainAuthenticated', 'HasDefaultRoute', 'HardwareInterface')) {
        $subset = @($pool | Where-Object { $_.$field -eq $true })
        if ($subset.Count -eq 1) { return $subset[0] }
        if ($subset.Count -gt 1) { $pool = $subset }
    }
    $details = @($pool | ForEach-Object {
        "$($_.IPAddress) [$($_.InterfaceAlias); dominio=$($_.DomainAuthenticated); rota=$($_.HasDefaultRoute); fisica=$($_.HardwareInterface)]"
    }) -join '; '
    throw "Multiplos IPv4 continuam igualmente elegiveis para o servidor: $details. A selecao automatica foi bloqueada por seguranca. Verifique o DNS e as rotas."
}

function Resolve-SgbLocalServerIp {
    param([Parameter(Mandatory=$true)][string]$Fqdn, [string]$RequestedIp = '')
    $localRecords = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.AddressState -eq 'Preferred' -and (Test-SgbPrivateIpv4 -Address $_.IPAddress)
    })
    $local = @($localRecords | Select-Object -ExpandProperty IPAddress -Unique)

    try {
        $resolved = @([Net.Dns]::GetHostAddresses($Fqdn) | Where-Object {
            $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
        } | ForEach-Object { $_.ToString() } | Select-Object -Unique)
    } catch {
        throw "DNS nao resolveu $Fqdn. O instalador nao adivinha o endereco de rede."
    }
    if ($RequestedIp) {
        if (-not (Test-SgbPrivateIpv4 -Address $RequestedIp) -or $RequestedIp -notin $local) {
            throw "O IPv4 informado nao pertence a uma interface local privada ativa: $RequestedIp"
        }
        if ($RequestedIp -notin $resolved) { throw "O DNS de $Fqdn nao aponta para $RequestedIp." }
        return $RequestedIp
    }

    $matching = @($localRecords | Where-Object { $_.IPAddress -in $resolved })
    if ($matching.Count -eq 0) {
        throw "O FQDN $Fqdn nao aponta para um IPv4 privado ativo desta maquina. DNS: $($resolved -join ', '); locais: $($local -join ', ')."
    }

    # Os tres cmdlets abaixo APENAS consultam o estado atual. Em sistemas onde
    # metadados nao estejam disponiveis, uma ambiguidade real permanece bloqueada.
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' })

    $candidates = @(
        foreach ($item in $matching) {
            $index = $item.InterfaceIndex
            $profile = @($profiles | Where-Object { $_.InterfaceIndex -eq $index -and $_.NetworkCategory -eq 'DomainAuthenticated' })
            $adapter = @($adapters | Where-Object { $_.InterfaceIndex -eq $index -and $_.Status -eq 'Up' } | Select-Object -First 1)
            $defaultRoute = @($routes | Where-Object { $_.InterfaceIndex -eq $index })
            [pscustomobject]@{
                IPAddress           = [string]$item.IPAddress
                InterfaceAlias      = [string]$item.InterfaceAlias
                DomainAuthenticated = ($profile.Count -gt 0)
                HasDefaultRoute     = ($defaultRoute.Count -gt 0)
                HardwareInterface  = ($adapter.Count -gt 0 -and $adapter[0].HardwareInterface -eq $true)
            }
        }
    )
    # A funcao pura retorna uma unica escolha ou uma excecao com candidatos detalhados.
    $selected = Select-SgbLocalIpv4Candidate -Candidates $candidates
    if ($matching.Count -gt 1) {
        Write-Host "[AUTO/REDE] $($matching.Count) IPv4 locais constam no DNS; selecionado $($selected.IPAddress) em '$($selected.InterfaceAlias)' (dominio=$($selected.DomainAuthenticated), rota=$($selected.HasDefaultRoute), fisica=$($selected.HardwareInterface))." -ForegroundColor Cyan
    }
    return [string]$selected.IPAddress
}

function Test-SgbCertificateDnsName {
    param([Parameter(Mandatory=$true)][string]$DnsName, [Parameter(Mandatory=$true)][string]$Hostname)
    $name = $DnsName.TrimEnd('.').ToLowerInvariant()
    $hostNorm = $Hostname.TrimEnd('.').ToLowerInvariant()
    if ($name -eq $hostNorm) { return $true }
    if ($name -notmatch '^\*\.([a-z0-9.-]+)$') { return $false }
    $suffix = $Matches[1]
    if (-not $hostNorm.EndsWith('.' + $suffix)) { return $false }
    $left = $hostNorm.Substring(0, $hostNorm.Length - $suffix.Length - 1)
    return ($left.Length -gt 0 -and -not $left.Contains('.'))
}

function Find-SgbServerCertificate {
    param([Parameter(Mandatory=$true)][string]$Fqdn)
    $now = Get-Date
    $candidates = @()
    $rejected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($store in @('My', 'WebHosting')) {
        $path = 'Cert:\LocalMachine\' + $store
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $all = @(Get-ChildItem -LiteralPath $path -ErrorAction Stop)
        foreach ($cert in $all) {
            # Moderno TLS exige SAN DNS. CN sozinho nao autoriza correspondencia.
            $san = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })
            if ($san.Count -eq 0) { continue }
            $names = @($cert.DnsNameList | ForEach-Object { $_.Unicode })
            if (@($names | Where-Object { Test-SgbCertificateDnsName -DnsName $_ -Hostname $Fqdn }).Count -eq 0) { continue }
            $why = ''
            if ($cert.NotBefore -gt $now -or $cert.NotAfter -le $now) { $why = 'fora do prazo de validade' }
            elseif (-not $cert.HasPrivateKey) { $why = 'sem chave privada' }
            else {
                $ekus = @($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId })
                # Extensao EKU ausente significa uso irrestrito; quando presente, exige Server Authentication.
                $ekuExtension = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }
                if ($ekuExtension -and '1.3.6.1.5.5.7.3.1' -notin $ekus) { $why = 'EKU nao permite autenticacao de servidor' }
            }
            if (-not $why) {
                $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
                try {
                    $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
                    $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
                    if (-not $chain.Build($cert)) { $why = 'cadeia nao confiavel ou revogacao nao verificavel' }
                } finally { $chain.Dispose() }
            }
            # A configuracao padrao do Kestrel seleciona por Subject, nao por thumbprint.
            # Recusar subject duplicado evita que ele carregue outro certificado.
            if (-not $why -and @($all | Where-Object { $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ieq $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }).Count -ne 1) {
                $why = 'Subject duplicado no repositório (selecao Kestrel ambigua)'
            }
            if ($why) {
                $rejected.Add("$store/$($cert.Thumbprint): $why")
            } else {
                $candidates += [pscustomobject]@{ Certificate = $cert; Store = $store; Fqdn = $Fqdn }
            }
        }
    }
    if ($candidates.Count -ne 1) {
        $details = if ($rejected.Count -gt 0) { $rejected -join '; ' } else { 'nenhum certificado com DNS SAN compativel' }
        throw "HTTPS exige exatamente um certificado confiavel com chave privada para $Fqdn em LocalMachine/My ou WebHosting; encontrados: $($candidates.Count). Diagnostico: $details. Nenhum certificado foi modificado."
    }
    return $candidates[0]
}

function Test-SgbServerHttps {
    param([Parameter(Mandatory=$true)][string]$ServerUrl)
    try { $uri = [uri]$ServerUrl } catch { return $false }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
        $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.UserInfo -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { return $false }
    try {
        $health = [uri]::new($uri, '/api/health')
        $req = [Net.WebRequest]::Create($health)
        $req.Proxy = $null
        $req.Timeout = 5000
        $resp = $req.GetResponse()
        try {
            if ([int]$resp.StatusCode -ne 200) { return $false }
            $reader = New-Object IO.StreamReader($resp.GetResponseStream())
            try { $json = $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
            return ($json.service -ceq 'SGB-LAB' -and $json.status -ceq 'ok')
        } finally { $resp.Dispose() }
    } catch { return $false }
}

function Resolve-SgbServerUrl {
    param([string]$RequestedUrl = '')
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($RequestedUrl) {
        $candidates.Add($RequestedUrl)
    } else {
        # Configuracao de implantacao, nao armazenada no projeto.
        if ($env:SGB_SERVER_URL) { $candidates.Add($env:SGB_SERVER_URL) }
        $existing = Join-Path $env:ProgramData 'SGB-LAB\Relay\relaysettings.json'
        if (Test-Path -LiteralPath $existing) {
            try {
                $saved = Get-Content -LiteralPath $existing -Raw | ConvertFrom-Json
                if ($saved.Relay.ServerUrl) { $candidates.Add([string]$saved.Relay.ServerUrl) }
            } catch { Write-Warning 'Configuracao anterior do Relay invalida; ignorada durante a descoberta.' }
        }
        $suffixes = New-Object 'System.Collections.Generic.List[string]'
        $fqdn = Get-SgbLocalFqdn
        if ($fqdn.Contains('.')) { $suffixes.Add($fqdn.Substring($fqdn.IndexOf('.') + 1)) }
        foreach ($suffix in @($suffixes | Select-Object -Unique)) {
            # Registro DNS SRV gerenciado pela infraestrutura: _sgb-lab._tcp.dominio
            try {
                $records = @(Resolve-DnsName -Name "_sgb-lab._tcp.$suffix" -Type SRV -ErrorAction Stop)
                foreach ($record in $records) {
                    if ($record.NameTarget -and $record.Port -gt 0 -and $record.Port -le 65535) {
                        $target = ([string]$record.NameTarget).TrimEnd('.')
                        $candidates.Add("https://${target}:$($record.Port)")
                    }
                }
            } catch { } # Registro SRV nao e obrigatorio, mas sem descoberta segura falha fechado.
        }
    }
    $unique = @($candidates | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') } | Select-Object -Unique)
    $valid = @($unique | Where-Object { Test-SgbServerHttps -ServerUrl $_ })
    if ($valid.Count -ne 1) {
        throw "Nao foi possivel identificar um unico SGB-LAB via HTTPS confiavel (candidatos: $($unique.Count); validos: $($valid.Count)). Configure DNS SRV _sgb-lab._tcp.<dominio> ou SGB_SERVER_URL de forma administrada. Nenhuma validacao TLS foi desabilitada."
    }
    return $valid[0]
}

function Get-SgbProvisionedRelayToken {
    param([Parameter(Mandatory=$true)][string]$ServerUrl, [Parameter(Mandatory=$true)][string]$HostName)
    if ($env:SGB_RELAY_TOKEN -and $env:SGB_RELAY_TOKEN.Length -ge 24) { return $env:SGB_RELAY_TOKEN }
    $existing = Join-Path $env:ProgramData 'SGB-LAB\Relay\relaysettings.json'
    if (Test-Path -LiteralPath $existing) {
        try {
            $saved = Get-Content -LiteralPath $existing -Raw | ConvertFrom-Json
            if ($saved.Relay.ServerUrl.TrimEnd('/') -ieq $ServerUrl.TrimEnd('/') -and
                $saved.Relay.HostName -ieq $HostName -and
                $saved.Relay.ApiToken -and $saved.Relay.ApiToken.Length -ge 24) {
                return [string]$saved.Relay.ApiToken
            }
        } catch { }
    }
    throw 'Token individual do Relay nao provisionado. O servidor requer cadastro autenticado no Dashboard. Distribua SGB_RELAY_TOKEN por mecanismo seguro autorizado antes de instalar; o instalador nao cria tokens nem solicita segredos.'
}

function Read-SgbRelayToken {
    $secret=Read-Host 'Cole o token individual emitido no Dashboard (entrada protegida)' -AsSecureString
    $pointer=[IntPtr]::Zero
    try {
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
        $value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim()
        if ($value.Length -lt 24 -or $value.Length -gt 256 -or $value -match '\s') { throw 'Token invalido.' }
        return $value
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        $secret.Dispose()
    }
}

function Test-SgbAgentCredential {
    param([string]$ServerUrl,[string]$HostName,[string]$Token)
    # GET nao cadastra maquina, nao atualiza heartbeat e nao mostra o segredo.
    $request=[Net.WebRequest]::Create($ServerUrl.TrimEnd('/') + '/api/agent/status')
    $request.Proxy=$null; $request.Timeout=10000
    $request.Headers['X-SGB-Agent']=$HostName
    $request.Headers['Authorization']='Bearer ' + $Token
    try {
        $response=$request.GetResponse()
        try {
            $reader=New-Object IO.StreamReader($response.GetResponseStream())
            try { $data=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            if ($data.hostName -ine $HostName) { throw 'Identidade do agente divergente.' }
        } finally { $response.Dispose() }
    } catch { throw 'Credencial nao validada. Confira HTTPS, versao 0.3.3-rc.1 da API e token cadastrado para o hostname desta estacao.' }
}

function Test-SgbPrivateCidr {
    param([string]$Cidr)
    if ($Cidr -notmatch '^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]{1,2})$') { return $false }
    $address=$Matches[1]; $prefix=[int]$Matches[2]
    if ($prefix -gt 32 -or -not (Test-SgbPrivateIpv4 -Address $address)) { return $false }
    $bytes=([Net.IPAddress]::Parse($address)).GetAddressBytes()
    $minimum=if ($bytes[0] -eq 10) { 8 } elseif ($bytes[0] -eq 172) { 12 } else { 16 }
    return ($prefix -ge $minimum)
}
