# Instalar uma nova estação

## Uma vez no servidor

Com a distribuição revisada, abra PowerShell e exporte o certificado ativo:

```powershell
.\Exportar-Certificado-Servidor.ps1 -ServerUrl 'https://servidor.empresa.example:5443'
```

O script valida o TLS normalmente e exporta apenas o CER público para a Área de
Trabalho. Anote o SHA-256 exibido diretamente no servidor. Copie o CER e a pasta
completa SGB-LAB-DIST\SGB-LAB por meio administrado, como o SSD usado no piloto.
Não exporte PFX/chave privada. O SHA-256 do arquivo não é o thumbprint do certificado.
O CER não é incluído automaticamente na distribuição genérica.
Para certificado emitido por uma PKI, distribua a cadeia pela administração da
PKI/GPO; a opção abaixo aceita apenas o certificado local autoassinado do SGB-LAB.

## Na estação

1. Confirme o nome com `hostname`.
2. No Dashboard HTTPS do servidor, clique em Cadastrar agente, informe esse nome
   e copie o token. Recadastrar o mesmo nome invalida o token anterior.
3. Abra PowerShell como Administrador na pasta SGB-LAB da distribuição e execute:

```powershell
.\Instalar-SGB-LAB.ps1 -Perfil Laboratorio `
    -ServerUrl 'https://servidor.empresa.example:5443' `
    -ArquivoCer 'C:\CAMINHO\servidor.empresa.example.cer' `
    -Sha256Esperado 'SUBSTITUA_PELO_SHA256_EXIBIDO_NO_SERVIDOR' `
    -SolicitarToken
```

Cole o token no campo protegido. Se a confiança já estiver configurada, omita
ArquivoCer e Sha256Esperado. Nenhum SDK ou Node é necessário na estação.
O perfil TI também aceita o CER/hash para configurar acesso ao painel; ele não
instala o coletor. A importação é recusada em SomenteDiagnostico.

O instalador valida certificado, API e token, instala coletor e Relay e confirma
um diagnóstico recente no servidor. A confiança recém-importada é revertida se
o teste HTTPS falhar; uma falha posterior na instalação não desfaz confiança
que já passou na validação. Não há rollback integral do instalador de estação.

No Dashboard, confira Online, identificação, hardware e última coleta. Atenção
pode indicar um alerta real coletado, mesmo com transporte funcionando.

## Se parar com erro

- Hash/nome/validade: confira CER e SHA-256 no servidor; não desative TLS.
- Token recusado: confira hostname e cadastro no Dashboard do servidor correto.
- Relay existente: o pacote bloqueia reinstalação/atualização desse componente.
- Coleta antiga no teste final: reinicie SgbLabDiagnostico, aguarde nova coleta e
  execute scripts\Perfis\Testar-Estacao.ps1. O coletor tem intervalo padrão de 60 minutos.
- Serviço criado mas parado: examine o erro de inicialização e os eventos antes
  de repetir a instalação. Não apague a configuração nem envie o token em prints.

## Piloto já instalado

Se uma estação piloto já estiver funcional, não execute novamente o instalador nela apenas para repetir o teste.
A revisão 3 corrige a criação do Relay para as próximas instalações.

## Reboot ainda pendente

Em uma janela adequada, reinicie primeiro a estação e confirme que os dois
serviços voltaram a Running, com coleta nova e estação Online. Depois valide a
reinicialização do servidor e a retomada do heartbeat. Uma coleta antiga não
implica falha de transporte: confira o intervalo de coleta e a hora do heartbeat.
Estes testes causam interrupção e não foram executados na evidência deste piloto.
