# Cartão sem Open Finance

Decisão do usuário (12/11): ligar o cartão ao SoftSpend **sem pagar o piso dos agregadores** (Pluggy e parecidos).
O código do Open Finance continua no repositório, desligado (`OPEN_FINANCE_ENABLED=false`).
Dois caminhos, que se completam:

1. **§1 (este documento, parte 1):** registrar o gasto na hora, pelo atalho do Apple Pay.
2. **§2 (parte 2, ainda não escrita):** importar a fatura em PDF pela IA e conciliar com os gastos.

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

- **Gravar o nome do cartão no gasto** (para filtrar ou conciliar com a fatura do §2) exige campo novo no `@Model` e no servidor (V2 e migration). Fica para depois do §2, que define o que a conciliação precisa.
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

_Ainda não escrito: é a parte 2 do plano._
