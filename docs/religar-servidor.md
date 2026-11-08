# Religar o servidor na AWS (sem Open Finance)

Roteiro para voltar a servir a API na EC2 com o Open Finance **desligado**.
O código do Open Finance continua no repositório; só não é registrado.

Pré-requisitos:

- A tarefa do backend que cria `OPEN_FINANCE_ENABLED` (padrão `false`) já foi mergeada na `main`.
  Sem ela, o servidor sobe com as rotas do Pluggy ativas.
- Acesso SSH à EC2 e ao RDS (security group do RDS liberando a EC2).

Os comandos abaixo rodam **na EC2**, em `~/SoftSpend/Python`, com a venv ativa:

```bash
ssh ubuntu@<EC2_HOST>
cd ~/SoftSpend && git fetch origin && git reset --hard origin/main
cd Python && source .venv/bin/activate
pip install -r requirements.txt
```

## 1. Ver em que versão está o banco (RDS)

O `alembic/env.py` usa o mesmo `database.py` da API, então o comando
abaixo aponta para o banco definido no `.env` (confira `DB_HOST` = endpoint do RDS).

```bash
grep -E '^(DB_HOST|DB_NAME|DATABASE_URL)=' .env | sed -E 's#://[^@]*@#://***@#'
alembic -c alembic/alembic.ini current
```

Interpretação:

- Mostra `d6f1a9c3b8e4 (head)`: banco em dia, pule para o passo 3.
- Mostra outro id (ex.: `c4d8f2a6b9e0`): faltam migrations, siga para o passo 2.
- Não mostra nada: o banco não tem `alembic_version`. As tabelas foram criadas
  por `create_all` no começo do projeto. Marque a baseline antes de subir:
  `alembic -c alembic/alembic.ini stamp 663d2dcc98c8`
  (a baseline só vale se o banco tem exatamente o schema inicial; se `gastos_dia`
  já tiver `comprovante_key` ou `client_id`, o banco está mais adiante: confira as colunas e
  marque a revisão correspondente em vez da baseline).

## 2. Aplicar as migrations até `d6f1a9c3b8e4`

```bash
alembic -c alembic/alembic.ini upgrade d6f1a9c3b8e4
alembic -c alembic/alembic.ini current   # deve mostrar d6f1a9c3b8e4 (head)
```

Cadeia esperada: `663d2dcc98c8` → `a1f4c9b2d7e3` → `3e17707010d8` →
`b2c4d6e8f0a1` → `335cdb5f77dd` → `97ea189fc3da` → `c4d8f2a6b9e0` → `d6f1a9c3b8e4`.

Cuidados:

- Faça um snapshot do RDS antes. A `b2c4d6e8f0a1` (user id para UUID) **não tem downgrade**.
- As tabelas do Open Finance (`c4d8f2a6b9e0`, `d6f1a9c3b8e4`) são criadas mesmo com o recurso
  desligado. Elas ficam vazias e o código as espera no schema.
- Se alguma migration falhar com `Unknown column` ou `Duplicate column`, pare e não force:
  o banco está numa versão diferente da que o `alembic_version` diz.

## 3. Ajustar o `.env`

O serviço lê `/home/ubuntu/SoftSpend/Python/.env` (`EnvironmentFile` do systemd).

```bash
nano .env
```

Garanta estas linhas (sem aspas, sem espaço em volta do `=`):

```
OPEN_FINANCE_ENABLED=false
SECRET_KEY=<>= 32 caracteres>
REFRESH_TOKEN_SECRET_KEY=<diferente de SECRET_KEY>
DB_HOST=<endpoint do RDS>
```

Não precisa de `PLUGGY_*`. Pode comentar ou remover para não pagar nada por engano.
`GEMINI_API_KEY` e `S3_*` seguem como antes (OCR e comprovantes não dependem do Open Finance).

## 4. Reiniciar o serviço

```bash
sudo systemctl restart softspend
sudo systemctl status softspend --no-pager
```

Deve aparecer `active (running)`. Se aparecer `failed`, vá ao passo 6.

## 5. Checar a saúde e o recurso desligado

```bash
curl -fsS http://127.0.0.1:8000/health          # {"status":"ok"}
curl -fsS http://127.0.0.1:8000/api/features    # {"open_finance":false}
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/open-finance/cards   # 404
```

Depois, de fora (passa pelo nginx/HTTPS):

```bash
curl -fsS https://softspend.com.br/health
```

`/health` com 503 significa que a API subiu mas não alcança o banco (veja `DB_HOST` e o security group do RDS).

## 6. Ler o log

```bash
tail -n 100 /var/log/softspend/app.log
journalctl -u softspend -n 50 --no-pager
```

Sinais de problema:

- `Unknown column ...` → migration faltando (volte ao passo 1).
- `SECRET_KEY`/`REFRESH_TOKEN_SECRET_KEY` ausente ou igual → corrija o `.env`.
- `Can't connect to MySQL server` → RDS inacessível ou `DB_HOST` errado.
- Nenhuma menção a Pluggy é esperada. Se houver, `OPEN_FINANCE_ENABLED` não foi lida.

## 7. Teste final pelo app

Abra o app apontando para o servidor: faça login, crie um gasto e confirme que sincroniza.
O item "Cartão corporativo" não deve aparecer no menu.

## Para religar o Open Finance depois

Defina `OPEN_FINANCE_ENABLED=true` e as variáveis `PLUGGY_*` do `AGENTS.md`,
reinicie o serviço e confira que `/api/features` devolve `{"open_finance":true}`.
