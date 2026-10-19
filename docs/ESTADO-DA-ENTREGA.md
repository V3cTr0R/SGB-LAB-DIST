# Estado da entrega 0.3.3-rc.1

## Alterado nesta candidata

- Entrada `Iniciar-TI.ps1`: verificar, desenvolver, parar e gerar distribuição.
- Metadados de produto/componentes em `release.json`, API e UI identificadas.
- Coletor 0.2.2 preservado; nenhum novo coletor ou recurso de controle remoto.
- Banco do bootstrap fixado no destino e variáveis do DEV restauradas.
- Certificado local público com hash SHA-256; importação cliente explícita,
  vinculada ao nome, hash e teste HTTPS, com reversão da nova confiança em falha.
- Token interativo protegido opt-in e validação autenticada antes da instalação.
- Endpoint autenticado `/api/agent/status`, restrito à máquina do token.
- Relay confirma leitura da coleta persistida; `--once` falha sem snapshot.
- Teste final exige snapshot recente da estação e recibo no servidor.
- Painel distingue saúde normal de ausência de dados e explica heartbeat.
- Correção de sintaxe no script herdado que encerra DEV (`${nome}:`).
- Token instalado tem precedência sobre variável de ambiente residual.
- Versão mínima de Node 22.12 verificada; nomes de serviço alinhados ao SCM.
- Lockfile npm incluído; testes do Relay adicionados e executados pelo gerador.
- Verificações Python deixam de varrer dependências de terceiros em node_modules.

## Organização do painel (atualização em desenvolvimento)

- Menu com grupos e subgrupos persistidos no SQLite, edição e movimentação.
- Inventário por categoria e área Sem grupo; Dashboard reservado a indicadores e AD.
- Configuração AD organizada em configurar, visualizar prévia e sincronizar.
- Detalhes em janela central, com hardware, rede, eventos, histórico e JSON.
- Atribuição manual por máquina ou automática pelo identificador de laboratório/AD.
- Migração dos laboratórios existentes sem alterar credenciais e coletas.
- Coletor 0.2.2 preservado: a interface exibe mais dos dados já coletados.
- Esta atualização ainda exige validação visual e operacional no ambiente Windows/AD
  antes de gerar e homologar a próxima SGB-LAB-DIST.

## Disponível no código herdado

Autenticação administrativa, SQLite, inventário, histórico, regras de saúde,
coleta WMI/EventLog, heartbeat, atualização do painel e prévia/sincronização AD
via LDAPS. A configuração AD é desativada por padrão. A integração usa identidade
Windows; não distribua senha de domínio no projeto.

## Validado no piloto em 17/10/2026

- Build/distribuição na TI em Windows PowerShell 5.1, sem compilação na estação.
- Dashboard 0.3.3-rc.1 em SERVIDOR e inventário AD do Laboratorio Piloto.
- ESTACAO-PILOTO: confiança HTTPS normal, token individual aceito, coletor 0.2.2
  e Relay em execução; heartbeat, diagnóstico e recibo HTTP 200.
- Coleta de 17:28 exibida no Dashboard, Online, hardware/domínio e histórico.
- Estado Atenção coerente com seis incidentes estimados de desligamento em 90 dias.
- A instalação exigiu reparo manual da criação do Relay. Não equivale a homologar
  o instalador sem intervenção. A revisão 3 incorpora o comando que funcionou.

## Revisão 3 do pacote

- Relay criado por New-Service com caminho entre aspas; sc.exe failure recebe
  argumentos separados e o código de saída é verificado.
- Entrada principal aceita CER/SHA-256 para confiança antes da instalação TI/Lab.
- Exportação do certificado ativo por TLS validado, sem chave privada.
- Roteiro curto em INSTALAR-ESTACAO.md. Binários e versões de componentes mantidos.

## Pendente antes de produção

- Executar a revisão 6 completa em uma nova estação Windows, sem reparos manuais.
- Reiniciar estação e servidor e confirmar retomada automática e novos dados.
- Renovação de certificado e distribuição central de confiança/credenciais.
- Atualização do Relay, rollback real de falha do servidor e migração entre máquinas.
- Assinatura dos artefatos e lock completo de pacotes NuGet.
- Validar AD/LDAPS nas OUs e permissões do ambiente de trabalho; um laboratório
  não comprova todos os cenários de diretório.

## Fora do escopo implementado

Controle remoto/transmissão de tela, desligamento ou bloqueio remoto de estações,
SgbWatcher adicional, atualização remota silenciosa e auditoria abrangente de
operações. Há histórico de diagnóstico e registros de sincronização AD; isso
não equivale a um módulo completo de auditoria.

A passagem dos testes de código não promove automaticamente esta RC a versão
estável. O roteiro do piloto é o critério de aceite; somente os resultados
observados no ambiente do usuário devem ser marcados como homologados.

## Complemento de atualização

Atualizador do servidor 0.3.2-setup1 para 0.3.3-rc.1 implementado com backup,
validação HTTPS e tentativa de rollback. Testes simulados aprovados; atualização no piloto relatada como concluída,
com Dashboard 0.3.3-rc.1 observado. Rollback em falha real ainda pendente. Atualizador do Relay e migração entre máquinas seguem pendentes.
Veja `ATUALIZAR-SERVIDOR.md`.

## Revisões 4 a 6 incorporadas

- Revisão 4: pacote com seleção explícita de arquivos, exemplos genéricos,
  configurações de fábrica e publicação sem símbolos de depuração.
- Revisão 5: auxiliares em `scripts/Perfis` e desinstalação por perfil.
- Revisão 6: backup SQLite validado antes da remoção do servidor e recuperação
  opcional na reinstalação, preservando o banco anterior.

O ciclo completo de remoção/recuperação com SCM, ACLs e PowerShell 5.1 ainda
precisa de validação Windows. Os resultados anteriores do piloto não homologam
automaticamente a revisão 6. Veja [Desinstalar e recuperar](DESINSTALAR.md).
