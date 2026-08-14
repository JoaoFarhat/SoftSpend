# SoftSpend

Monorepo com dois projetos:

- `SoftexVamo/` — app iOS em SwiftUI (projeto Xcode `SoftSpend.xcodeproj`, scheme `SoftSpend`).
- `Python/` — API em FastAPI + SQLAlchemy + Alembic.

## Build e verificação

App iOS (o Xcode não está no `xcode-select` ativo, use o caminho completo):

```bash
cd SoftexVamo
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SoftSpend.xcodeproj -scheme SoftSpend \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Backend (checagem rápida de import e rotas):

```bash
cd Python && python3 -c "import main; print(len(main.app.routes))"
```

## Bancos de dados

Existem dois: um **MySQL local** (para testes) e o **da AWS** (produção). O
`.env` da raiz do repo — fora do versionamento — define qual está em uso:

```
DB_USER=softspend_user
DB_PASS=...
DB_HOST=localhost   # local; troque pelo endpoint RDS para apontar na AWS
DB_NAME=softspend
```

Alternativamente, `DATABASE_URL` sobrescreve tudo isso.

O `alembic/env.py` monta a URL a partir do mesmo `database.py` da aplicação, de
modo que migration e API **nunca apontam para bancos diferentes**. Por isso o
`sqlalchemy.url` do `alembic.ini` está vazio de propósito: quando tinha uma URL
fixa, o alembic ia para um banco que não era o da aplicação. O `env.py` escapa
`%` na URL, porque o `alembic.ini` passa pelo configparser e senhas
url-encoded contêm `%`.

Migrations (aplica no banco apontado pelo `.env`):

```bash
cd Python && alembic upgrade head
```

Para rodar na AWS, ajuste `DB_HOST`/`DATABASE_URL` antes do comando. Migration
nova precisa ser aplicada nos **dois** bancos.

As tabelas foram criadas originalmente por `Base.metadata.create_all`, não por
migration, então um banco novo pode não ter `alembic_version`. Nesse caso
`alembic stamp 663d2dcc98c8` marca a baseline (cujo schema já existe) antes do
`upgrade head`; sem isso a migration inicial falha tentando recriar colunas de
`users`.

## Variáveis de ambiente (backend)

OCR de comprovantes com Gemini (`services/ocr_service.py`):

| Variável | Default | Descrição |
| --- | --- | --- |
| `GEMINI_API_KEY` | — | Sem ela o OCR é desabilitado |
| `GEMINI_MODEL_NAME` | `gemini-3.5-flash-lite` | Modelo multimodal |
| `OCR_MAX_IMAGE_SIZE` | `1280` | Maior lado da imagem enviada |
| `OCR_JPEG_QUALITY` | `80` | Qualidade do recompactamento |

Armazenamento de notas fiscais (`services/storage_service.py`), compatível com
AWS S3, Cloudflare R2, Supabase Storage e MinIO:

| Variável | Default | Descrição |
| --- | --- | --- |
| `S3_BUCKET` | — | **Obrigatória** para habilitar o anexo de notas; sem ela as rotas de comprovante respondem 503 |
| `S3_ACCESS_KEY_ID` | — | Credencial |
| `S3_SECRET_ACCESS_KEY` | — | Credencial |
| `S3_ENDPOINT_URL` | — | Necessária para R2/Supabase/MinIO; omitir na AWS |
| `S3_REGION` | `auto` | Use a região real na AWS |
| `S3_PUBLIC_BASE_URL` | — | Se definida, a URL é `{base}/{key}`; senão gera URL assinada |
| `S3_URL_EXPIRACAO` | `3600` | Validade da URL assinada, em segundos. Recomenda-se 1h em produção |

| Variável | Default | Descrição |
| --- | --- | --- |
| `ALLOWED_ORIGINS` | `https://softspend.com.br` | Origens CORS permitidas, separadas por vírgula |
| `DOCS_ENABLED` | `false` | Se `true`, habilita `/docs`, `/redoc` e `/openapi.json` |

## Notas fiscais (comprovantes)

O banco guarda apenas `gastos_dia.comprovante_key`; os bytes ficam no bucket.
`GastoResponse.comprovante_url` é resolvida na serialização pela property
`Gasto.comprovante_url`.

O upload sempre acontece **depois** que o gasto existe (a key deriva do id do
gasto), o que evita objetos órfãos no bucket. Fluxos suportados no app:

1. Escanear com IA — preenche os campos e anexa a nota (removível antes de salvar).
2. Anexar manualmente durante a criação do gasto.
3. Anexar depois, reabrindo o gasto salvo para edição.

A nota arquivada mantém a **resolução original** (só é convertida para JPEG, e a
qualidade cai apenas se passar de 9MB); a redução para 1280px existe só para a
requisição do OCR. Ver `codificarNotaFiscal` e `comprimirParaOCR` em
`AddNewGastoSheetView.swift`.

A limpeza do bucket fica em `services/comprovante_cleanup.py`, via listeners do
SQLAlchemy registrados no import feito pelo `main.py`. O `after_delete` anota as
keys na sessão e o `after_commit` as remove, de modo que um rollback não apaga
arquivos. Isso cobre também os deletes por cascade (ciclo e conta do usuário),
que não passam por `gasto_service.remover_gasto`.

## Deploy no EC2

Arquivos para rodar a API como serviço systemd e rotacionar logs:

- `deploy/ec2/softspend.service` — serviço systemd
- `deploy/ec2/logrotate-softspend` — rotação diária de logs
- `deploy/ec2/setup.sh` — instala tudo no servidor

Configure uma única vez no EC2:

```bash
cd ~/SoftSpend/deploy/ec2
chmod +x setup.sh
./setup.sh
```

O workflow do GitHub Actions pode reiniciar o serviço automaticamente:

```yaml
script: |
  cd ~/SoftSpend
  git fetch origin
  git reset --hard origin/main
  cd Python
  source .venv/bin/activate
  pip install -r requirements.txt
  alembic upgrade head
  sudo systemctl restart softspend
```

Logs ficam em `/var/log/softspend/app.log` e são rotacionados diariamente.

## Privacidade / OCR

O serviço de OCR (`services/ocr_service.py`) envia a imagem da nota fiscal para a
API do Google Gemini. Isso pode conter dados pessoais e financeiros. O app deve
obter **consentimento explícito do usuário** antes de usar o escaneamento com IA,
explicando que a imagem será processada por um serviço de terceiro.

Recomenda-se incluir nos termos de uso uma cláusula sobre:
- processamento de imagens por IA;
- armazenamento de comprovantes em bucket S3/R2;
- prazo de retenção e exclusão dos dados.
