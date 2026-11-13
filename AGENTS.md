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

Backend:

```bash
cd Python && python3 -m pip install -r requirements-dev.txt
# REFRESH_TOKEN_SECRET_KEY precisa estar exportada para os testes passarem.
cd Python && SECRET_KEY="..." REFRESH_TOKEN_SECRET_KEY="..." pytest -q
cd Python && SECRET_KEY="..." REFRESH_TOKEN_SECRET_KEY="..." python3 -c "import main; print(len(main.app.routes))"
```

## Arquitetura iOS — SwiftData e offline-first

O app usa **SwiftData** como banco local (`CicloSoftex`, `DiaSoftex`, `GastosDia`, `UserModel`).

- O `ModelContainer` é criado uma vez em `BancoLocal.container`
  (`Models/BancoLocal.swift`) — container único usado pelo app e pelo App
  Intent "Registrar gasto" — com o schema versionado (ver "Schema versionado e
  quarentena" abaixo) e registrado via `.modelContainer(_:)`. O erro cosmético
  `Failed to create file; code = 2` do Core Data na primeira execução é
  esperado — o recovery automático cria o diretório e abre o store com
  sucesso.
- O `ModelContext` é acessado pelas views via `@Environment(\.modelContext)` e
  repassado para os ViewModels.
- Toda ação de escrita (criar, editar, excluir) altera o SwiftData primeiro e
  sincroniza com o backend em segundo plano.
- Cada model tem `syncStatus` (`pending`, `syncing`, `synced`, `failed`),
  `syncError`, `tentativas` e `proximaTentativaEm` para backoff.
- Deduplicação é feita pelo `clientId`, gerado no app e enviado nas requisições.

### Schema versionado e quarentena do banco local

Spec completa: `docs/migracao-banco-local-ios.md`.

- `Models/SoftSpendSchema.swift` define `SoftSpendSchemaV1` (`VersionedSchema`,
  versão 1.0.0) e `SoftSpendMigrationPlan` (`schemas = [V1]`, `stages = []`),
  ambos `nonisolated`.
- O V1 aponta para as 7 classes vivas e é **exatamente** o schema que a `main`
  já gravava sem versão. Por isso **qualquer mudança em um `@Model` exige,
  antes, congelar o V1** em cópias aninhadas e criar o V2 (seção 5 da spec).
- O store continua com o nome `"softspend"` e o arquivo `softspend_v1.sqlite`
  (renomear deixaria os dados atuais órfãos).
- Não existe mais fallback destrutivo. Se o container não abrir, o erro é logado
  completo (com `userInfo`) e `.sqlite`, `-wal` e `-shm` são **movidos** para
  `Application Support/softspend-backup-<yyyyMMdd-HHmmss>/`; depois um banco
  novo é criado. Nunca `removeItem`. Abertura normal não loga "backup" nem
  "quarentena".

### Isolamento de actor (Swift 6 / `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)

O projeto usa `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, que faz todo tipo
não-anotado ser implicitamente `@MainActor`. Como a sincronização roda em um
`actor` próprio (`SyncActor`), os modelos e o protocolo `Syncavel` precisam ser
**explicitamente `nonisolated`** para serem acessíveis de dentro do `SyncActor`:

```swift
@Model
nonisolated final class CicloSoftex { ... }

nonisolated protocol Syncavel: AnyObject { ... }
nonisolated extension CicloSoftex: Syncavel {}
```

`ComprovanteCrypto` também é `nonisolated` porque é acessado de propriedades
`@Transient` do `GastosDia` (que é `nonisolated`).

`NetworkManager` e `APIConfig` são `Sendable` com membros `nonisolated` para
que as chamadas de rede feitas a partir do `SyncActor` (background) não façam
hop para o MainActor e bloqueiem a UI. Sem isso, todo `await
NetworkManager.shared.postCiclo(...)` executado pelo `SyncActor` era
serializado no MainActor, congelando a UI durante a sincronização.

### Componentes

- `CiclosViewModel` — operações de ciclo/dia/gasto com persistência local.
- `SyncManager` — sincronização sob demanda com backoff exponencial.

### Relacionamentos SwiftData

- `CicloSoftex.dias` → `@Relationship(deleteRule: .cascade, inverse: \DiaSoftex.ciclo)`
- `DiaSoftex.gastos` → `@Relationship(deleteRule: .cascade, inverse: \GastosDia.dia)`
- `GastosDia.diaId` é `@Transient` e deriva de `dia?.backendId` — **não é
  persistido**, eliminando a denormalização. O `syncGastos` resolve o `diaId`
  via relação `gasto.dia?.backendId`.
- Propriedades computadas (`syncStatus`, `comprovanteData`, `temComprovante`,
  `diaId`) são marcadas `@Transient` para não serem persistidas pelo SwiftData.

### Fluxo de sync

1. A operação atualiza o model local e marca `syncStatus = .pending`.
2. A UI reflete a mudança imediatamente.
3. Uma `Task` em background envia a requisição.
4. Em caso de sucesso, preenche `backendId`, `clientId` retornado e `syncStatus = .synced`.
5. Em caso de falha, `syncStatus = .failed`, mensagem em `syncError` e `proximaTentativaEm` calculado por backoff.
6. O `SyncManager` (chamado no `onAppear` do `MainView`) retenta itens pendentes/falhados que já podem ser sincronizados.

### SyncManager e SyncActor

O `SyncManager` é `@MainActor` apenas para publicar `isSyncing` e
`pendentesRestantes` na UI. O trabalho pesado roda no `SyncActor`, um
`@ModelActor` (background) com seu próprio `ModelContext`:

```
SyncManager (@MainActor, ObservableObject)
  └─ configure(container:) → SyncActor (@ModelActor, background)
       └─ sync(agora:) → até 5 passadas
            ├─ syncCiclos    (cria/edita ciclos)
            ├─ syncDias      (cria dias, reconcilia saldo)
            ├─ syncGastos    (cria/edita gastos, respeita dependência dia)
            ├─ syncComprovantes (upload/delete de comprovantes)
            └─ syncDeletions (delete em cascata: gasto → dia → ciclo)
```

**Cascata automática**: O usuário pode criar ciclo → dias → gastos totalmente
offline (todos com `backendId == nil`). Quando a conexão restabelece, o loop de
passadas destrava cada etapa na mesma invocação de `sync()`:

1. `syncCiclos` sobe o ciclo → ciclo recebe `backendId`.
2. `syncDias` vê `dia.ciclo?.backendId` → sobe os dias → dias recebem `backendId`.
3. `syncGastos` vê `gasto.dia?.backendId` → sobe os gastos → gastos recebem `backendId`.
4. `syncComprovantes` vê `gasto.backendId` → sobe os comprovantes.

**Rede injetável (testes)**: o `SyncActor` não chama `NetworkManager.shared`
direto; usa o protocolo `SyncAPI` (`Network/SyncAPI.swift`, `nonisolated`),
recebido no `init(modelContainer:api:)` com padrão `NetworkManager.shared`. Por
isso a conformidade com `ModelActor` é escrita à mão (o `@ModelActor` não
deixa acrescentar parâmetro ao `init`). Nos testes, `SoftSpendTests/FakeSyncAPI.swift`
é um servidor em memória que pode segurar a resposta (`segurar` → `Portao`) e
falhar sob comando (`falhar`); ver `SyncActorTests.swift`.

Cada stage só processa itens cujo pai já tem `backendId`. Itens órfãos aguardam
na fila (`continue`) para a próxima passada.

**Backoff exponencial**: base 60s, teto 3600s (1h). `marcarFalha` incrementa
`tentativas` e seta `proximaTentativaEm`. `deveTentar` só retorna `true` se
`proximaTentativaEm <= agora`.

**Logging**: `SyncActor` usa `os.Logger` (subsystem `br.com.softspend`,
category `SyncActor`) para logar falhas de save e dias remotos sem `backendId`.
O helper `salvar(_:etapa:)` substitui `try? modelContext.save()` — erros de
save aparecem no Console.app em vez de serem silenciados.

**Mudança durante o envio (T2)**: o `SyncActor` não usa o próprio
`modelContext`. Cada etapa lista os itens num `ModelContext(modelContainer)`
novo, tira uma foto (`FotoCiclo`, `FotoDia`, `FotoGasto`) dos campos enviados e,
depois do `await`, `gravar(...)` relê o item (por `id`) em outro contexto novo:
grava sempre o que o servidor devolveu (`backendId`, URL), mas só chama
`marcarSucesso` se a releitura bate com a foto. Se o usuário mudou o item no
meio, `marcarMudancaDuranteEnvio` deixa `.pending` sem backoff e o `sync` roda
mais uma passada. Uma nota anexada durante o upload não é apagada. Testes em
`SoftSpendTests/MudancaDuranteEnvioTests.swift`.

**Delete centralizado**: Em `syncDeletions`, o `modelContext.delete` é chamado
uma única vez após o try/catch. Em sucesso ou 404, o item é deletado localmente.
Em falha real, `marcarFalha` + `continue` (sem delete).

**Descarte por 404 (T4, decisão de 12/11)**: 404 no POST/PUT de `syncGastos`
ou no POST de `syncDias` (o pai ou o item foi apagado em outro aparelho)
descarta o item no aparelho, sem nenhuma requisição a mais. `descartarGasto`/
`descartarDia` releem por `id` num contexto novo (via `gravar`): o gasto sai
do `dia.ciclo.gasto_total` e é apagado; o dia tira do total os gastos vivos
dele (`deletadoEm == nil`) e é apagado (a cascata leva os gastos). Versões
anteriores guardavam esses itens com `syncError = SyncActor.erroApagadoEmOutroAparelho`;
o começo de `sync(agora:)` os descarta do mesmo jeito
(`descartarAntigosApagadosEmOutroAparelho`, gastos antes dos dias). A
constante existe só para isso (e para `EstadoEnvio`/`podeTerSidoCriadoNoServidor`
tratarem esses itens antigos até o descarte). Testes em
`SoftSpendTests/FalhaFinal404Tests.swift`.

**Apagar sem `backendId` (T7)**: item apagado sem `backendId`, mas com
`podeTerSidoCriadoNoServidor` (`tentativas > 0`, `.failed` ou `syncError`, exceto
a falha final do T4), pode existir no servidor (resposta do POST perdida). O
`deleteCiclo` o marca com `deletadoEm` em vez de apagar só no aparelho, e o
`syncDeletions` repete o POST com o mesmo `client_id` só para obter o id e mandar
o `DELETE`. Nunca enviado: nenhuma requisição. Testes em
`SoftSpendTests/ApagarSemBackendIdTests.swift` (`FakeSyncAPI.perderResposta`).

**Comprovantes**: `syncComprovantes` filtra por `syncStatusRaw != synced` no
predicado. Chama `marcarFalha` em falha (backoff) e `marcarSucesso` apenas se
`comprovanteData == nil && !comprovanteParaRemover`. `syncGastos` também só
marca `.synced` se não há comprovante pendente — o gasto permanece `.pending`
até o comprovante ser processado.

**Exclusão vinda do servidor (T5)**: no `CiclosViewModel`, com a lista completa
de dias (`listaCompleta`), `removerSumidos` apaga gasto `.synced` com `backendId`
que não veio em nenhum dia da lista e dia ausente cujos gastos todos saíram. Com
a lista de ciclos lida até a última página sem buraco (`LeituraDeCiclos`), sai o
ciclo `.synced` ausente sem nenhuma alteração local na viagem. Candidatos são
tirados antes da busca; nada `pending`/`failed`/`deletadoEm` sai. Testes em
`SoftSpendTests/ExclusaoNoServidorTests.swift`.

### ComprovanteCrypto

`GastosDia.comprovanteData` é uma propriedade `@Transient` que encripta/decripta
sob demanda usando `ComprovanteCrypto` (CryptoKit AES-GCM). O bytes criptografados
ficam em `comprovanteDataCriptografado`. A chave simétrica de 256 bits é armazenada
no Keychain com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

`ComprovanteCrypto` é `nonisolated` porque é acessado de `GastosDia` (que é
`nonisolated`).

### Apple Pay (atalho "Registrar gasto")

Spec: `docs/cartao-sem-open-finance.md` §1 (partes A e B implementadas).

- `Intents/RegistrarGastoIntent.swift` — App Intent com
  `openAppWhenRun = false`; roda `@MainActor` no `mainContext` do
  `BancoLocal.container` (o mesmo do app) e só chama a regra. Responde com um
  `IntentDialog` curto que o Atalhos mostra como confirmação.
- `Intents/SoftSpendAtalhos.swift` — `AppShortcutsProvider` com frases em
  português contendo `\(.applicationName)` (exigência da Apple).
- `Services/RegistroApplePay.swift` — regra pura (recebe `ModelContext`,
  `userId`, `agora`, `calendario`, fila): parse do valor (`ValorDaCompra`),
  categoria por `InterpretadorComprovante.inferirCategoria`, dia de hoje da
  viagem aberta (em sobreposição, a de primeiro dia mais recente), duplicata
  em janela deslizante de 60 s (mesmo valor + estabelecimento normalizado, em
  gasto vivo **ou** item da fila). Sem viagem/dia de hoje, vai para a fila.
- `Services/UsuarioSalvo.swift` — `userId` lido do `user_data` do
  `UserDefaults` **sem Keychain**: a ação pode rodar com o iPhone trancado e o
  token é `WhenUnlockedThisDeviceOnly`. Sem `user_data`, recusa
  `.semUsuario`. Se o app acordou travado, o `AuthService` nasce sem token; o
  `SoftexVamoApp` repete `checkAuthentication()` quando a cena fica `.active`
  com `isAuthenticated == false` (só lê, nunca apaga).
- `Services/ComprasAguardandoViagem.swift` — fila "sem viagem" em JSON
  (`Application Support/compras-apple-pay.json`, escrita atômica, teto de 50
  por usuário, fora do SwiftData de propósito: nenhum `@Model` novo, sem V2).
  Ler+regravar é serializado por `NSLock`; arquivo corrompido vai para
  `.corrompido-<data>` (nome único, backups se acumulam) em vez de ser
  sobrescrito — e se o move falhar, lança para não gravar por cima. Arquivo
  que existe mas não lê (permissão, I/O) também lança: ler como vazio
  deixaria a próxima gravação apagar os itens de todos. `adicionar`
  **lança** quando a leitura ou a gravação falha (o `registrar` propaga e
  a ação responde "lance no app"), enquanto `remover` só loga e deixa o
  item.
- Aviso da fila no `InicioView` (`AlertaPendencia` com `textoComprasApplePay`,
  lido por `recarregarFila` no `task(id: hoje)`) e folha
  `Scenes/ComprasSemViagemView.swift`: cada item mostra estabelecimento,
  valor, cartão e data, com "Lançar em …" (destino por
  `RegistroApplePay.viagemEDia` — a folha puxa os ciclos num fetch só por
  render, via `ciclosVivos`, e filtra em memória — `allCiclos` pode ainda
  não ter carregado) e "Descartar" (pede `.confirmationDialog` com
  `presenting:` — a compra some para sempre). Sem viagem para a data,
  só "Descartar" e o texto "Crie a viagem desta data para lançar". `lancar`
  só grava se o `id` ainda estiver na fila (toque duplo vira no-op), tira o
  item da fila depois do `save` e grava `criadoEm = recebidaEm`.
- `Scenes/ComoLigarApplePayView.swift` — tela de ajuda na seção Preferências
  de `PerfilView` (linha "Apple Pay (atalho)"); a automação é criada pelo
  usuário no app Atalhos (a Apple não permite criar pelo app).

### Pegadinhas SwiftData / SwiftUI (crashes conhecidos)

Estas armadilhas já causaram crashes em produção e foram corrigidas. Mantenha
estas regras ao modificar o código:

1. **`@Transient` em `#Predicate` é fatal error em runtime.**
   `#Predicate` é traduzido em SQL pelo SwiftData e só pode referenciar
   propriedades persistidas (colunas reais da tabela). Usar uma propriedade
   `@Transient` (como `comprovanteData`, `syncStatus`, `diaId`, `temComprovante`)
   dentro de `FetchDescriptor(predicate:)` causa:

   ```
   Fatal error: Couldn't find \GastosDia.comprovanteData on GastosDia
   with fields [...]
   ```

   **Regra**: no `#Predicate`, use sempre a propriedade persistida
   (`comprovanteDataCriptografado`, `syncStatusRaw`). O filtro pela propriedade
   `@Transient` deve ser feito em memória, **depois** do `fetch`.

2. **Mutar `@Model` durante o body da view causa loop infinito de observação.**
   `@Model` é observado pelo SwiftUI. Se uma computed property chamada durante
   o `body` muta o modelo, o SwiftUI detecta a mudança → re-renderiza → chama a
   computed property de novo → muta de novo → crash/freeze.

   **Caso concreto** (visual antigo, já removido): um ViewModel fazia
   `diaFiltrado.gastos = gastosQueBatem` (mutava o `@Model` durante o body).
   Foi corrigido com um struct imutável que envolvia o dia e os gastos
   filtrados sem mutar o modelo.

   **Regra**: computed properties de ViewModel chamadas em `body` nunca devem
   mutar `@Model`. Se precisar de dados filtrados, retorne um struct value type.

3. **Não fazer append manual em relacionamentos inversos.**
   `GastosDia(dia: dia)` já seta `novoGasto.dia = dia`. Após
   `modelContext.insert(novoGasto)`, SwiftData estabelece a relação inversa
   automaticamente — `dia.gastos` já contém o gasto. Fazer
   `dia.gastos.append(novoGasto)` manualmente cria uma **duplicata** na relação,
   que causa crash de integridade quando o `SyncActor` faz merge do contexto.

   **Regra**: para criar um gasto, faça apenas `GastosDia(dia: dia)` +
   `modelContext.insert(novoGasto)`. Nunca faça append manual na relação
   inversa. Atualize apenas campos derivados como `gasto_total`.

4. **Não acessar `@State` após `dismiss()`.**
   `defer { Task { @MainActor in isSalvando = false } }` executa **depois**
   do `dismiss()`. Quando o sheet é destruído, o `@State` é desalocado — a
   Task do `defer` acessa memória morta → crash.

   **Regra**: sempre reset `@State` **antes** de `dismiss()`, síncrono no
   MainActor. Nunca use `defer` com `Task` aninhada para resetar estado de UI.

5. **Delete de gastos via context menu (long press).**
   Os gastos estão em `ScrollView` + `VStack` (não em `List`), então
   `.swipeActions` não funciona. O delete é feito via `.contextMenu` na célula
   do gasto em `InicioView` (e pelo botão de apagar em `DetalheGastoView`),
   que chama `CiclosViewModel.deleteGasto(gastoID: UUID)` (soft delete + sync).

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
cd Python && alembic -c alembic/alembic.ini upgrade head
```

Para rodar na AWS, ajuste `DB_HOST`/`DATABASE_URL` antes do comando. Migration
nova precisa ser aplicada nos **dois** bancos.

As tabelas foram criadas originalmente por `Base.metadata.create_all`, não por
migration, então um banco novo pode não ter `alembic_version`. Nesse caso
`alembic stamp 663d2dcc98c8` marca a baseline (cujo schema já existe) antes do
`upgrade head`; sem isso a migration inicial falha tentando recriar colunas de
`users`.

Cadeia de migrations:

1. `663d2dcc98c8` — baseline (users, ciclos, dias, gastos_dia).
2. `a1f4c9b2d7e3` — adiciona `comprovante_key` em `gastos_dia`.
3. `3e17707010d8` — adiciona `client_id` em `ciclos`, `dias` e `gastos_dia`
   com índices e unique constraints. **Sem essa migration, qualquer rota que
   toque `client_id` falha com** `Unknown column 'ciclos.client_id' in 'field
   list'` (erro 1054 do MySQL).
4. `b2c4d6e8f0a1` — muda `users.id` de Integer auto-increment para String(36)
   UUID. Gera UUIDs para usuários existentes e atualiza `ciclos.id_usuario`.
   **Sem downgrade** — UUIDs não podem ser revertidos para inteiros sequenciais.
5. `335cdb5f77dd` — converte valores monetários para `DECIMAL(10, 2)`.
6. `97ea189fc3da` — adiciona `refresh_tokens`.
7. `c4d8f2a6b9e0` — adiciona as tabelas Open Finance: conexões Pluggy,
   cartões de crédito, faturas e transações.
8. `d6f1a9c3b8e4` — adiciona `expense_transaction_matches`, o vínculo entre
   gastos do SoftSpend e transações da fatura.
9. `e8a2b5c7d9f1` — adiciona `refresh_tokens.session_id` (indexada, NOT NULL).
   Linhas antigas recebem o próprio `id`. Sem ela, login e qualquer rota
   autenticada falham com `Unknown column 'refresh_tokens.session_id'`.
10. `f2c4e6a8b0d2` — fatura importada por arquivo (§2.6): `credit_card_accounts`
    ganha `origem` (`PLUGGY`/`FATURA`, default `PLUGGY`) e `conexao_id` passa a
    aceitar NULL (cartão importado não tem conexão Pluggy). O downgrade apaga
    as linhas `FATURA` com as filhas e devolve `conexao_id` a NOT NULL.

## Isolamento por usuário (UUID)

O `User.id` no backend é UUID string. Cada usuário tem identificador globalmente
único — impossível colidir entre ambientes (dev/prod). No iOS, `CicloSoftex`
tem `userId: String` que é setado a partir do usuário autenticado. Todas as
queries SwiftData (fetch, sync, dedup) filtram por `userId`. Isso elimina o
vazamento de dados entre usuários no mesmo dispositivo **sem precisar deletar
dados no logout** — dados offline pendentes de sync são preservados.

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

Open Finance com Pluggy (`services/open_finance_service.py`):

| Variável | Default | Descrição |
| --- | --- | --- |
| `OPEN_FINANCE_ENABLED` | `false` | Com `false` as rotas `/api/open-finance/*`, `/api/connect-token` e `/api/webhooks/pluggy` não são registradas (404) e `GET /api/features` devolve `{"open_finance": false}`; nenhuma variável `PLUGGY_*` é necessária. Com `true` tudo funciona como antes |
| `PLUGGY_CLIENT_ID` | — | Credencial da aplicação no Pluggy; sem ela `/api/connect-token` responde 503 |
| `PLUGGY_CLIENT_SECRET` | — | Segredo da aplicação no Pluggy; somente no backend |
| `PLUGGY_API_URL` | `https://api.pluggy.ai` | Base URL da API |
| `PLUGGY_WEBHOOK_URL` | — | URL pública HTTPS enviada no connect token; deve apontar para `/api/webhooks/pluggy` |
| `PLUGGY_WEBHOOK_SECRET` | — | **Obrigatória** para habilitar o webhook; use no header `X-Pluggy-Webhook-Secret` ao registrar o webhook pela API do Pluggy ou como `?token=` em `PLUGGY_WEBHOOK_URL` |
| `PLUGGY_TIMEOUT_SECONDS` | `10` | Timeout das chamadas HTTP ao Pluggy |

A importação roda em background nos eventos `item/created`, `item/updated`,
`transactions/created` e `transactions/updated`. Também existe sincronização
manual em `POST /api/open-finance/items/{item_id}/sync`, que valida o
`clientUserId` do Item contra o usuário autenticado. O app pode consultar:

- `GET /api/open-finance/connections`
- `GET /api/open-finance/cards`
- `GET /api/open-finance/cards/{cartao_id}/bills`
- `GET /api/open-finance/cards/{cartao_id}/transactions`
- `GET /api/open-finance/bills/{fatura_id}` — fatura com suas transações e o
  vínculo de cada transação com um gasto do usuário
- `GET /api/open-finance/matches` — vínculos gasto/transação do usuário
- `POST /api/open-finance/matches/{match_id}/confirm` — confirma um match
  ambíguo, mudando o status para `CONFIRMED`
- `DELETE /api/open-finance/matches/{match_id}` — remove o vínculo para o
  gasto voltar a `PENDENTE`

Somente contas `type=CREDIT` e `subtype=CREDIT_CARD` são importadas. Transações
são buscadas por `GET /v2/transactions` e vinculadas à fatura por
`creditCardMetadata.billId` quando o Pluggy envia esse campo. Após a
importação, `services/open_finance_reconciliation_service.py` compara gastos
ainda não vinculados com transações do mesmo usuário usando valor exato,
janela de data e similaridade textual. `GastoResponse` expõe
`open_finance_status` (`PENDENTE`, `AUTO_MATCHED`, `REVIEW` ou `CONFIRMED`) e
o detalhe em `open_finance_match`.

No iOS, `CartaoOpenFinance`, `FaturaCartao` e `TransacaoCartao` são models
SwiftData somente de leitura cacheados por `backendId`. `OpenFinanceViewModel`
faz upsert a partir dos DTOs, apaga registros que sumiram no backend e
reaplica os matches em `GastosDia`. A tela `OpenFinanceView` (hoje fora da
navegação do visual novo: volta quando o Open Finance estiver ligado, sem "em breve")
lista cartões, faturas e todas as transações do cartão; `FaturaDetalheView` e
`CartaoTransacoesView` permitem confirmar ou remover um vínculo em revisão.

Importar fatura por arquivo (`docs/cartao-sem-open-finance.md` §2, tarefas S1
e S2). Todas as rotas ficam em `controllers/fatura_controller.py` sob
`/api/faturas`, sempre registradas — não dependem de `OPEN_FINANCE_ENABLED`
nem de `PLUGGY_*`:

- `POST /api/faturas/ler` (multipart `arquivo`, `senha?`, `ciclo_id?`) lê o
  arquivo e devolve a prévia **sem gravar nada** (nem banco, nem S3).
  `arquivo`: PDF até 10 MB e 20 páginas, OFX ou CSV até 2 MB; `senha?` para
  PDF protegido (regravado sem proteção em memória pelo `pypdfium2`; a senha
  nunca é guardada nem logada). `services/fatura_arquivo_service.py` detecta
  o tipo pelos bytes/cabeçalho, faz o parse de OFX e CSV por regex/`csv`
  (sem IA) e aplica a validação e o `soma_confere` compartilhados.
  `services/fatura_ia_service.py` manda o PDF nativo ao Gemini (mesmas
  `GEMINI_API_KEY`/`GEMINI_MODEL_NAME` do OCR, mas cliente próprio com
  timeout de 60 s e `MAX_OUTPUT_TOKENS` 16.384; sem a chave só o PDF dá
  `503` — OFX e CSV funcionam). O log leva só tamanho, tempo, nº de compras
  e `usage_metadata` — nunca descrição, valor ou senha. Com `ciclo_id`
  (ciclo de outro usuário: `404`), `services/fatura_service.marcar_previa`
  preenche `dentro_da_viagem` (data entre o primeiro e o último dia do
  ciclo), `dia_id` e `match` — a mesma `_pontuacao` da conciliação real,
  com atribuição gulosa pela maior pontuação (um gasto casa com uma compra
  só e vice-versa; `>= 80` sem empate `AUTO_MATCHED`, `65+` ou empate
  `REVIEW`) sobre os gastos do ciclo ainda sem vínculo. Estorno e encargo
  nunca casam.
- `POST /api/faturas` recebe a `FaturaLida` da prévia já sem as compras
  descartadas, grava tudo de forma idempotente e roda `conciliar_usuario`.
  `services/fatura_service.py` acha ou cria o cartão por (usuário, emissor,
  final) — `origem = 'FATURA'`, `conexao_id = NULL` — e a fatura por
  (cartão, vencimento), atualizando o total se mudou. O `transaction_id` é
  `fatura:` + sha256 de usuário, cartão, data, valor, descrição
  normalizada, parcela, tipo e ordem entre iguais (duas compras idênticas
  no mesmo dia continuam duas; reimportar não duplica).
- `POST /api/faturas/{id}/conciliar` roda a conciliação de novo (o app
  chama depois de sincronizar os gastos criados na conferência).
- `GET /api/faturas` e `GET /api/faturas/{id}` — histórico e detalhe, só do
  usuário e só `origem = FATURA`.
- `DELETE /api/faturas/{id}` — apaga a fatura, suas compras e os vínculos;
  os gastos ficam (voltam a `PENDENTE`).
- `POST /api/faturas/matches/{id}/confirm` e
  `DELETE /api/faturas/matches/{id}` — mesmo efeito das rotas do
  Open Finance, chamando as mesmas funções do `open_finance_repository`.

O `_pontuacao`/`_pontuacao_texto` de `open_finance_reconciliation_service.py`
aceitam qualquer objeto com `amount`, `date` (`date` ou `datetime`) e
`merchant_name`/`description`, sem mudar regra nenhuma — a prévia pontua
compras ainda não gravadas por um adaptador (`_CompraComoTransacao`).

| Variável | Default | Descrição |
| --- | --- | --- |
| `ALLOWED_ORIGINS` | `https://softspend.com.br` | Origens CORS permitidas, separadas por vírgula |
| `DOCS_ENABLED` | `false` | Se `true`, habilita `/docs`, `/redoc` e `/openapi.json` |
| `TRUST_PROXY` | `false` | Habilita o uso de `X-Forwarded-For` somente quando o peer pertence a uma rede confiável |
| `TRUSTED_PROXY_IPS` | `127.0.0.1,::1` | IPs ou redes CIDR dos proxies confiáveis, separados por vírgula |

Autenticação OAuth2 / refresh tokens (`services/auth_service.py`):

| Variável | Default | Descrição |
| --- | --- | --- |
| `SECRET_KEY` | — | Chave para assinar JWTs (>= 32 caracteres) |
| `REFRESH_TOKEN_SECRET_KEY` | — | **Obrigatória** — chave separada para HMAC dos refresh tokens; deve ser diferente de `SECRET_KEY` |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | `15` | Tempo de vida do access token |
| `REFRESH_TOKEN_EXPIRE_DAYS` | `7` | Tempo de vida do refresh token |
| `REVOKE_OLD_REFRESH_TOKENS_ON_LOGIN` | `false` | Se `true`, login invalida refresh tokens antigos (apenas uma sessão ativa) |
| `REFRESH_REUSE_GRACE_SECONDS` | `60` | Janela de tolerância (segundos) para reuso de refresh token recém-rotacionado com a sessão ainda ativa; `0` desliga. Lida a cada chamada |
| `HSTS_MAX_AGE` | `31536000` | Valor do header `Strict-Transport-Security` em segundos |

Sessões: cada login gera um `session_id` novo, gravado no refresh token e no
claim `sid` do access token; a rotação (`/auth/refresh`) herda o mesmo
`session_id`. O `get_current_user` só aceita um token com `sid` se ainda
existir refresh token dessa sessão, do mesmo usuário, não revogado e não
expirado. Assim:

- o logout revoga a sessão inteira e o access token dela cai na hora;
- o reuso de refresh token revoga todas as sessões do usuário — exceto dentro
  da janela de `REFRESH_REUSE_GRACE_SECONDS` com a sessão ainda ativa, caso em
  que um par novo é emitido na mesma sessão (tolera réplica legítima logo após
  a rotação);
- a rotação normal não derruba requisições em voo (o token antigo segue válido);
- tokens sem `sid` (emitidos antes dessa regra) seguem aceitos até expirar.

Custo: uma consulta indexada em `refresh_tokens.session_id` por requisição autenticada.

## TLS/HTTPS

O backend nao forca TLS no codigo; isso e responsabilidade da camada de proxy.
Foram adicionados dois mecanismos:

1. **Middleware `EnforceHTTPSMiddleware`** (`middlewares/enforce_https.py`):
   - Le `X-Forwarded-Proto` do proxy.
   - Se for `http`, redireciona `308` para `https://`.
   - Adiciona `Strict-Transport-Security` nas respostas HTTPS.
   - Requisicoes diretas (sem o header) nao sao redirecionadas, permitindo
     health checks locais HTTP.

2. **Config nginx** (`deploy/ec2/nginx-softspend.conf`):
   - Escuta `80` e redireciona tudo para HTTPS.
   - Escuta `443` com SSL, repassa `X-Forwarded-Proto` e adiciona HSTS.
   - O uvicorn no `softspend.service` foi alterado para bind em `127.0.0.1:8000`
     (nao e mais exposto publicamente).

Para rodar o setup com certificado SSL na EC2:

```bash
export DOMAIN="softspend.com.br"
export CERTBOT_EMAIL="seu-email@example.com"
cd ~/SoftSpend/deploy/ec2 && ./setup.sh
```

O `certbot` e executado automaticamente quando `DOMAIN` e `CERTBOT_EMAIL` estao
exportados. Sem eles, o setup instala o nginx mas emite um aviso para voce
rodar o certbot manualmente.

## Deduplicação e `client_id`

Para evitar criação duplicada quando o app não recebe a resposta do `POST` (ex: timeout com a requisição já processada no backend), todos os models (`Ciclo`, `Dia`, `Gasto`) têm `client_id`.

- O iOS gera `clientId` (UUID) ao criar ciclo, dia ou gasto local.
- O `client_id` é enviado nas requisições de criação.
- O backend verifica se já existe um registro com o mesmo `client_id` e retorna o existente, em vez de criar um novo.
- As tabelas têm unique constraints por `client_id` + entidade pai:
  - `uix_ciclo_client_id_usuario`
  - `uix_dia_client_id_ciclo`
  - `uix_gasto_client_id_dia`

Migrations relacionadas:
- `a1f4c9b2d7e3_add_comprovante_key_to_gasto`
- `3e17707010d8_add_client_id_to_ciclos_dias_gastos`

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
requisição do OCR. Ver `NotaFiscal.codificar` e `NotaFiscal.comprimirParaOCR` em
`Services/LancamentoGasto.swift`.

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
