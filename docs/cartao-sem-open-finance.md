# Cartão sem Open Finance

Decisão do usuário (12/11): ligar o cartão ao SoftSpend **sem pagar o piso dos agregadores** (Pluggy e parecidos).
O código do Open Finance continua no repositório, desligado (`OPEN_FINANCE_ENABLED=false`).
Dois caminhos, que se completam:

1. **§1 (este documento, parte 1):** registrar o gasto na hora, pelo atalho do Apple Pay.
2. **§2 (parte 2):** importar a fatura em PDF pela IA e conciliar com os gastos.

---

## 1. Registrar o gasto pelo atalho do Apple Pay

### 1.1 O que o usuário vê

1. Paga com o Apple Pay (iPhone ou Apple Watch).
2. Segundos depois, a automação do app Atalhos chama o SoftSpend, que grava o gasto sem abrir o app e sem perguntar nada.
3. Ao abrir o app, o gasto está no dia de hoje da viagem, com o selo de "ainda não enviado" como qualquer gasto (PR #27), e sobe para o servidor como os outros.

A automação **não é criada pelo app**: a Apple não permite. O app só oferece a ação e uma tela que ensina a ligar (§1.6).

### 1.2 Como a Apple entrega a compra (e o que é incerto)

- No app Atalhos, a automação pessoal **"Transação"** (gatilho "Carteira/Wallet" no iOS 17 em diante) roda quando uma compra é feita com um cartão ou passe da Carteira.
- As variáveis que ela entrega são **valor, estabelecimento (Merchant) e cartão ou passe (Card or Pass, Name)**. Todas chegam como **texto**, no formato do idioma do aparelho (ex.: `R$ 12,34`).
- **Não vem a hora da compra.** O app usa a hora em que a ação roda.
- A automação deve ser criada com **"Executar imediatamente"** (não "Pedir antes de executar") e, para não encher a tela de avisos, com **"Notificar quando executar" desligado**.
- A Apple não garante o gatilho: alguns bancos e cartões (principalmente os que não são adicionados pela Carteira da forma padrão) não disparam, e a automação pode atrasar ou não rodar com o aparelho em modo avião. A tela do §1.6 diz isso.
- **Para o Devin conferir no iPhone real:** os nomes exatos das variáveis em português e se `Amount` vem como `R$ 12,34` ou só `12,34`. O parser (§1.4) aceita os dois, mas o passo a passo da tela precisa usar os nomes que o iOS mostra.

### 1.3 A ação do app: `RegistrarGastoIntent`

App Intent no alvo do app (sem extensão), com `openAppWhenRun = false`.

| Parâmetro | Tipo | Obrigatório | Observação |
| --- | --- | --- | --- |
| `valor` | `String` | sim | Texto da variável "Valor" da automação |
| `estabelecimento` | `String` | sim | Vira o título do gasto (cortado em 60 caracteres, sem espaços nas pontas) |
| `cartao` | `String?` | não | Aparece só no diálogo de resposta e na fila (§1.5). **Não é gravado no gasto** na v1 (veja §1.8) |

- Título da ação: "Registrar gasto". Resposta: um diálogo curto, mostrado como confirmação ou erro no Atalhos (ex.: "Gasto de R$ 12,34 em Padaria Pão Quente registrado em Cuiabá, dia 3.").
- `AppShortcutsProvider` (`SoftSpendAtalhos`) com a ação e frases em português que contêm `\(.applicationName)` (a Apple exige o nome do app em toda frase), por exemplo "Registrar gasto no \(.applicationName)". Isso faz a ação aparecer no Atalhos e na Siri sem o usuário montar nada.
- O `perform()` é `@MainActor` e usa **o mesmo `ModelContainer` do app** (`container.mainContext`). Hoje o container é criado dentro de `SoftexVamoApp` (`createModelContainer()`, privado); a tarefa o move para um `BancoLocal.container` único, que o app e a ação usam, **sem mudar nada do que ele faz** (nome `"softspend"`, arquivo `softspend_v1.sqlite`, quarentena). Dois containers no mesmo arquivo é o que se quer evitar; usar o `mainContext` compartilhado também faz a tela aberta atualizar na hora.
- Quem é o usuário: **não depende do `AuthService` nem do token.** O token fica no Keychain com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (`KeychainManager.swift`), ou seja, **ilegível com o iPhone trancado**, e é aí que a compra do Apple Watch acorda o app em segundo plano. Com `AuthService.shared.currentUser`, o `checkAuthentication()` do `init` não acharia o token, `currentUser` ficaria `nil` e a compra seria recusada com um aviso enganoso.
  - Por isso a ação lê o `userId` direto do `user_data` do `UserDefaults` (o mesmo JSON `UserDTO` que o `AuthService` guarda em `userKey`), numa função pequena e testável (`UsuarioSalvo.id()`), e **só grava no aparelho**, o que não exige token.
  - Sem `user_data` (nunca logou ou saiu da conta), a ação recusa com diálogo ("Abra o SoftSpend e entre na sua conta.") e não grava nada. Tudo filtra por `userId`, então a compra nunca cai na conta errada.
  - **Efeito colateral a evitar:** se o processo ficar vivo depois da ação em segundo plano, o `AuthService.shared` já terá nascido com `isAuthenticated == false` e o usuário cairia na tela de login ao abrir o app (parece um logout). Por isso o `AuthService` repete `checkAuthentication()` quando a cena fica `.active` com `isAuthenticated == false` (só lê, nunca apaga nada).
- Sem `SyncManager` na ação: ela só grava no SwiftData e, se o `SyncManager` já estiver configurado (app aberto), pede `sync(forcar: true)` como o `createNewGasto` faz. Com o app fechado, quem sobe o gasto é o `onAppear` do `MainView`, como já acontece com qualquer gasto pendente.

### 1.4 A regra (lógica pura, testável): `RegistroApplePay`

Arquivo novo `SoftexVamo/SoftexVamo/Services/RegistroApplePay.swift`. A ação só chama isto; recebe `ModelContext`, `userId`, `agora` e `calendario`, para testar com banco em memória.

```swift
enum ResultadoRegistro: Equatable {
    case gravado(titulo: String, valor: Decimal, viagem: String, dia: Date)
    case guardadoSemViagem(titulo: String, valor: Decimal)   // vai para a fila (§1.5)
    case duplicado                                          // já registrado, nada mudou
    case recusado(MotivoRecusa)                             // .valorInvalido, .moedaEstrangeira, .semUsuario
}
```

**Valor** (`ValorDaCompra.interpretar(_ texto: String) -> Decimal?`):
- Aceita `R$ 1.234,56`, `1.234,56`, `1234,56`, `12,5`, `12.34`, com espaços (inclusive o espaço sem quebra) e sinal de menos (compras com sinal negativo viram positivas, porque algumas automações entregam `-12,34`).
- Vírgula é decimal; ponto seguido de exatamente 3 dígitos e de mais nada é milhar (`1.234`); ponto seguido de 1 ou 2 dígitos é decimal (`12.34`). Arredonda a 2 casas.
- **Recusa** (`.valorInvalido`) texto sem número, zero, e valor acima de **R$ 100.000** (provável erro de leitura).
- **Recusa** (`.moedaEstrangeira`) texto com símbolo ou código de outra moeda (`US$`, `$` sozinho, `€`, `£`, `USD`, `EUR`). Só `R$`, `BRL` ou sem símbolo passam. Por quê: gravar `10,00` dólares como `R$ 10,00` esconde o erro; recusar com aviso é honesto. O diálogo diz "Compra em outra moeda: lance no app".

**Estabelecimento:** `trimmingCharacters`, espaços repetidos viram um; vazio vira `"Compra no cartão"`. O Apple Pay costuma mandar o nome **em MAIÚSCULAS**: passar por `InterpretadorComprovante.formatarTitulo` (já existe) antes de gravar; a comparação de duplicata continua sem acento e sem maiúsculas.

**Categoria:** `InterpretadorComprovante.inferirCategoria(de: [estabelecimento]) ?? .OUTROS`. Reaproveita a lista de palavras que já existe (a mesma da leitura local do comprovante). Sem acertar, é `.OUTROS`, que o usuário troca editando o gasto. Limitação conhecida e herdada: a lista é curta e a ordem das categorias faz "Mercado Livre" cair em Alimentação; melhorar a lista é outra tarefa.

**Em qual dia o gasto entra:**
1. Viagens do usuário (`userId`), sem `deletadoEm`, cujo intervalo (`intervaloViagem`, que já usa os dias locais ou o `periodo`) **contém o dia de hoje**. Com mais de uma, a de primeiro dia mais recente (mesma regra de `cicloDoInicio`, mas **sem** cair na "próxima" ou na "última encerrada": isso não é viagem aberta).
2. Dentro dela, o `DiaSoftex` com `deletadoEm == nil` cuja `data` é hoje (`Calendar.isDate(_:inSameDayAs:)`).
3. Não achou viagem aberta ou não existe dia local de hoje (ex.: instalação nova que ainda não baixou os dias) → **fila "sem viagem"** (§1.5), nunca um dia errado.

**Gravação:** igual ao `CiclosViewModel.createNewGasto`, sem passar por ele (ele depende de `atualCiclo`, que é estado de tela):
- `GastosDia(valor:titulo:categoria:dia:)` + `modelContext.insert`, **sem** `dia.gastos.append` (pegadinha 3 do `AGENTS.md`), `ciclo.gasto_total += valor`, `try modelContext.save()`. `syncStatus` fica `.pending`.
- Se o `viewModel` estiver na tela, ele enxerga a mudança porque o contexto é o mesmo; a tarefa confere que `atualCiclo.gasto_total` e a lista de gastos do dia atualizam sem reabrir o app.

**Duplicata** (mesma compra chegando duas vezes: o Atalhos às vezes dispara duas vezes, e a automação do Apple Watch pode repetir):
- É duplicata se já existe gasto vivo (`deletadoEm == nil`) **ou item na fila** do mesmo usuário com **o mesmo valor, o mesmo estabelecimento (comparado sem acento, sem maiúsculas e sem espaços repetidos) e criado há menos de 60 segundos**. Resultado `.duplicado`, sem gravar.
- Janela de 60 s **deslizante** em vez de "mesmo minuto do relógio": duas chegadas às 10:04:59 e 10:05:01 são a mesma compra e cairiam em minutos diferentes.
- Não precisa de campo novo: usa `criadoEm`, `valor` e `titulo` que já existem. Efeito colateral aceito: um gasto digitado à mão com o mesmo valor e título no último minuto também bloqueia o atalho, o que é o que o usuário quer.
- Buscar por `criadoEm` no `#Predicate` e filtrar valor e título **em memória** (pegadinha 1: nunca `@Transient` no predicado).
- Duas compras iguais de verdade em menos de 1 minuto (dois cafés de R$ 6 passados seguidos) viram uma só. Limite conhecido e aceito; o usuário vê um só e lança o outro à mão.

### 1.5 Sem viagem aberta: **guardar numa fila e perguntar depois** (decisão)

**Decidi guardar, não recusar.** Por quê:
- A compra já aconteceu; recusar a perde. O aviso da recusa aparece no Atalhos como uma notificação fácil de ignorar, e o usuário só descobriria o buraco na fatura.
- Viajar sem ter criado a viagem ainda, ou ter esquecido de criar a do dia, é justamente o caso comum.

**Fila fora do SwiftData.** Mudar um `@Model` exige congelar o V1 e criar o V2 com migração (`AGENTS.md`, "Schema versionado"), o que é muito custo e risco para uma lista pequena e passageira. A fila é um arquivo **JSON** em `Application Support/compras-apple-pay.json` (`Codable`, escrita atômica), por usuário:

```swift
struct CompraAguardandoViagem: Codable, Identifiable {
    var id: UUID
    var userId: String
    var valor: Decimal
    var estabelecimento: String
    var cartao: String?
    var categoria: Categoria
    var recebidaEm: Date
}
```

- Teto de **50** itens por usuário; passando, a mais antiga sai.
- Nunca sai sozinha por tempo: só quando o usuário decide ou quando é lançada.
- O arquivo usa a proteção padrão do iOS (disponível depois do primeiro desbloqueio), para a ação rodar com o aparelho trancado.

**Perguntar depois (tela curta, sem pedir nada na hora):**
- No Início, quando há itens na fila do usuário, um aviso discreto com o padrão de `AlertaPendencia`: "N compras do Apple Pay esperando uma viagem".
- Toque abre uma folha com a lista. Cada item mostra estabelecimento, valor, cartão e data, e tem **"Lançar em …"** (a viagem aberta ou, se a compra é de outro dia, a viagem cujo intervalo contém o dia da compra, no dia da compra) e **"Descartar"**. Sem viagem possível para aquela data, só "Descartar" e o texto "Crie a viagem desta data para lançar".
- "Lançar" usa a mesma gravação do §1.4 (com o dia escolhido) e tira o item da fila só **depois** do `save()`. Falhou o save, o item fica.
- O `userId` do item precisa ser o do usuário logado: itens de outro usuário ficam intocados e escondidos.

### 1.6 Tela "Como ligar o Apple Pay"

`ComoLigarApplePayView`, aberta por uma linha **"Apple Pay (atalho)"** na seção Preferências de `PerfilView`. Curta, texto simples, estilo do `Tema`:

1. Abra o app **Atalhos** → aba **Automação** → **+** → **Transação** (em alguns iOS aparece como **Carteira**).
2. Escolha os cartões que quer acompanhar e marque **Executar imediatamente**.
3. Toque em **Criar novo atalho**, procure **SoftSpend → Registrar gasto** e preencha: Valor = **Valor**, Estabelecimento = **Estabelecimento**, Cartão = **Cartão ou passe**. (Usar os nomes que o iOS mostra; ver §1.2.)
4. Desligue **Notificar quando executar** (opcional, para não receber um aviso a cada compra).
5. Pague algo com o Apple Pay e confira no app.

Seção **"O que esperar"**, com as limitações honestas, sem enfeite:
- Só vale para compras pelo **Apple Pay** no iPhone ou no Apple Watch (não pega cartão físico, compra online sem Apple Pay, boleto, Pix).
- **Pode atrasar**, e o iPhone precisa ter sido desbloqueado ao menos uma vez desde que ligou.
- **Alguns bancos e cartões não disparam** a automação. Se a sua compra não aparecer, lance à mão ou escaneie o comprovante.
- Só reais; compra em outra moeda é recusada com aviso.
- O app escolhe a categoria pelo nome do local; confira e troque se precisar.
- "Nada sai do seu iPhone para outro serviço: o gasto é gravado no app e sobe só para o servidor do SoftSpend, como qualquer gasto."

A tela fica atrás da linha de Perfil e também aparece uma vez como dica no primeiro uso do aviso da fila (opcional). Sem botão "criar automação": a Apple não permite.

### 1.7 Privacidade, segurança e o que não muda

- **Nada passa por servidor de terceiros e o servidor não muda** (nenhuma rota, migration ou variável). O gasto sobe pelo `SyncManager` e pelo `POST` de gasto que já existe. Não há Gemini aqui; não precisa de consentimento novo e a Política de Privacidade (`docs/publicacao.md` §2) só ganha uma linha: o app grava a compra que o Apple Pay informa ao Atalhos.
- A fila de compras guarda estabelecimento e valor em arquivo local sem criptografia extra (os comprovantes têm AES, estes dados não são mais sensíveis do que os gastos, que ficam no SwiftData sem criptografia hoje). Não registra o número do cartão, que o Atalhos nem entrega.
- A ação roda com o aparelho trancado: não loga valor nem estabelecimento (`os.Logger` com `privacy: .private`).
- Sem mudança em `@Model`, **sem schema V2**.

### 1.8 Fora do escopo (decisões abertas)

- **Gravar o nome do cartão no gasto** exige campo novo no `@Model` e no servidor (V2 e migration). **Resposta do §2: a conciliação não precisa dele** (casa por valor, data e texto, §2.5), então continua fora.
- Aviso de 80% da diária ao registrar por atalho (`AvisoDiaria`): hoje só dispara dentro do fluxo do app; a v1 não dispara.
- Melhorar a lista de palavras por categoria.

### 1.9 Tarefa para o Devin (os detalhes estão aqui; a nota do projeto só aponta para esta seção)

Pode ir em duas partes: **A** = regra, ação, `BancoLocal`, `UsuarioSalvo`, tela de ajuda e testes; **B** = a fila "sem viagem" na tela Início (§1.5), só depois da A. Uma tarefa só também serve.

Arquivos: `Services/RegistroApplePay.swift` (regra), `Services/UsuarioSalvo.swift` (id sem token) e a releitura em `AuthService` ao ficar ativo, `Services/ComprasAguardandoViagem.swift` (fila JSON), `Intents/RegistrarGastoIntent.swift` e `Intents/SoftSpendAtalhos.swift`, `Models/BancoLocal.swift` (container único, extraído de `SoftexVamoApp`), `Scenes/ComoLigarApplePayView.swift`, linha em `PerfilView`, aviso e folha da fila no Início. Sem tocar em `@Model`, em `SyncManager.swift` nem no `Python/`.

Testes (Swift Testing, banco em memória, como `GastoDuplicadoTests`):
- `ValorDaCompraTests`: `R$ 12,34`, `12.34`, `1.234,56`, `1.234`, `12,5`, `-12,34`, `0`, `abc`, `US$ 10,00`, `€ 5`, acima do teto.
- `RegistroApplePayTests`: grava no dia de hoje da viagem aberta e soma no `gasto_total`; não duplica a relação `dia.gastos`; `syncStatus == .pending`; categoria sugerida (`Uber` → Transporte, `Cinemark` → Lazer, desconhecido → Outros); viagem encerrada ou futura não conta; viagem apagada não conta; viagem de outro usuário não conta; duas viagens que se sobrepõem usam a de primeiro dia mais recente; sem viagem vai para a fila; viagem sem dia local de hoje vai para a fila; duplicata em 30 s (barrada), em 61 s (grava), com título em outra caixa ou com acento (barrada), valor diferente (grava), contra item da fila (barrada); gasto apagado (`deletadoEm`) não conta para duplicata.
- `ComprasAguardandoViagemTests`: ler e gravar o JSON, teto de 50, isolamento por usuário, lançar remove só depois do `save`, arquivo corrompido vira lista vazia sem derrubar o app.
- `UsuarioSalvoTests`: com `user_data` no `UserDefaults` e **sem token no Keychain**, `UsuarioSalvo.id()` devolve o id e o registro grava o gasto; sem `user_data`, recusa (`.semUsuario`) e não grava.
- `BancoLocal` e a ação: um teste de fumaça que a ação existe e que o container compartilhado não é criado duas vezes.

Pronto quando o CI (`.github/workflows/ios.yml`) compilar e todos os testes passarem; conferir no iPhone real o passo a passo do §1.2 e **anotar no PR os nomes exatos das variáveis do iOS** para ajustar o texto da §1.6.

---

## 2. Importar a fatura em PDF pela IA e conciliar

### 2.1 O que o usuário vê

1. Na tela da **viagem**, toca em **"Importar fatura do cartão"** e escolhe o arquivo (PDF; OFX ou CSV, se tiver).
2. Na primeira vez, o app mostra um aviso curto (§2.8) e só segue se a leitura por IA estiver permitida (o mesmo interruptor do comprovante, `Consentimento.leituraAutomatica`).
3. O servidor lê as compras (alguns segundos) e o app mostra **uma lista para conferir**, já separada:
   - **Já lançadas** (batem com um gasto da viagem): selo "Na fatura" ou "Revisar" (§2.5), com "Confirmar" e "Desvincular".
   - **Faltam na viagem**: compras da fatura dentro das datas da viagem sem gasto correspondente, cada uma com caixa de seleção **desmarcada** e o botão "Marcar todas".
   - **Fora desta viagem (N)**: o resto da fatura (o mês inteiro), recolhido e ignorado.
4. Toca em **"Importar"**. Só então algo é gravado: o app cria, como gasto comum, as compras marcadas (SwiftData primeiro, `SyncManager` depois) e o servidor guarda as compras mantidas e os vínculos. **Nada é criado, nem no aparelho nem no servidor, antes desse toque.**

Por que desmarcadas: uma compra "que falta" pode ser um gasto que a pessoa digitou com valor diferente (gorjeta, arredondamento). Marcar sozinho criaria duplicata; marcar à mão custa um toque.

### 2.2 O que existe e o que se reaproveita

O Open Finance desligado já tem a parte difícil da conciliação. **O que é do Pluggy** (`open_finance_service.py`, `/api/connect-token`, o webhook, `sincronizar_item`, `OPEN_FINANCE_ENABLED`) **não é tocado.** O que é da fatura passa a viver à parte e sempre ligado:

| Peça existente | Uso na fatura |
| --- | --- |
| `open_finance_reconciliation_service.py` (`_pontuacao`: valor exato, janela de data, texto; limiares 80 e 65) | **Reaproveitado.** Só não pode depender de `CreditCardTransaction` do ORM: a pontuação passa a aceitar qualquer objeto com `amount`, `date` e `merchant_name`/`description` (a prévia da §2.5 pontua compras ainda não gravadas). Nenhuma regra muda |
| Tabelas `credit_card_accounts`, `credit_card_bills`, `credit_card_transactions`, `expense_transaction_matches` | **Reaproveitadas** (§2.6): migration pequena |
| `open_finance_repository` (criar, confirmar e remover match; listar gastos sem match) | **Reaproveitado**, sem mudança |
| `CreditCardBillDetailResponse`, `CreditCardTransactionResponse`, `ExpenseTransactionMatchResponse` | **Reaproveitados** nas respostas |
| `/api/open-finance/*` | **Ficam como estão**, atrás de `OPEN_FINANCE_ENABLED`. As rotas novas ficam em `/api/faturas`, sempre registradas (§2.4) |
| `GastoResponse.open_finance_status` / `open_finance_match` e os campos já cacheados em `GastosDia` | **Reaproveitados:** o selo do gasto já chega ao app |
| `OpenFinanceMatchStatus` (títulos, ícones, cores), `FaturaDetalheView` | **Reaproveitados** na conferência |
| `FaturaCartao` / `TransacaoCartao` / `CartaoOpenFinance` (SwiftData) | **Não usados na v1** (decisão abaixo) |

**Decisão: sem cache SwiftData da fatura na v1.** Os três `@Model` exigem um `cartao` do Pluggy (`conexaoBackendId` obrigatório) e um campo novo (emissor, final do cartão) obrigaria a congelar o V1 e criar o V2 (`AGENTS.md`). A importação precisa de internet de qualquer forma; o app mostra a conferência com um `struct` em memória e o histórico lido do servidor. O que importa offline já está no gasto (`open_finance_status`). Se um dia o histórico precisar funcionar offline, é uma tarefa própria, com V2.

### 2.3 Arquivos, limites e o que é guardado

| Item | Decisão |
| --- | --- |
| Tipos aceitos | **PDF** (principal), **OFX** e **CSV** (só se simples, §2.7). PDF conferido pelos bytes (`filetype`), como em `_ler_arquivo`; OFX e CSV são texto, conferidos por decodificação e cabeçalho |
| Tamanho | **PDF: 10 MB** (igual ao `TAMANHO_MAXIMO_PDF` do comprovante) e **no máximo 20 páginas**. **OFX e CSV: 2 MB.** Leitura em pedaços, como hoje. Acima: `413` com texto claro |
| PDF com senha | Bancos costumam proteger a fatura (senha = dígitos do CPF). O app pede a senha (campo `senha` do formulário); o servidor abre com `pypdfium2`, que **já é dependência**, e regrava o PDF sem proteção **em memória**. A senha **nunca é guardada nem logada**. Senha errada: `422` "senha incorreta" |
| **PDF, OFX e CSV originais** | **Não são guardados.** Ficam só em memória durante a requisição: nunca vão para disco nem para o S3 (diferente do comprovante, que é arquivado) e não aparecem em log. É o mais simples **e** o que menos expõe: a fatura tem nome, endereço e limite |
| O que se guarda (só depois do toque em "Importar") | Só as **compras que a pessoa deixou na conferência** (as da viagem e as que ela marcar), em `credit_card_transactions`: data, descrição, valor, parcela (`2/5`), categoria sugerida. Mais uma linha em `credit_card_bills` (vencimento, fechamento, total) e em `credit_card_accounts` (emissor e **final** do cartão, nunca o número inteiro). O resto do mês e os dados pessoais do PDF são **descartados** |
| Retenção | Até a pessoa **apagar a fatura** (`DELETE /api/faturas/{id}`) ou excluir a conta (as chaves estrangeiras já apagam em cascata). Entra no prazo da Política (publicacao U9) |

### 2.4 Rotas novas (sempre registradas: não dependem de `OPEN_FINANCE_ENABLED` nem de `PLUGGY_*`)

Um `controllers/fatura_controller.py` novo, incluído no `main.py` sem condição. `GET /api/features` **não muda** (`test_features.py` compara o dicionário inteiro); o app descobre a falta da chave do Gemini pelo `503`, como já acontece com o OCR.

| Rota | O que faz |
| --- | --- |
| `POST /api/faturas/ler` (multipart: `arquivo`, `senha?`, `ciclo_id?`) | Lê o arquivo e devolve a **prévia**. **Não grava nada.** Limite de `5/minuto` por usuário |
| `POST /api/faturas` | Grava a fatura e as compras confirmadas (idempotente, §2.6) e concilia. Devolve `CreditCardBillDetailResponse` |
| `POST /api/faturas/{id}/conciliar` | Roda a conciliação de novo (o app chama depois de sincronizar os gastos criados na conferência) |
| `GET /api/faturas` e `GET /api/faturas/{id}` | Histórico e detalhe (só do usuário; de outro usuário é `404`) |
| `DELETE /api/faturas/{id}` | Apaga a fatura importada, suas compras e vínculos (só `origem = FATURA`) |
| `POST /api/faturas/matches/{id}/confirm` e `DELETE /api/faturas/matches/{id}` | Mesmo efeito dos matches do Open Finance, chamando as mesmas funções do repositório (as rotas antigas seguem atrás do interruptor) |

Resposta de `ler` (`dtos/fatura.py`):

```
FaturaLida {
  emissor: str | null, final_cartao: str(4) | null,
  fechamento: date | null, vencimento: date | null,
  total_fatura: Decimal | null, moeda: "BRL",
  soma_confere: bool | null, diferenca: Decimal | null,
  avisos: [str],
  compras: [ CompraLida {
      indice: int, data: date, descricao: str, valor: Decimal,
      parcela_atual: int | null, parcela_total: int | null,
      tipo: "COMPRA" | "ESTORNO" | "ENCARGO",
      categoria: Categoria, valor_original: str | null,
      dentro_da_viagem: bool, dia_id: int | null,
      match: { gasto_id, score, status } | null } ]
}
```

### 2.5 Leitura pela IA e conciliação

**Leitura (`services/fatura_ia_service.py`, novo; `ocr_service.py` quase intacto).** Usa o mesmo cliente Gemini e o mesmo modelo (`GEMINI_MODEL_NAME`, `GEMINI_API_KEY`; sem a chave, `503`). Diferenças em relação ao comprovante:

- O **PDF vai nativo** (`Part.from_bytes(..., mime_type="application/pdf")`), sem rasterizar: o Gemini lê a camada de texto e as tabelas melhor que uma foto.
- Saída estruturada (`response_schema`) com lista de compras; `MAX_OUTPUT_TOKENS` próprio de **16.384** (o de 256 é do comprovante) e **teto de 200 compras**. Se a resposta cortar (`MAX_TOKENS`), `422` "fatura grande demais; envie em OFX ou CSV".
- **Timeout próprio de 60 s** por requisição (o cliente atual tem 12 s, curto demais para uma fatura). O app espera até 90 s.
- Prompt: ignore nome, endereço, CPF, limite e propaganda; devolva só compras, estornos e encargos (IOF, juros, anuidade); **não** devolva "pagamento recebido" nem saldo anterior; data completa (o ano é deduzido pelo vencimento); parcela em campos próprios; compra em moeda estrangeira com o valor **em reais cobrado na fatura** e o original em `valor_original`; categoria pelo mesmo enum do comprovante.

**A IA é tratada como não confiável (o servidor valida, não confia):**

- `soma_confere`: soma de compras e encargos menos estornos contra `total_fatura` (tolerância R$ 0,05). Se não bate, o app mostra "Não consegui ler tudo: confira a lista" e a `diferenca`. É a defesa principal contra compra omitida ou inventada.
- Descarta (com aviso) compra com data fora de `[fechamento − 40 dias, vencimento]`, valor `<= 0` ou acima de R$ 100.000, ou descrição vazia.
- O texto do PDF pode tentar instruir o modelo ("ignore as regras..."): a saída é só dado validado e nada é executado a partir dela; o pior caso é uma lista errada, que a pessoa confere.

**Prévia da conciliação** (`fatura_service`, sem gravar). Se veio `ciclo_id`, as compras com data entre a ida e a volta ganham `dentro_da_viagem = true` e `dia_id`. Cada uma é pontuada contra os **gastos vivos da viagem** pela `_pontuacao` existente (valor exato; compra de 1 dia antes a 5 dias depois da data do dia do gasto; texto):

- `>= 80` e sem empate: `AUTO_MATCHED`. `65 a 79` ou empate: `REVIEW`. Menos: sem vínculo.
- **Um gasto casa com uma compra só e vice-versa** (atribuição gulosa pela maior pontuação, como `conciliar_gasto` já faz com `uix_expense_match_gasto` e `uix_expense_match_transaction`).
- `ESTORNO` e `ENCARGO` nunca casam (ficam fora do filtro `DEBIT`/`None` que já existe); as compras viram `type = "DEBIT"`.
- **Limitação aceita:** a prévia só vê gastos **já enviados ao servidor**. O app roda `sync(forcar: true)` antes de chamar `ler` e, se ainda houver pendentes, avisa "N gastos ainda não enviados podem aparecer como faltando".
- **Parcelas:** a fatura mostra a parcela (R$ 200 de 3x) e o gasto costuma ter o total (R$ 600). Não casa; aparece em "Faltam" com o texto "parcela 2 de 3", e a pessoa decide.

**Depois de "Importar":** o app cria os gastos marcados na data da compra, no `DiaSoftex` local daquele dia (compra sem dia na viagem nem aparece na lista). Quando eles sincronizam, chama `POST /api/faturas/{id}/conciliar`, que reaproveita `conciliar_usuario`: os gastos criados casam com as compras marcadas pela mesma regra (valor e data iguais).

### 2.6 Banco (migration nova) e dedupe

Hoje as tabelas exigem Pluggy (`conexao_id NOT NULL`). Uma migration nova, `f2c4e6a8b0d2` (cabeça atual: `e8a2b5c7d9f1`), **aplicada nos dois bancos** (local e AWS):

- `credit_card_accounts.conexao_id` passa a aceitar `NULL`.
- Coluna nova `credit_card_accounts.origem String(20) NOT NULL DEFAULT 'PLUGGY'` (`PLUGGY` ou `FATURA`).
- `account_id`, `bill_id` e `transaction_id` continuam únicos e obrigatórios: as importadas usam `fatura:<uuid>` e `fatura:<sha256>`, que nunca colidem com os do Pluggy.
- O cartão é achado ou criado por `(user_id, origem = FATURA, emissor, final_cartao)`.
- **Idempotência:** o `transaction_id` é `fatura:` + sha256 de `user_id | cartão | data | valor | descrição normalizada | parcela | tipo | ordem entre iguais` (o tipo evita que um estorno idêntico a uma compra seja confundido com ela; a ordem desempata duas compras idênticas no mesmo dia). Importar o mesmo arquivo duas vezes, ou a fatura aberta e depois a fechada, **não duplica** (as repetidas são puladas). A fatura é achada por `(cartão, vencimento)`; se o total mudou, atualiza.
- Downgrade: apaga as linhas `origem = FATURA` e remove a coluna; `conexao_id` volta a `NOT NULL`.

### 2.7 OFX e CSV (sem IA, sem custo)

- **OFX** (`<STMTTRN>`: `TRNTYPE`, `DTPOSTED`, `TRNAMT`, `MEMO`/`NAME`, `FITID`): lido por regex em `services/fatura_arquivo_service.py`, sem biblioteca nova. O sinal de `TRNAMT` varia por banco: normaliza para compra positiva usando `TRNTYPE` (DEBIT/CREDIT) e, sem ele, o sinal da maioria; "pagamento recebido" sai da lista. Exato, rápido e **não envia nada ao Gemini** (o aviso da §2.8 diz isso).
- **CSV:** só quando o cabeçalho tem colunas reconhecíveis de data, descrição e valor (ex.: `date,category,title,amount`; `Data;Descrição;Valor`), separador `,` ou `;`, decimal com vírgula ou ponto. Formato desconhecido: `422` "Formato não reconhecido; envie o PDF". Também sem IA.
- Ambos passam pela mesma validação e prévia. O `total_fatura` do OFX vem de `LEDGERBAL`; o do CSV não vem, então `soma_confere` fica `null`.

### 2.8 Consentimento, privacidade e Política

- **Mesmo consentimento do comprovante** (decisão do usuário): a importação exige `Consentimento.leituraAutomatica == true`; sem ele, o app oferece a mesma pergunta (`ConsentimentoLeituraView`).
- **Ajuste necessário:** o texto atual fala em "foto do comprovante". Passa a dizer "foto ou arquivo (comprovante ou fatura)". Quem já respondeu "sim" aceitou só comprovante, e a fatura tem mais dado pessoal; por isso, **além do interruptor**, a primeira importação mostra um aviso de uma tela, com **Continuar** e **Agora não**, guardado em `Consentimento.avisoFatura`:
  - **Texto final do aviso (F2, decidido em 13/11):**
    - Título: "Antes de importar sua fatura"
    - Corpo: "Para ler os gastos, o SoftSpend envia o PDF da fatura a um serviço de inteligência artificial (Google Gemini), que devolve a lista de compras. A fatura pode ter seu nome, endereço e os 4 últimos números do cartão. O arquivo não fica guardado no SoftSpend: só as compras que você confirmar. Arquivos OFX e CSV são lidos pelo nosso servidor e não vão para a IA."
    - Botões: **Continuar** (segue para escolher o arquivo) e **Agora não** (volta sem enviar nada e sem marcar o aviso como visto, então ele reaparece na próxima vez).
  - É informativo, não um segundo interruptor. Aparece uma vez, antes do primeiro envio de PDF, depois de `Consentimento.leituraAutomatica` estar ligado; "Continuar" grava `Consentimento.avisoFatura`. Para OFX e CSV não há aviso, pois nada vai a terceiros.
  - Se a Política de Privacidade ou o plano do Gemini (G1) mudarem o que é dito sobre retenção, este texto e a ficha da App Store mudam juntos. Não prometer "o Google não guarda" enquanto o G1 não estiver resolvido.
- **A chave do Gemini no plano pago (G1) é pré-requisito para qualquer pessoa de fora usar isto.** A fatura é mais sensível que um comprovante; no plano gratuito o Google pode usar o conteúdo para melhorar os modelos (`docs/publicacao.md` §2.1). Pode-se desenvolver e testar antes; **não liberar ao público** sem G1.
- **O servidor não registra** conteúdo da fatura, descrições nem valores em log (só tamanho, páginas, número de compras, tempo e tokens). Nunca loga a senha do PDF.
- **O que muda na Política de Privacidade** (`docs/publicacao.md` §2; rascunho do Claude, revisão no U8):
  1. Citar a fatura do cartão como mais um documento enviado à leitura por IA (Google Gemini, plano pago, envio ao exterior), com o mesmo texto de retenção do Google que a §2.1 pede.
  2. Dizer que o arquivo **não é guardado**, que pode conter nome, endereço e final do cartão, e que só as compras confirmadas e o final do cartão (4 dígitos) são gravados.
  3. Prazo e exclusão: as compras importadas ficam até a pessoa apagar a fatura ou excluir a conta.
  4. OFX e CSV são lidos no nosso servidor, sem terceiros.
  5. O app nunca pede a senha do banco nem acessa a conta no banco (diferente do Open Finance).
  - A tela de consentimento e a ficha de privacidade da App Store ("dados financeiros: compras") têm de dizer o mesmo.

### 2.9 Custo do Gemini por fatura (estimativa)

Mesmos preços da `docs/publicacao.md` §1.1: `gemini-3.5-flash-lite`, US$ 0,30 por milhão de tokens de entrada e US$ 2,50 por milhão de saída; **R$ 5,50 por US$ 1**. Cada página de PDF vale ≈ 258 tokens.

| Caso | Entrada | Saída | Custo |
| --- | --- | --- | --- |
| Típica: 4 páginas, 40 compras | ≈ 1.600 | ≈ 3.000 | ≈ US$ 0,008 ≈ **R$ 0,05** |
| Pesada: 10 páginas, 150 compras | ≈ 3.500 | ≈ 7.500 | ≈ US$ 0,020 ≈ **R$ 0,11** |
| Teto: 20 páginas, 200 compras (corte em 16.384) | ≈ 6.000 | ≤ 16.384 | ≤ US$ 0,043 ≈ **R$ 0,24** |

- **≈ 5 a 10 centavos por fatura**, uns 5 a 10 comprovantes. Ainda barato (uma viagem usa 1 ou 2 faturas), mas **a saída é o que pesa**: por isso o teto de 200 compras e as 5 leituras por minuto. OFX e CSV custam zero.
- São estimativas. A tarefa S1 **loga `usage_metadata`** (tokens de entrada e saída, sem conteúdo) para conferir nos primeiros usos reais.
- Se a assinatura (publicacao U2) bloqueia "ler comprovante com IA", a importação de fatura entra no mesmo bloqueio.

### 2.10 Fora do escopo

- Cache offline do histórico de faturas (exige V2 do SwiftData, §2.2).
- Gravar o cartão no gasto (§1.8).
- Fatura em moeda que não seja a cobrada em reais.
- Estorno que apaga ou reduz um gasto: o estorno aparece na lista, mas a v1 não mexe em gastos por causa dele.
- Ler fatura por foto ou captura de tela (só PDF, OFX e CSV).

### 2.11 Tarefas para o Devin

Ordem: **S1** (leitura) e depois **S2** (gravação e conciliação) no servidor, depois **A1** (app). Cada uma é um PR e atualiza o `AGENTS.md` (rotas novas, cadeia de migrations, nota do consentimento). S1 e S2 mexem no mesmo `fatura_controller.py`, por isso sobem em sequência.

**S1: leitura da fatura (servidor, sem gravar nada)** (complexa)

- Arquivos: `Python/services/fatura_ia_service.py`, `Python/services/fatura_arquivo_service.py` (OFX, CSV e abrir PDF com senha), `Python/dtos/fatura.py`, `Python/controllers/fatura_controller.py` (só `POST /api/faturas/ler`, sem `ciclo_id`), `Python/main.py` (incluir o router **sem** `OPEN_FINANCE_ENABLED`).
- Limites (§2.3), prompt, validações e `soma_confere` (§2.5), log de `usage_metadata` sem conteúdo.
- Não tocar em `open_finance_*`, na migration nem em `ocr_service.py` (só importa dele o cliente e o modelo).
- Testes, com o Gemini **substituído por um falso** (sem chamada real):
  - PDF válido devolve compras; PDF de 11 MB `413`; mais de 20 páginas rejeitado; arquivo de outro tipo `400`; imagem renomeada como PDF `400`.
  - PDF com senha: certa, errada (`422`) e ausente (`422`).
  - OFX com sinais invertidos; OFX com pagamento (sai da lista); CSV conhecido e desconhecido (`422`).
  - Resposta cortada por `MAX_TOKENS` (`422`); data absurda ou valor `<= 0` descartados com aviso; `soma_confere` verdadeiro e falso.
  - Sem `GEMINI_API_KEY`: PDF dá `503`, **OFX e CSV continuam funcionando**.
  - `OPEN_FINANCE_ENABLED=false` e sem `PLUGGY_*`: a rota responde (não `404`), `/api/open-finance/cards` segue `404` e `/api/features` não muda.
  - Sem token `401`; nada é gravado (contagem das tabelas igual antes e depois; `storage_service` nunca chamado); o log não contém descrição nem valor.
- Pronto quando `pytest -q` passa.

**S2: conciliação, gravação e migration (servidor)** (complexa)

- Arquivos: `Python/alembic/versions/f2c4e6a8b0d2_*.py` (§2.6), `Python/models/open_finance.py` (`origem`, `conexao_id` nullable), `Python/services/open_finance_reconciliation_service.py` (pontuação sem depender do ORM, **sem mudar regra nenhuma**), `Python/services/fatura_service.py` (prévia, hash, gravar, idempotência), `Python/controllers/fatura_controller.py` (`ciclo_id` em `ler`, `POST /api/faturas`, `/conciliar`, `GET`, `DELETE`, matches), `Python/dtos/fatura.py`.
- Aplicar a migration **nos dois bancos** e atualizar o `AGENTS.md`.
- Testes:
  - Os do Open Finance continuam passando **sem alteração**.
  - Prévia: valor e data iguais (`AUTO_MATCHED`); alguns dias depois (o que a pontuação der); valor diferente (sem vínculo); fora da janela (sem vínculo); empate entre dois gastos iguais (`REVIEW`); um gasto não casa com duas compras e uma compra não casa com dois gastos.
  - Gasto de outra viagem, de outro usuário ou apagado nunca entra; compra fora das datas da viagem fica `dentro_da_viagem = false`; estorno e encargo nunca casam.
  - Gravar duas vezes o mesmo arquivo **não duplica** (fatura nem compras); duas compras idênticas no mesmo dia continuam duas; só as compras enviadas são gravadas.
  - `GET` e `DELETE` de fatura de outro usuário dão `404`; `DELETE` leva compras e vínculos e **não** apaga os gastos; confirmar e desvincular match; `POST /conciliar` casa gastos criados depois.
  - Gravar com `OPEN_FINANCE_ENABLED=false` funciona.
  - A migration sobe e desce num banco limpo e num banco que já tem linhas do Pluggy (ficam `origem = PLUGGY`).

**A1: importar a fatura no app** (complexa; só depois da S1 e da S2 na `main`)

- Só `SoftexVamo/`, **sem tocar em `@Model`** (sem V2).
- Arquivos: `Network/NetworkManager.swift` (`lerFatura`, `confirmarFatura`, `conciliarFatura`, timeout de 90 s), `Models/DTOs/FaturaDTO.swift`, `ViewModels/ImportarFaturaViewModel.swift` (máquina de estados testável sem tela: escolhendo, consentindo, lendo, conferindo, importando, pronto, erro), `Scenes/ImportarFaturaView.swift` (§2.1; `.fileImporter` para PDF, OFX e CSV; campo de senha quando o servidor pedir; três grupos), botão na tela da viagem, `Scenes/ConsentimentoLeituraView.swift` (texto da §2.8) e `Consentimento.avisoFatura`.
- Criar os gastos marcados pelo caminho existente (`CiclosViewModel.createNewGasto`, sem `dia.gastos.append`, pegadinha 3); `sync(forcar: true)` antes de `ler` e `conciliar` depois.
- Testes (Swift Testing, rede falsa):
  - O DTO decodifica a resposta (parcela e `valor_original` incluídos).
  - **Nada é criado antes de "Importar"** (nem gasto local nem chamada de gravação); só as marcadas viram gasto, no `DiaSoftex` certo e `.pending`; "Marcar todas".
  - Consentimento recusado não chama o servidor; arquivo grande demais ou de tipo errado é barrado no aparelho antes do envio.
  - `422` de senha pede a senha; `503` mostra "leitura indisponível"; `soma_confere == false` mostra o aviso; pendentes antes da leitura mostram o aviso.
  - Falha de rede na gravação não cria gasto nenhum (o servidor grava primeiro, depois o app cria).
- Pronto quando o CI compilar e os testes passarem; conferir no iPhone real com uma fatura de verdade (PDF e, se o banco der, OFX).

### 2.12 Perguntas para o usuário

1. **A importação da fatura entra no bloqueio da assinatura**, junto com "ler comprovante com IA" (publicacao U2)? Recomendo que sim: é o uso com custo por vez (R$ 0,05 a R$ 0,11).
2. **G1 (Gemini com faturamento) antes de qualquer pessoa de fora usar.** Pode ser feito e testado antes, mas não liberado.
3. O aviso extra da primeira importação (§2.8) ao lado do mesmo interruptor: concorda, ou prefere um interruptor separado "Ler fatura"?
