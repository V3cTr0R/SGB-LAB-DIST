# Ponto de entrada por papel. Windows PowerShell 5.1, terminal atual.
[CmdletBinding()]
param(
    [ValidateSet('Instalar','TestarEstacao')][string]$Acao = 'Instalar',
    [ValidateSet('','Servidor','Laboratorio','TI')][string]$Perfil = '',
    [string]$BackupBanco = '',
    [string]$ServerUrl = '',
    [string]$ServerIp = '',
    [string]$RedePermitida = '',
    [switch]$PermitirBuildLocal,
    [switch]$NaoCriarCertificadoLocal,
    [switch]$SomenteDiagnostico,
    [switch]$SolicitarToken,
    [switch]$Atualizar,
    [string]$ThumbprintEsperado = '',
    [string]$ArquivoCer = '',
    [string]$Sha256Esperado = ''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=$PSScriptRoot
if ($Acao -eq 'TestarEstacao') {
    & (Join-Path $root 'scripts\Perfis\Testar-Estacao.ps1')
    return
}
if (-not $Perfil) {
    Write-Host '=== SGB-LAB - Instalacao por perfil ===' -ForegroundColor Cyan
    Write-Host '1 - Servidor central'
    Write-Host '2 - Estacao de laboratorio (agente + relay)'
    Write-Host '3 - Estacao do TI (acesso ao Dashboard)'
    $choice=Read-Host 'Escolha 1, 2 ou 3'
    $Perfil=switch($choice){ '1'{'Servidor'} '2'{'Laboratorio'} '3'{'TI'} default{throw 'Perfil invalido.'} }
}
if ($BackupBanco -and ($Perfil -ne 'Servidor' -or $SomenteDiagnostico -or $Atualizar -or $Acao -ne 'Instalar')) { throw '-BackupBanco requer instalacao do perfil Servidor.' }
# Confianca explicita: nunca importar certificados em modo somente diagnostico.
if ($ArquivoCer -or $Sha256Esperado) {
    if (-not $ArquivoCer -or -not $Sha256Esperado -or -not $ServerUrl) {
        throw 'Informe juntos -ArquivoCer, -Sha256Esperado e -ServerUrl.'
    }
    if ($Perfil -eq 'Servidor' -or $Atualizar) { throw 'Importacao de confianca disponivel somente para estacoes TI/Laboratorio.' }
    if ($SomenteDiagnostico) { throw 'SomenteDiagnostico nao importa certificados. Execute sem -ArquivoCer/-Sha256Esperado para consultar a confianca atual.' }
    if ($Perfil -eq 'Laboratorio' -and (Get-Service SgbLabRelay -ErrorAction SilentlyContinue)) {
        throw 'Relay ja instalado; nenhuma confianca foi alterada. Atualizacao de Relay ainda nao homologada.'
    }
    & (Join-Path $root 'Confiar-Servidor.ps1') -ArquivoCer $ArquivoCer -Sha256Esperado $Sha256Esperado -ServerUrl $ServerUrl
}
if ($Atualizar) {
    if ($Perfil -ne 'Servidor') { throw 'Atualizacao integrada disponivel somente para o perfil Servidor.' }
    if (-not $ServerUrl -or -not $ThumbprintEsperado) { throw 'Informe -ServerUrl e -ThumbprintEsperado do servidor ativo.' }
    & (Join-Path $root 'Atualizar-Servidor.ps1') -Distribuicao $root -ServerUrl $ServerUrl -ThumbprintEsperado $ThumbprintEsperado -Aplicar:(-not $SomenteDiagnostico)
    return
}
if ($SomenteDiagnostico) {
    . (Join-Path $root 'scripts\Instalacao\Descoberta.ps1')
    . (Join-Path $root 'scripts\Instalacao\CertificadoLocal.ps1')
    if ($Perfil -eq 'Servidor') {
        $fqdn = Get-SgbLocalFqdn
        Write-Host "[DIAGNOSTICO] FQDN: $fqdn" -ForegroundColor Cyan
        $problems = New-Object 'System.Collections.Generic.List[string]'
        try {
            $ip = Resolve-SgbLocalServerIp -Fqdn $fqdn -RequestedIp $ServerIp
            Write-Host "[OK/REDE] IPv4 do servidor: $ip" -ForegroundColor Green
        } catch {
            Write-Warning "[REDE] $($_.Exception.Message)"
            $problems.Add('rede')
        }
        try {
            $selected = Find-SgbServerCertificate -Fqdn $fqdn
            Write-Host "[OK/HTTPS] Certificado: $($selected.Certificate.Thumbprint) | Store: $($selected.Store)" -ForegroundColor Green
        } catch {
            $certificateError = $_.Exception.Message
            # Se nenhum certificado apresenta SAN correspondente, o instalador
            # pode emitir um LOCAL, sem perguntar e sem alterar o diagnostico.
            $matching = @(Get-SgbMatchingHostnameCertificates -Fqdn $fqdn)
            if ($matching.Count -eq 0 -and -not $NaoCriarCertificadoLocal) {
                try {
                    Assert-SgbCanIssueLocalCertificate -Fqdn $fqdn
                    Write-Host "[AUTO/HTTPS] Nenhum certificado existente para $fqdn. Na instalacao normal sera emitido certificado local e sua parte publica sera confiada SOMENTE neste servidor." -ForegroundColor Yellow
                    Write-Warning 'Outras estacoes precisarao receber a confianca no certificado publico por canal administrado. Nenhuma escrita foi feita no diagnostico.'
                } catch {
                    Write-Warning "[HTTPS] Nao e possivel emitir certificado local com seguranca: $($_.Exception.Message)"
                    $problems.Add('certificado')
                }
            } else {
                Write-Warning "[HTTPS] $certificateError"
                $problems.Add('certificado')
            }
        }
        if ($problems.Count -gt 0) {
            Write-Host '[DIAGNOSTICO CONCLUIDO] Ambiente consultado sem alteracoes.' -ForegroundColor Cyan
            Write-Host "[BLOQUEADO] Instalacao do servidor impedida por: $($problems -join ', ')." -ForegroundColor Yellow
            if ($problems -contains 'certificado') {
                Write-Host '[PROXIMA ACAO] Corrigir o certificado existente/invalido ou disponibilizar certificado HTTPS valido via PKI. Se apropriado, remova -NaoCriarCertificadoLocal para permitir emissao local quando nenhum existe.' -ForegroundColor Yellow
                Write-Host '[SEGURANCA] Nenhum certificado foi criado, importado, modificado ou validado de forma permissiva.' -ForegroundColor Cyan
            }
            Write-Host '[RESULTADO] Pre-requisitos pendentes. Codigo de saida: 2.' -ForegroundColor Yellow
            exit 2
        }
        Write-Host '[DIAGNOSTICO CONCLUIDO] Rede valida; HTTPS existente ou emissao local prevista. Nenhuma instalacao foi executada.' -ForegroundColor Green
        exit 0
    } else {
        $url = Resolve-SgbServerUrl -RequestedUrl $ServerUrl
        Write-Host "[OK] Servidor SGB-LAB HTTPS: $url" -ForegroundColor Green
        if ($Perfil -eq 'Laboratorio') {
            $credential = if ($SolicitarToken) { Read-SgbRelayToken } else { Get-SgbProvisionedRelayToken -ServerUrl $url -HostName $env:COMPUTERNAME }
            try { Test-SgbAgentCredential -ServerUrl $url -HostName $env:COMPUTERNAME -Token $credential }
            finally { Remove-Variable credential -ErrorAction SilentlyContinue }
            Write-Host '[OK] Credencial individual aceita pelo servidor (valor nao exibido).' -ForegroundColor Green
        }
    }
    return
}
switch ($Perfil) {
    'Servidor' {
        & (Join-Path $root 'scripts\Perfis\Instalar-Servidor.ps1') -BackupBanco $BackupBanco -ServerIp $ServerIp -RedePermitida $RedePermitida -PermitirBuildLocal:$PermitirBuildLocal -NaoCriarCertificadoLocal:$NaoCriarCertificadoLocal
    }
    'Laboratorio' {
        & (Join-Path $root 'scripts\Perfis\Instalar-Laboratorio.ps1') -ServerUrl $ServerUrl -SolicitarToken:$SolicitarToken
    }
    'TI' {
        & (Join-Path $root 'scripts\Perfis\Instalar-TI.ps1') -ServerUrl $ServerUrl
    }
}
Write-Host '[INFO] Conclua as validacoes especificas de cada perfil antes do piloto.'
