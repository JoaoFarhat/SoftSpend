# Backup diário do MySQL da EC2

Especificação, sem código. Vale para o banco de produção, que é um MySQL
**dentro da própria EC2** (sem RDS; ver `AGENTS.md`, "Bancos de dados"). Hoje
não existe nenhum backup: perder o disco da EC2 é perder cadastros, viagens,
gastos e assinaturas. O banco local de testes não entra.

## 1. Resumo das decisões

| Tema | Decisão |
| --- | --- |
| Ferramenta | `mysqldump` com `--single-transaction` (as tabelas são InnoDB, então não trava a API), compactado com `gzip` |
| Quando | Todo dia às 03:30 de Brasília (06:30 UTC), por **timer do systemd** com `Persistent=true` (se a EC2 estava desligada, roda ao ligar) |
| Para onde | Bucket S3 **só de backup**, na `sa-east-1`, separado do bucket dos comprovantes |
| Acesso | **Função IAM anexada à EC2** (sem chave de acesso no `.env`), só pode gravar e ler; **não pode apagar** |
| Retenção | **30 dias**, uma regra única de expiração do S3 (sem cópias mensais ou anuais; ver §5) |
| Antes de migration | Um dump extra, só quando há migration pendente no deploy (§6) |
| Teste de restauração | Primeiro à mão (§8.1); depois automático, 1 vez por mês (§8.2) |
| Perda máxima aceita (RPO) | 24 horas, mais o dump extra antes de migration |
| Tempo para voltar (RTO) | até 1 hora, seguindo o roteiro do §9 |

## 2. O que entra no dump

- Banco `softspend` inteiro: estrutura, dados, triggers e rotinas, em `utf8mb4`.
  Flags: `--single-transaction --quick --routines --triggers --no-tablespaces
  --default-character-set=utf8mb4 --set-gtid-purged=OFF` (a última só se a
  versão do MySQL aceitar; conferir com `mysql --version` no servidor).
- Inclui `alembic_version`, para saber a versão do schema na restauração.
- **Não entra:** o `.env` (segredos), os comprovantes (ficam no outro bucket)
  e o código (está no GitHub). Ver §10.
- O dump contém dados pessoais e financeiros e os hashes de senha (argon2).
  Por isso o bucket é privado, criptografado e a retenção é curta (§5).

## 3. Como o backup roda na EC2

Todos os arquivos novos ficam em `deploy/ec2/` (mesmo lugar de
`softspend.service` e `logrotate-softspend`) e o `setup.sh` os instala.

1. **Usuário do MySQL só para backup**, `softspend_backup`, com `SELECT`,
   `SHOW VIEW`, `TRIGGER`, `LOCK TABLES` (e `PROCESS` se a versão pedir) no
   banco `softspend`, e nada mais. A senha fica em
   `/etc/softspend/backup.cnf`, dono `root`, modo `600`, lida pelo
   `mysqldump` com `--defaults-extra-file` (nunca na linha de comando, onde
   apareceria no `ps`).
2. **Script de backup** (`backup-mysql.sh`), em ordem:
   1. confere espaço livre em `/var/backups/softspend` (pasta modo `700`):
      pelo menos 2 vezes o último dump, senão falha com mensagem clara;
   2. `mysqldump ... | gzip` para `softspend-AAAAMMDDTHHMMSSZ.sql.gz`
      (data em UTC no nome; o nome nunca se repete, então nada é sobrescrito);
   3. valida: `gzip -t` passa, o arquivo termina com a linha
      `-- Dump completed` do mysqldump e o tamanho é maior que 10 KB;
   4. grava ao lado um `.meta.json` com a data, a versão do MySQL, o
      `alembic_version` e a contagem de linhas de `users`, `ciclos`, `dias` e
      `gastos_dia` (usado no teste de restauração, §8.2);
   5. envia os dois arquivos ao bucket em `diario/AAAA/MM/` e confere que o
      tamanho no S3 é igual ao local; só então apaga o arquivo local mais
      antigo, mantendo os **2 últimos** na EC2 (restauração rápida; cópia no
      mesmo disco não protege contra perda do disco, é só conveniência);
   6. qualquer falha termina com código diferente de zero (o journal do
      systemd registra) e, na fase 2, avisa por e-mail (§7).
3. **Envio ao S3 sem instalar nada novo:** um script Python pequeno com
   `boto3`, que já está no `requirements.txt` e na venv da API, usando a
   função IAM da instância. Atenção: o script **não** pode ler as variáveis
   `S3_*` do `.env` (são as chaves do bucket dos comprovantes); o serviço do
   backup usa o próprio arquivo de ambiente, sem `EnvironmentFile` da API.
4. **Timer systemd** (`softspend-backup.timer` + `softspend-backup.service`,
   `Type=oneshot`), `OnCalendar=*-*-* 06:30:00 UTC`, `Persistent=true`,
   `RandomizedDelaySec=300`. Log em `/var/log/softspend/backup.log` (entra no
   logrotate que já existe) e no journal. Timer em vez de cron porque
   recupera execução perdida e deixa o histórico em `systemctl status`.
5. **Segredos:** a senha do `softspend_backup` e o nome do bucket ficam em
   `/etc/softspend/`, fora do repositório; o repositório só traz um
   `backup.env.example` sem valores.

## 4. O que o usuário precisa criar na AWS

Nenhum destes itens pode ser criado pelo Claude ou pelo Devin; é no console
da AWS, com a conta do usuário. Tudo na região **sa-east-1 (São Paulo)**, a
mesma da EC2. Custo esperado: centavos por mês (o dump compactado de um app
deste tamanho é de poucos MB; medir o tamanho real depois do primeiro
backup). Não precisa de NAT Gateway nem de endpoint: a EC2 tem IP público e
acessa o S3 pela internet.

### 4.1 Obrigatório (fase 1)

- [ ] **Bucket S3** novo, por exemplo `softspend-backups-<sufixo>` (o nome é
      global e não pode ser reaproveitado; o sufixo pode ser o ID da conta).
  - **Bloquear todo acesso público**: as 4 opções ligadas.
  - **Criptografia padrão** SSE-S3 (AES-256) ligada.
  - **Versionamento desligado** (assim a regra de expiração apaga de
    verdade; não existe nome repetido, então não há o que proteger).
  - **Regra de ciclo de vida**: prefixos `diario/` e `pre-migration/`
    expiram os objetos com **30 dias**; apagar também envios multipart
    incompletos após 2 dias.
  - **Política do bucket** negando qualquer acesso sem HTTPS
    (`aws:SecureTransport = false`).
- [ ] **Política IAM** `softspend-backup-escrita`, anexada à função da
      EC2, permitindo **somente**:
  - `s3:PutObject` e `s3:GetObject` em `arn:aws:s3:::<bucket>/diario/*` e
    `.../pre-migration/*` (`GetObject` é necessário para conferir o tamanho
    depois do envio e para o teste de restauração);
  - `s3:ListBucket` no bucket, limitado a esses dois prefixos;
  - **nada de** `s3:DeleteObject`, `s3:PutBucketPolicy`, `s3:*` ou `Resource: "*"`.
    Quem apaga é só a regra de ciclo de vida do bucket: se alguém invadir a
    EC2, não consegue destruir os backups.
- [ ] **Função IAM** `softspend-ec2-backup` (tipo "serviço AWS / EC2") com
      essa política, **anexada à instância EC2**: Console EC2 → instância →
      Ações → Segurança → Modificar função do IAM. Se a EC2 já tiver uma
      função, só acrescentar a política a ela. Conferir que a instância exige
      **IMDSv2** (Ações → Configurações da instância → Modificar opções de
      metadados), para um erro na API não conseguir roubar as credenciais.
- [ ] **Não usar** as chaves `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` do
      `.env` para o backup: elas dão acesso ao bucket dos comprovantes e
      não podem ser limitadas a "só gravar".
- [ ] Depois de criar, **avisar o Claude/Devin** com: nome do bucket, nome
      da função e se a EC2 já tinha função antes. O restante (usuário do
      MySQL, instalação do timer) é feito por SSH, com roteiro do Devin.

### 4.2 Recomendado (fase 2, alertas)

- [ ] **Tópico SNS** `softspend-alertas` e uma assinatura de e-mail (o
      usuário confirma o e-mail que a AWS manda). Acrescentar
      `sns:Publish` nesse tópico à política da função.
- [ ] **Alarme CloudWatch** de "backup não chegou": ativar **métricas de
      requisição** do S3 só para o prefixo `diario/` (custa cerca de US$ 0,30
      por mês) e criar um alarme em `PutRequests` com soma `< 1` em 25 horas e
      `TreatMissingData = breaching`, avisando o tópico acima. Isso pega o
      caso que o aviso de falha não pega: o timer parou de rodar e nada
      falhou, porque nada executou.
- [ ] **Alerta de orçamento** (AWS Budgets) com um valor baixo, para notar
      custo inesperado do bucket.

### 4.3 Opcional (não é prioridade)

- Cópia dos backups em outra região (`us-east-1`): só se o usuário quiser se
  proteger contra a perda de uma região inteira, o que é raro; dobra o custo
  de armazenamento, que continua pequeno.
- **Snapshot diário do disco** (EBS, via Data Lifecycle Manager) como camada
  extra, para recriar a máquina inteira mais rápido. Não substitui o dump: o
  snapshot de um disco com MySQL ligado é consistente só em caso de queda
  ("crash-consistent"), e o dump é a cópia que se confere.

## 5. Retenção (e a LGPD)

- **30 dias corridos**, uma regra só. São ~30 arquivos de poucos MB.
- Motivo: a proposta de privacidade (13/11) é apagar os dados de quem excluiu
  a conta **em até 30 dias**. Backup guardado por 12 meses faria o dado
  excluído continuar existindo por um ano. Com 30 dias, o dado excluído sai
  dos backups no mesmo prazo prometido ao usuário.
- Os registros fiscais de 5 anos (decisão pendente com o contador) vêm das
  notas e relatórios da Apple e do contador, **não** deste dump; não guardar
  dumps por 5 anos para isso.
- **Decisão do usuário:** confirmar os 30 dias. Se o contador exigir mais,
  cria-se um prefixo `mensal/` com retenção maior **só com dados fiscais**
  (nunca o dump inteiro).
- A Política de Privacidade (`docs/legal/`) deve dizer que cópias de
  segurança são apagadas automaticamente em até 30 dias.

## 6. Dump antes de migration

O `deploy.yml` roda `alembic upgrade head` a cada merge na `main`, e a
`docs/publicacao.md` já aponta que isso acontece sem backup (há migration sem
downgrade, como a `b2c4d6e8f0a1`). Regra: no passo de deploy, **antes** do
`alembic upgrade head`, comparar `alembic current` com `alembic heads`; se
forem diferentes, rodar o script de backup com destino `pre-migration/`
(mesma retenção), e **abortar o deploy se o dump falhar**. Sem migration
pendente, não faz dump (um backup por merge seria ruído). Mexer no
`deploy.yml` é mudança de produção: o merge é do usuário.

## 7. Como saber que o backup funciona

1. **Falhou:** o script sai com erro e, na fase 2, publica uma mensagem no
   SNS com o motivo (sem dados do banco na mensagem).
2. **Não rodou:** o alarme do CloudWatch (§4.2).
3. **Conferência mensal** (o teste do §8.2) também falha alto se o último
   backup não existe ou não restaura.
4. Sem a fase 2, o mínimo é o usuário abrir o bucket 1 vez por semana e ver
   que há um arquivo novo por dia; o Claude escreve esse lembrete como tarefa.

## 8. Teste de restauração

Backup que nunca foi restaurado não conta como backup.

### 8.1 Primeiro teste, à mão (obrigatório antes de dizer que existe backup)

Feito uma vez, com o Claude guiando passo a passo, **fora do banco de
produção**:

1. Baixar o dump mais recente do bucket (da EC2, com a função IAM).
2. Criar o banco `softspend_restore_test` no mesmo MySQL (mesma versão e
   mesmo servidor, para provar que a versão restaura) e carregar:
   `gunzip -c arquivo.sql.gz | mysql softspend_restore_test`.
   **Conferir três vezes o nome do banco antes de rodar**: o dump traz as
   tabelas sem `CREATE DATABASE`, então o destino é o que se escolhe na linha.
3. Conferir: (a) `alembic_version` igual ao `alembic heads` do repositório;
   (b) a contagem de `users`, `ciclos`, `dias` e `gastos_dia` bate com o
   `.meta.json`; (c) ao menos um ciclo com seus dias e gastos abre e os
   valores monetários (`DECIMAL(10,2)`) estão certos; (d) as colunas de UUID
   (`users.id`) e os acentos (`utf8mb4`) vieram íntegros.
4. Apagar `softspend_restore_test`. Anotar na nota do projeto: data, tamanho
   do dump, tempo que levou (isso é o RTO real).

### 8.2 Teste automático mensal

Depois do primeiro, um segundo timer (`softspend-backup-teste.timer`, dia 1
às 07:30 UTC) roda o mesmo roteiro sozinho: baixa o dump mais recente,
restaura em `softspend_restore_test`, compara com o `.meta.json`
(`alembic_version` igual ao do dump e contagens iguais), apaga o banco
temporário e registra o resultado. Falha avisa pelo SNS. Detalhes:

- Usuário próprio `softspend_restore` com permissão **só** em
  `softspend_restore_test` (`CREATE`, `DROP`, `ALTER`, `INSERT`, `SELECT`
  nesse banco). Nunca em `softspend`.
- O script **recusa** rodar se o banco de destino não se chamar
  `softspend_restore_test`.
- Restaurar consome CPU e disco numa `t3.small` que também serve a API; por
  isso o horário de madrugada e `nice`/`ionice` baixos.

## 9. Roteiro de desastre (restaurar de verdade)

Para quando o banco de produção foi perdido ou corrompido. Quem decide
rodar é o usuário.

1. Avisar que o app ficará fora (o app guarda os gastos no aparelho e envia
   depois; ver "Offline-first" no `AGENTS.md`).
2. `sudo systemctl stop softspend` (a API não pode gravar durante a carga).
3. Escolher o dump: o mais recente em `diario/`, ou o de `pre-migration/` se o
   problema veio de uma migration. Baixar e conferir `gzip -t`.
4. **Se o banco `softspend` existe e está corrompido, não apagar:** renomear
   (`softspend_quebrado_AAAAMMDD`) ou fazer um dump do estado atual antes.
   Criar o banco `softspend` vazio e carregar o dump.
5. `alembic -c alembic/alembic.ini current`: se o dump é de antes de uma
   migration, aplicar `upgrade head`.
6. `sudo systemctl start softspend` e checar `https://softspend.com.br/health`.
7. **Efeito no app:** o que foi gravado no servidor depois do dump
   (até 24 h) some do servidor. Nos aparelhos, itens já marcados `synced` não
   são reenviados sozinhos, então esses gastos continuam só no iPhone.
   Para diminuir isso, quando houver muitos assinantes, ligar o binlog do
   MySQL e fazer restauração até um ponto no tempo (fora desta especificação).
8. Registrar o incidente na nota do projeto.

## 10. O que este documento não cobre

- **`.env` da EC2** (`SECRET_KEY`, `REFRESH_TOKEN_SECRET_KEY`, chaves S3 e
  Gemini): guardar uma cópia no gerenciador de senhas do usuário. Sem ela, um
  servidor novo precisa de segredos novos (todo mundo teria que logar de novo).
- **Comprovantes** (bucket S3 dos anexos): tarefa à parte, ligar o
  versionamento no bucket deles (`docs/publicacao.md`, §3, linha "Notas (S3)", e §4, item 9).
- **Monitoramento geral** da EC2 (alarme de CPU, disco, `/health`).
- Atualização de versão do MySQL: o primeiro teste do §8.1 deve ser refeito
  depois de qualquer atualização.

## 11. Ordem das tarefas

1. **[Você]** Criar os itens do §4.1 (bucket, política, função, anexar à EC2) e
   confirmar os 30 dias do §5. Fase 2 (§4.2) pode vir depois.
2. **[Devin] B1 (complexa, só `deploy/ec2/` e `setup.sh`):** script de backup,
   envio com `boto3`, units do systemd, `backup.env.example`, logrotate. O
   comando `--dry-run` faz o dump e a validação sem enviar. Teste de unidade
   (`pytest`) da parte em Python: nome do arquivo, validação do tamanho e
   recusa de bucket vazio. Pronto quando `pytest -q` passa e o roteiro de
   instalação na EC2 está no PR.
3. **[Você, com o Claude]** Instalar na EC2 e fazer o teste do §8.1. Só depois
   disso o backup conta como existente.
4. **[Devin] B2 (simples):** teste automático mensal (§8.2).
5. **[Devin] B3 (simples):** dump antes de migration no `deploy.yml` (§6);
   o merge é do usuário.
6. **[Devin] B4 (simples):** em `docs/publicacao.md`, trocar as menções a RDS
   (§3, linha "Banco", e §4, item 9) pelo MySQL na EC2 com este backup; em
   `docs/religar-servidor.md`, trocar "snapshot do RDS" por "dump antes de
   migration"; frase sobre cópias de segurança na Política de Privacidade.
