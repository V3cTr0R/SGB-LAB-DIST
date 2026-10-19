# Atualizar SgbLabServer existente — 0.3.2-setup1 para 0.3.3-rc.1

O atualizador usa os binários autocontidos já compilados na distribuição.
Não exige SDK, Node ou nova compilação no servidor. A conta e o inventário
continuam no banco instalado; o banco DEV não deve ser copiado.

## Uso inicial: somente consulta

Abra PowerShell como Administrador, na pasta da distribuição.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Atualizar-Servidor.ps1 `
  -ServerUrl 'https://servidor.empresa.example:5443' `
  -ThumbprintEsperado 'THUMBPRINT_DO_CERTIFICADO_ATIVO'
```

Substitua o endereco e o thumbprint pelos valores do seu servidor.
Obtenha e confira o certificado ativo antes de informar o valor.
Sem `-Aplicar`, o atualizador não escreve arquivos nem para o serviço.

## Aplicar após diagnóstico OK

O mesmo comando com `-Aplicar` provoca indisponibilidade durante backup, cópia
e validação. Faça em janela sem uso do sistema. Não encerre o PowerShell.

1. Confere produto/versão dos binários, instalação padrão, serviço LocalSystem,
   caminho de banco, DNS, porta pertencente ao processo e HTTPS confiável.
2. Para SgbLabServer e copia os binários e todo o diretório de dados, incluindo
   eventuais arquivos WAL/SHM do SQLite. Confere SHA-256 das cópias.
3. Protege o backup para SYSTEM e Administradores.
4. Prepara uma cópia da instalação, sobrepõe os binários publicados e restaura
   os appsettings locais byte a byte. Preserva arquivos locais adicionais.
5. Troca as pastas, inicia o serviço e exige API 0.3.3-rc.1, administrador
   configurado em produção e o mesmo certificado TLS esperado.
6. Em falha, tenta restaurar binários e dados anteriores e verificar a API antiga.
   Backup, diretórios anteriores e dados de falha são preservados.

O caminho do backup é exibido no terminal, dentro de
`%ProgramData%\SGB-LAB\Backups\Server`.
Depois do sucesso, abra o Dashboard HTTPS e confira login, inventário e AD.
O diagnóstico não acessa inventário protegido com a senha do administrador.

## Certificados duplicados

O atualizador preserva a configuração atual por Subject e não exclui nem cria
certificados. Confere o certificado realmente apresentado antes e depois do
reinício. Não muda a seleção para thumbprint no Kestrel. Se o certificado mudar,
a atualização falha e tenta recuperação. A duplicidade continua existindo e o
instalador de primeira instalação ainda pode recusá-la. Seleção explícita e
renovação são melhorias posteriores, não pré-requisitos para essa atualização
com o endpoint atual validado.

## Limites e validação

Escopo: serviço padrão `SgbLabServer`, executável em Program Files/SGB-LAB/Server,
LocalSystem, banco padrão ProgramData/SGB-LAB/Server/sgblab.db, origem
0.3.2-setup1 e destino 0.3.3-rc.1, certificado LocalMachine/My e binding IPv4 local.
Configurações personalizadas são bloqueadas antes de alterações.

Testados nesta revisão: parser e transação com filesystem temporário e serviços/TLS
simulados, incluindo sucesso, falha de backup, falha de cópia e falha de saúde,
com preservação de configurações e restauração de banco/WAL.
O registro do piloto relata atualização concluída e Dashboard 0.3.3-rc.1 observado;
isso não comprova recuperação de uma falha real. Rollback é melhor esforço;
falhas de disco, permissão ou serviço podem exigir recuperação manual.
A janela deve ser exclusiva: não executar outra atualização, editar o banco
manualmente ou usar o Dashboard durante a operação.

O ponto de entrada atualizado também aceita:
`Instalar-SGB-LAB.ps1 -Perfil Servidor -Atualizar -SomenteDiagnostico -ServerUrl ... -ThumbprintEsperado ...`.
Retirar `-SomenteDiagnostico` desse modo aplica a atualização. Para a distribuição
já copiada antes deste complemento, basta adicionar Atualizar-Servidor.ps1 e usar
o comando direto; não é necessário substituir binários.
