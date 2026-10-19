# SGB-LAB

Inventário e diagnóstico de estações Windows, com servidor central e Dashboard web.

**Versão:** `0.3.3-rc.1` · **Pacote:** revisão `6` · **Arquitetura:** `win-x64`  
**Status:** candidata a lançamento; validação em laboratório em andamento.

Este README acompanha o pacote compilado. No repositório-fonte, os guias
operacionais desta pasta são os mesmos selecionados para a distribuição.

## Recursos disponíveis

- Inventário de hardware, sistema operacional, domínio e interfaces de rede.
- Coleta de eventos e indicadores de saúde, incluindo desligamentos inesperados.
- Heartbeat e envio autenticado de diagnósticos por HTTPS.
- Dashboard com estado de conexão, alertas, última coleta e histórico.
- Prévia e sincronização de computadores do Active Directory por LDAPS,
  mediante configuração e permissões apropriadas.

## Componentes

| Componente | Versão | Função |
|---|---|---|
| Servidor / API | 0.3.3-rc.1 | Administração, inventário, SQLite e recebimento dos diagnósticos |
| Dashboard | 0.3.3-rc.1 | Consulta e administração pelo navegador |
| Relay | 0.3.3-rc.1 | Heartbeat, envio e confirmação do diagnóstico |
| Agente / diagnóstico | 0.2.2 | Coleta local por WMI e Event Log |

O diretório interno `publicado-v030` é mantido por compatibilidade e não indica
uma versão diferente do produto.

## Download e requisitos

Obtenha o ZIP compilado fornecido pela TI (ou por uma Release, quando disponível)
e extraia a pasta completa
`SGB-LAB`. Não utilize o ZIP automático de código-fonte do GitHub como instalador.

- Windows x64 e Windows PowerShell 5.1 para os scripts.
- Permissão de administrador para instalar serviços e configurar confiança.
- DNS e conectividade com o servidor, usando o nome presente no certificado HTTPS.
- Certificado válido e confiável nas máquinas que acessarão o servidor.

Os executáveis são autocontidos: as máquinas de destino não precisam de SDK
.NET, Node.js, npm ou WinGet. O pacote não inclui tokens, contas, banco de dados
operacional ou certificado específico de uma organização.

## Instalação

Abra PowerShell como administrador na pasta extraída e escolha o perfil:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Instalar-SGB-LAB.ps1
```

| Perfil | Instalação |
|---|---|
| Servidor | API e Dashboard no servidor central |
| Laboratório | Agente de diagnóstico e Relay na estação |
| TI | Atalho para acesso ao Dashboard; não instala ambiente de desenvolvimento |

### Servidor novo

**1. Prepare o servidor e copie o pacote.**

Use Windows x64, uma conta administradora e um IPv4 privado estável. Configure o
DNS para que o nome completo (FQDN) do servidor resolva para esse IP, tanto no
servidor quanto nas estações. O instalador detecta o FQDN do Windows; o certificado
HTTPS precisa corresponder a esse nome. Não use o IP no lugar do FQDN ao acessar
o Dashboard.

Copie a pasta compilada `SGB-LAB` inteira para o servidor. Ela deve conter
`Instalar-SGB-LAB.ps1`, `scripts` e `publicado-v030\Server`.
Abra **Windows PowerShell como administrador** nessa pasta. Os exemplos abaixo
usam IP, rede e FQDN fictícios: substitua pelos valores reais do seu ambiente.

**2. Confira rede e certificado antes de instalar.**

```powershell
Resolve-DnsName 'servidor.empresa.example'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Instalar-SGB-LAB.ps1 `
    -Perfil Servidor -ServerIp '10.20.30.10' -SomenteDiagnostico
```

O diagnóstico não instala o serviço nem emite certificado. Se não houver
certificado compatível, a instalação efetiva poderá criar um certificado local
autoassinado. Para usar somente um certificado já provisionado pela organização,
acrescente `-NaoCriarCertificadoLocal` na instalação.

Deixe livres as portas **5080** (ativação local temporária) e **5443** (HTTPS).
Se estiver executando o DEV nessa máquina, encerre-o pela pasta do código-fonte
com `Iniciar-TI.ps1 -Acao Parar`.

**3. Execute a instalação e escolha se deseja recuperar um banco.**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Instalar-SGB-LAB.ps1 `
    -Perfil Servidor `
    -ServerIp '10.20.30.10' `
    -RedePermitida '10.20.30.0/24'
```

`-ServerIp` seleciona o IPv4 local; o FQDN continua sendo detectado automaticamente.
`-RedePermitida` cria uma regra de entrada para a porta 5443, restrita à rede
privada informada e aos perfis de firewall Domínio/Privado. Sem esse parâmetro,
nenhuma exceção é criada; a administração da rede deverá permitir o acesso necessário.

Na pergunta sobre recuperar um backup, responda **N** para uma instalação nova.
Para recuperação, responda **S** e informe a pasta de backup ou o arquivo `.db`.
Um banco local existente é preservado quando não há restauração; a substituição
por backup exige confirmação e backup prévio. Consulte
[Backup e recuperação](docs/DESINSTALAR.md).

**4. Crie o primeiro administrador no próprio servidor.**

Mantenha o terminal aberto. Quando aparecer o código temporário de ativação:

1. Abra **http://127.0.0.1:5080** no navegador do próprio servidor.
2. Informe o código exibido no terminal, escolha o usuário e uma senha de pelo
   menos 12 caracteres e conclua o cadastro.
3. Volte ao terminal e pressione **Enter** somente depois de concluir o cadastro.

O código de ativação não é a senha da conta. O endereço HTTP é usado apenas
durante essa etapa local. Se o banco recuperado já possui administrador, o
instalador preserva a conta e dispensa novo cadastro.

**5. Verifique o serviço e o acesso HTTPS.**

Aguarde o instalador confirmar o serviço e a validação HTTPS. Depois, execute:

```powershell
Get-Service SgbLabServer
Test-NetConnection 'servidor.empresa.example' -Port 5443
Invoke-RestMethod -Uri 'https://servidor.empresa.example:5443/api/health'
```

O serviço deve estar em **Running** e a API deve retornar `status: ok`.
Abra **https://servidor.empresa.example:5443** e entre com a conta criada.
Repita a verificação de HTTPS de uma estação autorizada após provisionar a
confiança no certificado. Não ignore erros de certificado: confira nome, DNS,
validade e cadeia de confiança.

Os binários ficam em `%ProgramFiles%\SGB-LAB\Server` e o banco em
`%ProgramData%\SGB-LAB\Server\sgblab.db`. Se a ativação inicial falhar,
consulte `setup.out.log` e `setup.err.log` em
`%ProgramData%\SGB-LAB\Server\Logs`.

**6. Prepare as estações.**

Se usou certificado local, exporte o certificado público e anote seu SHA-256
conforme [Instalar uma estação](docs/INSTALAR-ESTACAO.md). Provisione a confiança
nas máquinas TI/Laboratório antes de acessar o servidor. Para certificados da
organização, use o processo da PKI/GPO.

No Dashboard, cadastre cada hostname e obtenha seu token individual. Em seguida,
instale os perfis TI/Laboratório. A integração com AD é opcional e pode ser
configurada depois que o servidor e o acesso HTTPS estiverem funcionando.

Para um servidor já instalado, consulte
[Atualização do servidor](docs/ATUALIZAR-SERVIDOR.md). O instalador de servidor novo
não sobrescreve um serviço existente; o atualizador tem escopo específico.

### Estação de laboratório

No Dashboard, cadastre o hostname exato da estação e copie seu token individual.
Em uma estação que já confie no HTTPS do servidor:

```powershell
.\Instalar-SGB-LAB.ps1 -Perfil Laboratorio `
    -ServerUrl 'https://servidor.empresa.example:5443' `
    -SolicitarToken
```

Substitua o endereço de exemplo pelo endereço real. Cole o token somente no
campo protegido. O token não deve ser inserido no comando nem publicado.
Recadastrar o mesmo hostname invalida a credencial anterior.

Para importar o certificado público local com verificação de SHA-256 no mesmo
fluxo, siga [Instalar uma estação](docs/INSTALAR-ESTACAO.md).
Certificados de uma PKI devem ser provisionados pela administração da PKI/GPO.

### Verificar o funcionamento

```powershell
.\scripts\Perfis\Testar-Estacao.ps1
```

O teste exige os serviços ativos, uma coleta recente da própria estação e
confirmação do diagnóstico no servidor. Ele envia dados reais da estação.
No Dashboard, confirme **Online**, identificação, hardware e data da última coleta.
Um estado **Atenção** pode representar um alerta de saúde real, mesmo com a
comunicação funcionando. Heartbeat e diagnóstico possuem ciclos separados.

## Estado da entrega

Um piloto real confirmou autenticação, HTTPS confiável, serviços, recebimento
e exibição do diagnóstico no Dashboard. Nesse piloto, a criação do Relay exigiu
reparo manual; a correção está incorporada desde a revisão 3.

As revisões 4 a 6 organizam o pacote público, retiram símbolos de depuração,
usam exemplos genéricos e acrescentam desinstalação com backup e recuperação.
Ainda falta validar o ciclo completo da revisão 6 no Windows e a retomada
após reinicialização. Consulte [Recursos e limites](docs/ESTADO-DA-ENTREGA.md).

Não estão implementados: controle remoto de tela, desligamento/bloqueio remoto,
atualização remota silenciosa e atualização automática do Relay. Renovação e
distribuição central de certificados/credenciais ainda exigem planejamento.

## Integridade e dados locais

A distribuição inclui `SHA256SUMS.txt` para conferir os arquivos e o manifesto
usado pelo instalador do agente. Hashes não substituem assinatura digital nem
comprovam, sozinhos, a origem de um download.

Os binários são instalados em `%ProgramFiles%\SGB-LAB`; configurações, banco,
credenciais e diagnósticos ficam sob `%ProgramData%\SGB-LAB`. Esses dados
operacionais não devem ser adicionados ao repositório público ou privado.

Não publique tokens, senhas, bancos, logs com dados internos ou chaves privadas
em Issues, capturas ou anexos. Para relatar falhas, informe a revisão do pacote,
a etapa e a mensagem de erro, removendo dados sensíveis.

## Revisão 6: backup e recuperação do servidor

O desinstalador do perfil Servidor para o serviço, cria e valida o backup do banco,
informa seu caminho e só então remove o serviço. O instalador pergunta se deseja
recuperar um backup e solicita o caminho. Se já houver banco, exige confirmação e
faz backup dele antes da troca. Veja [Desinstalação e recuperação](docs/DESINSTALAR.md).

Auxiliares ficam em `scripts/Perfis`; use os pontos de entrada da raiz.
Gere novamente a distribuição completa na TI. Validação Windows ainda pendente.
