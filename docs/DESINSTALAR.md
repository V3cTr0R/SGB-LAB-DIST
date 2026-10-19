# Desinstalação e recuperação — revisão 6

Execute a distribuição completa gerada na TI, em PowerShell 64 bits. Os perfis
auxiliares ficam em `scripts/Perfis`; utilize os pontos de entrada da raiz.

## Servidor: remoção com backup automático

```powershell
# Prévia: não para nem altera o servidor
.\Desinstalar-SGB-LAB.ps1 -Perfil Servidor
# Aplicar como administrador
.\Desinstalar-SGB-LAB.ps1 -Perfil Servidor -Aplicar
```

O script localiza o banco pela configuração SGB_DB_PATH do serviço (ou pelo
caminho padrão), verifica a ferramenta do pacote e:

1. Para SgbLabServer e aguarda a parada.
2. Gera uma cópia consistente pela API de backup do SQLite, incluindo transações
   presentes no WAL, verifica integridade e estrutura SGB-LAB e grava SHA-256.
3. Salva também appsettings.json, quando presente, para consulta administrativa.
4. Informa a pasta do backup validado.
5. Somente depois exclui o serviço e arquiva a pasta de instalação.

Se o banco estiver ausente, inválido ou o backup falhar, a remoção é bloqueada.
Se o serviço estava em execução, o script tenta reiniciá-lo após falha de backup
ou parada. Se o reinício falhar, o erro é exibido; não há promessa de recuperação
incondicional. Falhas posteriores na exclusão/movimentação podem deixar uma
remoção parcial, com backup e arquivos preservados.

Pasta padrão, considerando ProgramData em C:\ProgramData:

```text
C:\ProgramData\SGB-LAB\Backups\Servidor\<data-hora-identificador>
```

A pasta é protegida para administradores e SYSTEM. Copie a pasta inteira para
um local de recuperação confiável; uma cópia no mesmo disco não protege contra
falha do disco. Não publique backups: incluem contas, credenciais e inventário.
Certificados/chaves privadas não são exportados. Uma recuperação em outro
servidor exige certificado HTTPS adequado nesse servidor.

## Reinstalação e recuperação

```powershell
.\Instalar-SGB-LAB.ps1 -Perfil Servidor
```

O instalador pergunta se deseja recuperar um banco antigo e solicita a pasta do
backup ou o caminho de um arquivo .db. Também é possível informar antecipadamente:

```powershell
.\Instalar-SGB-LAB.ps1 -Perfil Servidor -BackupBanco 'E:\Backups\Servidor\backup-escolhido'
```

O backup passa por validação de integridade e esquema SQLite; se houver
backup.json, seu SHA-256 precisa conferir. Um .db sem manifesto é aceito com aviso
sobre procedência e também precisa passar na validação. Selecione somente cópias
confiáveis, sem outro processo gravando nelas.

Se houver banco local, é necessário digitar RESTAURAR. Antes de substituí-lo, o
instalador faz outro backup validado dele. Se o banco local estiver corrompido e
não puder ser copiado/validado, a restauração automática é bloqueada para tratamento
administrativo. O banco original e seus arquivos auxiliares também são preservados
com sufixo `.before-restore-<identificador>`; arquivos WAL antigos nunca acompanham
o banco restaurado. Arquivos em uso bloqueiam a troca. Não execute dois instaladores
ou processos de banco simultaneamente.

Responder N preserva o banco local existente; só cria uma base nova se não houver
banco. Restaurar não redefine a senha do administrador. Contas, tokens, histórico e
mapeamentos armazenados no banco são recuperados conforme a data do backup.
O appsettings antigo é guardado para referência, mas não aplicado automaticamente:
HTTPS é configurado para a máquina de destino. Confira a integração AD após instalar.
Se a instalação falhar depois da restauração, o banco restaurado fica no destino,
e o backup do banco anterior permanece disponível; o instalador não reverte a
restauração automaticamente.

## Laboratório e TI

```powershell
.\Desinstalar-SGB-LAB.ps1 -Perfil Laboratorio -Aplicar
.\Desinstalar-SGB-LAB.ps1 -Perfil TI -Aplicar
.\Instalar-SGB-LAB.ps1 -Acao TestarEstacao
```

Laboratorio remove coletor e Relay; TI remove apenas o atalho do usuário atual.
O perfil TI dispensa administrador. Sem -Aplicar, ambos apenas mostram o plano.
Não existe perfil Todos; uma máquina pode acumular funções. `-Aplicar -WhatIf`
também permite conferir a intenção sem executar. Se um serviço ficar marcado
para exclusão, feche o console Serviços e reinicie se necessário antes de repetir.
Os binários são arquivados em Program Files\SGB-LAB\Desinstalados. Dados em
ProgramData, certificados, regras de firewall e cadastro remoto são preservados.
Revogue o token remoto se a estação for retirada de uso.

## Preparar e validar

Extraia o fonte em uma pasta nova e execute na TI:

```powershell
.\Iniciar-TI.ps1 -Acao GerarDistribuicao
```

Copie a distribuição completa. Não copie somente o script: o novo binário do
servidor contém o utilitário de backup, que encerra antes de iniciar o host web.
Não é preciso atualizar a instalação ativa para usar o desinstalador novo.

Compilação do servidor e testes SQLite reais passaram no Linux/.NET 10; parser
passou no PowerShell 7.6. Testes do módulo com serviços/ACL simulados confirmaram
restauração, preservação do original e bloqueio por hash divergente e serviço
existente. Isso não valida SCM/ACL/PowerShell 5.1 no Windows. Faça o ciclo completo
em ambiente de teste antes da remoção do servidor em uso.
