# Redesenho visual do app iOS — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refazer a camada visual do app iOS do SoftSpend seguindo as 18 telas aprovadas, sem perder nenhuma função que existe hoje.

**Architecture:** Primeiro os tokens (cores claro/escuro, tipografia, espaçamentos) e uma camada de cálculo pura e testada (`ResumoViagem`), depois os componentes visuais, depois as telas, uma por tarefa. O que busca dados e sincroniza (SwiftData, `SyncActor`, `NetworkManager`, DTOs) não muda; o `CiclosViewModel` só ganha a escolha do ciclo do início e perde o bloqueio de saldo na edição.

**Tech Stack:** SwiftUI, SwiftData, Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift Testing, UserNotifications, Xcode no Mac do usuário.

**Spec:** `docs/superpowers/specs/2026-11-09-redesenho-visual-design.md` — telas aprovadas: `docs/superpowers/specs/telas/2026-11-09-todas-as-telas.html` (abrir no navegador; botão troca claro/escuro). Leia os dois antes de começar.

**Claude Design (referência viva, mesmas telas):** Design System "SoftSpend" — https://claude.ai/artifact/Ata2yxRut3wkQGMvv2Epad (tokens claro/escuro, tipografia, espaçamentos, raios e os componentes `CartaoPassagem`, `BarrasPorDia`, `LinhaGasto`, `Selo`, `AlertaPendencia`, `Botoes`); canvas "SoftSpend — telas do redesenho" — https://claude.ai/artifact/7NmBpiyCPVAfEPYqSPFoWd (as 18 telas, cada uma com o tema no botão Tweaks). Os nomes de cor do `tokens.json` do Design System são os nomes dos Color Sets da Tarefa 1 (`fundo`, `superficie`, `superficie-2`, `borda`, `texto`, `texto-fraco`, `barra-dia`, `marca`, `marca-botao`, `marca-texto`, `marca-fundo`, `estouro`, `alerta-texto`, `alerta-fundo`, `alerta-borda`, `ok`, `ok-fundo`, `cat-*`). Os links são privados do João: se a sessão não conseguir abri-los, siga o HTML do repositório, que tem as mesmas telas.

## Global Constraints

- Branch `redesenho-visual`; a `main` fica com a versão antiga. Commits pequenos, um por tarefa (ou por passo de commit).
- Só a camada visual muda. Exceções permitidas pelo spec: tirar o bloqueio de saldo do `editGasto`; escolher o ciclo do início pela data de hoje; derivar valores no ViewModel. Nada em `Python/`.
- Roxo só como marca: logo, ícone de avião da rota, barra do dia de hoje, botão principal. Proibidos: `LinearGradient` roxo, brilhos/estrelinhas de "IA", ilustração 3D (imagens `bagagem`/`maleta`), emoji como ícone, grade de cartõezinhos com ícone em quadradinho.
- Temas claro e escuro iguais em qualidade; o app segue o tema do iPhone. Contraste AA nos dois.
- Paleta: os valores exatos e as regras de uso estão em `docs/superpowers/specs/design-system/tokens.json` (claro = `light`, escuro = `dark`); o resumo está no design. Fundo #F2F2F7 / #000, superfície #FFF / #1C1C1E, sem bordas em cartões.
- Dinheiro sempre em pt-BR ("R$ 1.183,00"), SF Pro com algarismos tabulares (`.monospacedDigit()`), independente do idioma do aparelho. **Nunca** fonte mono.
- Tipografia: SF Pro em toda a interface; **SF Pro Expanded** (`.fontWidth(.expanded)`) só nos códigos da passagem e no valor de destaque.
- Texto: títulos e rótulos em caixa normal ("Hoje", "Antes de gerar"); sem pontinhos (·) ligando dados, sem setas no texto; frases como "Você gastou R$ 147,70 dos R$ 450 de hoje", "2 gastos sem foto", "Falta a foto". Logo = símbolo de bilhete roxo + "SoftSpend" numa cor só.
- Formas: só a passagem tem raio 20 e recortes; listas agrupadas raio 12 sem borda (divisória 0,5 pt); botões em pílula.
- Ícones em SF Symbols. Categorias continuam as 5 de hoje (`Categoria`: Alimentação, Transporte, Lazer, Compras, Outros); a "Hospedagem" do esboço 10 **não** entra (exigiria backend).
- Dynamic Type nos textos; VoiceOver lê "Ainda dá para gastar hoje, R$ X" e o estado de cada barra ("21 de julho, passou R$ 38").
- Textos com acento correto ("Não tem conta?", "começar", "usuário").
- Consentimento da leitura automática obrigatório antes de enviar foto ao Gemini (`AGENTS.md`, LGPD).
- Verificação visual de cada tela: build, simulador, captura nos dois temas, comparada com a tela de mesmo número no HTML aprovado.

Comandos (no Mac, de dentro de `SoftexVamo/`):

```bash
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
$XB -project SoftSpend.xcodeproj -scheme SoftSpend -destination 'platform=iOS Simulator,name=iPhone 16' test
$XB -project SoftSpend.xcodeproj -scheme SoftSpend -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build build
xcrun simctl boot "iPhone 16"; xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/SoftSpend.app
xcrun simctl launch booted <bundle id do app>
xcrun simctl ui booted appearance light   # ou dark
xcrun simctl io booted screenshot capturas/<tela>-<tema>.png
```

`capturas/` fica fora do git (adicionar ao `.gitignore` na Tarefa 1).

## Review Focus

1. **Viagem sem dias ou vazia** (`CicloSoftex.vazio`, `periodo` vazio, `dias == nil`): o início mostra o estado vazio "Nenhuma viagem agora", sem travar. Teste em Tarefa 2.
2. **Diária zero ou viagem de 1 dia**: barras sem divisão por zero (altura 0 e nenhum dia "estourado" por arredondamento). Teste em Tarefa 2.
3. **Aparelho em inglês ou outro idioma**: valores continuam "R$ 1.183,00". Teste em Tarefa 1.
4. **Virada do dia / fuso**: um gasto às 23:50 conta para aquele dia, e "hoje" é decidido por `Calendar.current.isDate(_:inSameDayAs:)`, não por comparação de `Date`. Teste em Tarefa 2.
5. **Sem internet**: salvar um gasto (com ou sem foto) funciona offline e aparece no início na hora, com sincronização pendente; nenhuma tela nova espera a rede para mostrar dados locais. Teste em Tarefa 7 (passo de verificação manual no simulador com rede desligada).

---

### Tarefa 0: Alvo de testes

**Files:**
- Modify: `SoftexVamo/SoftSpend.xcodeproj/project.pbxproj` (novo alvo `SoftSpendTests`)
- Create: `SoftexVamo/SoftSpendTests/SmokeTests.swift`

- [ ] **Passo 1:** Criar no Xcode o alvo de testes unitários `SoftSpendTests` (File › New › Target › Unit Testing Bundle, Swift Testing, "Target to be Tested" = SoftSpend) e adicioná-lo ao scheme `SoftSpend` (Test). Se for feito por script, usar a gem `xcodeproj`.
- [ ] **Passo 2:** `SmokeTests.swift` com `@Test func appCompila() { #expect(Categoria.allCases.count == 5) }` (com `@testable import SoftSpend`).
- [ ] **Passo 3:** Rodar o comando `test`. Esperado: `** TEST SUCCEEDED **`, 1 teste.
- [ ] **Passo 4:** Commit `test: alvo SoftSpendTests`.

### Tarefa 1: Tokens visuais e formatação de dinheiro

**Files:**
- Create: Color Sets em `SoftexVamo/SoftexVamo/Assets.xcassets/Tema/`, um por cor do `tokens.json` do Design System (valores exatos de lá, Any = `light`, Dark = `dark`). O botão principal usa `marca-botao` (#7C3AED nos dois temas: texto branco a 5,7:1); as cores de categoria `cat-*` foram escurecidas para o glifo branco passar 3:1.
- Create: `SoftexVamo/SoftexVamo/Tema/Tema.swift`
- Create: `SoftexVamo/SoftSpendTests/FormatacaoTests.swift`
- Modify: `.gitignore` (`capturas/`)

**Interfaces:**
- Produces: `enum Tema` com uma `static let <nome em camelCase>: Color` por Color Set (`fundo`, `superficie`, `superficie2`, `borda`, `texto`, `textoFraco`, `barraDia`, `marca`, `marcaBotao`, `marcaTexto`, `marcaFundo`, `estouro`, `alertaTexto`, `alertaFundo`, `alertaBorda`, `ok`, `okFundo`); `enum Espaco { static let p: CGFloat = 8, m = 12, g = 16 }`; `enum Raio { static let selo: CGFloat = 6, campo = 10, lista = 12, passagem = 20 }` (botões são `Capsule()`); `extension Font { static func larga(_ tamanho: CGFloat, _ peso: Font.Weight) -> Font }` (= `.system(size:weight:)` com `.width(.expanded)`); `func formatarBRL(_ valor: Decimal, centavos: Bool = true) -> String`; `extension Categoria { var cor: Color }` (Color Sets `cat-alimentacao` `#C2410C`, `cat-transporte` `#1D4ED8`, `cat-lazer` `#0F766E`, `cat-compras` `#6D28D9`, `cat-outros` `#64748B`, todos iguais nos dois temas; ver `docs/superpowers/specs/design-system/tokens.json`).

- [ ] **Passo 1: testes que falham**

```swift
@Test func brlComCentavos() { #expect(formatarBRL(1183) == "R$ 1.183,00") }
@Test func brlSemCentavos() { #expect(formatarBRL(1517.4, centavos: false) == "R$ 1.517") }
@Test func brlNegativo() { #expect(formatarBRL(-38) == "-R$ 38,00") }
@Test func brlIgnoraIdiomaDoAparelho() { /* Locale.current em en_US não muda o resultado */ #expect(formatarBRL(302.3) == "R$ 302,30") }
```

- [ ] **Passo 2:** Rodar `test`. Esperado: FAIL (`formatarBRL` não existe).
- [ ] **Passo 3:** Implementar `formatarBRL` com `Decimal.FormatStyle.Currency(code: "BRL", locale: Locale(identifier: "pt_BR"))` (o espaço depois de "R$" deve ser espaço comum; normalizar `\u{00A0}` para " "). Criar os Color Sets e `Tema.swift`.
- [ ] **Passo 4:** Rodar `test`. Esperado: PASS.
- [ ] **Passo 5:** Commit `feat(tema): cores claro/escuro e formatação BRL`.

### Tarefa 2: Cálculos da viagem (`ResumoViagem`)

**Files:**
- Create: `SoftexVamo/SoftexVamo/Tema/ResumoViagem.swift`
- Create: `SoftexVamo/SoftSpendTests/ResumoViagemTests.swift`

**Interfaces:**
- Consumes: `CicloSoftex` (`valor_total`, `diaria`, `titulo`, `dias: [DiaSoftex]?`), `DiaSoftex` (`data`, `gastos`), `GastosDia` (`valor`, `comprovanteUrl`, `comprovanteDataCriptografado`, `deletadoEm`).
- Produces:
  - `struct DiaResumo: Identifiable { let id: Date; let data: Date; let gasto: Decimal; let diaria: Decimal; var passou: Decimal { max(0, gasto - diaria) }; var estourou: Bool { gasto > diaria }; let ehHoje: Bool; let futuro: Bool; var proporcao: Double /* gasto/diaria, 0...1.25; 0 se diaria == 0 */ }`
  - `enum EstadoViagem: Equatable { case semViagem, antes(diasFaltando: Int), durante(dia: Int, de: Int), encerrada }`
  - `struct ResumoViagem { init(ciclo: CicloSoftex?, hoje: Date, calendario: Calendar = .current); let estado: EstadoViagem; let dias: [DiaResumo]; let diaria: Decimal; let total: Decimal; let gastoTotal: Decimal; let gastoHoje: Decimal; var livreHoje: Decimal { diaria - gastoHoje }; let semComprovante: [GastosDia]; let diasEstourados: Int }`
  - `func cicloDoInicio(_ ciclos: [CicloSoftex], hoje: Date, calendario: Calendar = .current) -> CicloSoftex?` — o que contém hoje (sobreposição: o de primeiro dia mais recente); senão o próximo futuro; senão o último encerrado; senão `nil`.
  - `enum ValoresViagem { static func diaria(total: Decimal, dias: Int) -> Decimal; static func total(diaria: Decimal, dias: Int) -> Decimal }` (arredondar diária a 2 casas, `.bankers` não: `.plain`).
  - `func codigoCidade(_ titulo: String) -> String` — 3 primeiras letras sem acento, maiúsculas, ignorando ", UF" ("Cuiabá, MT" → "CUI"; "São Paulo" → "SAO"; "" → "---"). (O spec deixa ao construtor; IATA real fica para depois.)
  - Gasto "sem comprovante" = `comprovanteUrl == nil && comprovanteDataCriptografado == nil`; gastos com `deletadoEm != nil` não contam em nada.

- [ ] **Passo 1: testes que falham** (dados: Cuiabá, 20/07–25/07/2026, total 2700, diária 450; hoje 23/07; gastos 21/07 = 488,00; 22/07 = 412,00; 23/07 = 43,10 com comprovante + 104,60 sem)

```swift
@Test func livreHoje() { #expect(r.livreHoje == 302.30); #expect(r.gastoHoje == 147.70) }
@Test func estadoDurante() { #expect(r.estado == .durante(dia: 4, de: 6)) }
@Test func barras() { #expect(r.dias.count == 6); #expect(r.dias[1].estourou && r.dias[1].passou == 38); #expect(r.dias[3].ehHoje); #expect(r.dias[4].futuro && r.dias[5].futuro); #expect(r.diasEstourados == 1) }
@Test func pendencias() { #expect(r.semComprovante.count == 1) }
@Test func antes() { #expect(ResumoViagem(ciclo: c, hoje: d("17/07")).estado == .antes(diasFaltando: 3)) }
@Test func encerrada() { #expect(ResumoViagem(ciclo: c, hoje: d("26/07")).estado == .encerrada) }
@Test func semViagem() { #expect(ResumoViagem(ciclo: nil, hoje: d("23/07")).estado == .semViagem); #expect(ResumoViagem(ciclo: .vazio, hoje: d("23/07")).estado == .semViagem) }   // Review Focus 1
@Test func diariaZero() { /* ciclo de 1 dia, diária 0, um gasto de 10 */ #expect(r0.dias[0].proporcao == 0); #expect(r0.livreHoje == -10) }        // Review Focus 2
@Test func gastoAs2350ContaNoDia() { /* gasto com data 22/07 23:50 vai para 22/07 */ }                                                             // Review Focus 4
@Test func cicloDoInicioEscolheOQueContemHoje() { #expect(cicloDoInicio([antigo, cuiaba, futuro], hoje: d("23/07")) === cuiaba); #expect(cicloDoInicio([antigo, futuro], hoje: d("23/07")) === futuro); #expect(cicloDoInicio([], hoje: d("23/07")) == nil) }
@Test func valores() { #expect(ValoresViagem.diaria(total: 2700, dias: 6) == 450); #expect(ValoresViagem.total(diaria: 450, dias: 6) == 2700); #expect(ValoresViagem.diaria(total: 1000, dias: 3) == 333.33) }
@Test func codigos() { #expect(codigoCidade("Cuiabá, MT") == "CUI"); #expect(codigoCidade("São Paulo") == "SAO"); #expect(codigoCidade("") == "---") }
```

- [ ] **Passo 2:** Rodar `test`. Esperado: FAIL.
- [ ] **Passo 3:** Implementar. Datas do ciclo vêm de `dias.map(\.data)` (min/max); o número de dias inclui o primeiro e o último. Comparações de dia sempre por `calendario.startOfDay`.
- [ ] **Passo 4:** Rodar `test`. Esperado: PASS.
- [ ] **Passo 5:** Commit `feat: ResumoViagem e escolha do ciclo do início`.

### Tarefa 3: Regras no `CiclosViewModel`

**Files:**
- Modify: `SoftexVamo/SoftexVamo/ViewModels/CiclosViewModel.swift:848-856` (bloqueio de saldo) e seleção do `atualCiclo` (linhas ~161, ~207, ~619)
- Create: `SoftexVamo/SoftSpendTests/CiclosViewModelTests.swift`

**Interfaces:**
- Consumes: `cicloDoInicio` (Tarefa 2).
- Produces: `var cicloInicio: CicloSoftex?` no `CiclosViewModel` (usa `cicloDoInicio(ciclosLocais, hoje: .now)`); `func abrirViagem(_ ciclo: CicloSoftex)` para Viagens, que carrega aquele ciclo sem mudar `cicloInicio`.

- [ ] **Passo 1: teste que falha** — com `ModelContainer` em memória (`ModelConfiguration(isStoredInMemoryOnly: true)`): editar um gasto de 43,10 para 600,00 num dia de diária 450 **não** lança erro e o dia fica com saldo -150.
- [ ] **Passo 2:** Rodar. Esperado: FAIL com "Saldo do dia insuficiente".
- [ ] **Passo 3:** Remover os dois `guard` de saldo do `editGasto` (mesmo dia e dia de destino). Trocar as escolhas de `atualCiclo = ciclosLocais[0]`/`primeiro` por `cicloInicio ?? CicloSoftex.vazio`.
- [ ] **Passo 4:** Rodar. Esperado: PASS (e os testes anteriores).
- [ ] **Passo 5:** Commit `fix: editar gasto pode passar da diária; início usa a viagem de hoje`.

### Tarefa 4: Componentes base

**Files:**
- Create em `SoftexVamo/SoftexVamo/Componentes/`: `CartaoPassagem.swift`, `BarrasPorDia.swift`, `LinhaGasto.swift`, `Selo.swift`, `AlertaPendencia.swift`, `Botoes.swift`, `IconeCategoria.swift`, `ValorMonetario.swift`

**Interfaces:**
- Consumes: `Tema`, `Espaco`, `Raio`, `formatarBRL`, `Categoria.cor` (Tarefa 1); `ResumoViagem`, `DiaResumo`, `codigoCidade` (Tarefa 2).
- Produces:
  - `CartaoPassagem(resumo: ResumoViagem, origem: String?, destino: String, periodo: String)` — cidade pequena sobre o código (SF Pro Expanded) nos dois lados, avião em `Tema.marca` entre eles, "20 a 25 de julho" e "4º de 6 dias", picote tracejado com recortes na cor `Tema.fundo`, sem borda, raio 20, bloco do estado (`.durante`: "Ainda dá para gastar hoje" + valor grande, ou "Passou R$ X hoje" em `Tema.estouro` se negativo; `.antes`: "Começa em N dias"; `.encerrada`: "Viagem encerrada") e `BarrasPorDia` quando `.durante`. Sem origem: mostra só "PARA".
  - `BarrasPorDia(dias: [DiaResumo], aoTocar: (DiaResumo) -> Void)` — hoje `Tema.marca`, estourado `Tema.estouro`, normal `Tema.barraDia`, futuro tracejado; rótulo com o dia do mês; acessibilidade por barra.
  - `LinhaGasto(gasto: GastosDia)` — `IconeCategoria`, título, linha de apoio "Categoria, HH:mm" em `Tema.textoFraco` ou "Falta a foto" em `Tema.alertaTexto`, valor com `.monospacedDigit()`. Tudo `.lineLimit(1)`.
  - `Selo(texto: String, estilo: .neutro | .alerta | .ok)`, `AlertaPendencia(quantidade: Int, aoAdicionar: () -> Void)` ("N gastos sem foto" + "Adicionar"; some se 0), `BotaoPrincipal(_ titulo: String, acao:)` (pílula `Tema.marcaBotao`), `BotaoSecundario(_ titulo: String, acao:)` (pílula `Tema.superficie`), `IconeCategoria(_ categoria: Categoria, tamanho: CGFloat = 30)`, `ValorMonetario(_ valor: Decimal, destaque: Bool = false)` (destaque = SF Pro Expanded 38pt bold, `.lineLimit(1).minimumScaleFactor(0.7)`).
- Cada componente com `#Preview` em claro e escuro (`.preferredColorScheme`).

- [ ] **Passo 1:** Implementar os componentes.
- [ ] **Passo 2:** Build. Esperado: `** BUILD SUCCEEDED **`.
- [ ] **Passo 3:** Montar uma tela temporária de vitrine (só em DEBUG) com todos os componentes e os dados da viagem de exemplo; capturar nos dois temas e comparar com as telas 6 e 12 do HTML (cores, picote, barras, selos sem quebra).
- [ ] **Passo 4:** Commit `feat: componentes base do redesenho`.

### Tarefa 5: Início e navegação (telas 3, 5, 6, 7)

**Files:**
- Create: `SoftexVamo/SoftexVamo/Scenes/InicioView.swift`, `SoftexVamo/SoftexVamo/SubViews/MenuAvatar.swift`
- Modify: `SoftexVamo/SoftexVamo/SubViews/MainView.swift` (sai a barra de abas; vira `NavigationStack` com `InicioView` na raiz), `SoftexVamo/SoftexVamo/SubViews/MenuView.swift` (substituído por `MenuAvatar`)

**Interfaces:**
- Consumes: componentes (Tarefa 4), `cicloInicio` (Tarefa 3).
- Produces: `enum Rota: Hashable { case novaViagem, viagens, viagem(UUID), todosGastos(filtro: FiltroGastos), detalheGasto(UUID), fecharViagem(UUID), perfil }` e `enum FiltroGastos: Hashable { case todos, semComprovante, categoria(Categoria) }` — usados pelas tarefas seguintes em `.navigationDestination(for: Rota.self)`. Até a tarefa dona existir, o destino mostra a tela antiga correspondente.

- [ ] **Passo 1:** `InicioView`: topo com logo (símbolo de bilhete em `Tema.marca` + "SoftSpend") e avatar; `CartaoPassagem`; `AlertaPendencia` → `.todosGastos(filtro: .semComprovante)`; título "Hoje" + "Todos os gastos" → `.todosGastos(filtro: .todos)`; lista dos gastos de hoje com `LinhaGasto`; rodapé fixo `BotaoPrincipal("Fotografar comprovante")` + `BotaoSecundario("＋")`. Estados: `.semViagem` → tela 3 com "Nova viagem"; `.antes` → tela 5 (dicas + "Editar viagem"); `.encerrada` → cartão "Viagem encerrada" + botão "Fechar viagem" → `.fecharViagem`.
- [ ] **Passo 2:** `MenuAvatar` (tela 7): nome/e-mail, Viagens, Todos os gastos, Fechar viagem e PDF, Perfil e ajustes, Sair. Sem "Ambiente API" fora de `#if DEBUG`; sem "Cartão corporativo" enquanto o Open Finance estiver desligado (manter a checagem que já existe no `MenuView`; sem resposta = desligado).
- [ ] **Passo 3:** Build e capturas das telas 3, 5, 6, 7 nos dois temas (mudar a data do simulador ou usar dados de exemplo em DEBUG para cada estado). Comparar com o HTML.
- [ ] **Passo 4:** Commit `feat: novo início e menu do avatar`.

### Tarefa 6: Lançar gasto (telas 8, 9, 10, 11)

**Files:**
- Create: `SoftexVamo/SoftexVamo/Scenes/ConsentimentoLeituraView.swift`, `SoftexVamo/SoftexVamo/Scenes/ConfirmarGastoView.swift`, `SoftexVamo/SoftexVamo/Scenes/DetalheGastoView.swift`
- Modify: `SoftexVamo/SoftexVamo/SubViews/AddNewGastoSheetView.swift` (a lógica de foto/leitura/salvar é reaproveitada; o visual sai), `SoftexVamo/SoftexVamo/SubViews/CameraPicker.swift`
- Create: `SoftexVamo/SoftSpendTests/ConsentimentoTests.swift`

**Interfaces:**
- Produces: `enum Consentimento { static var leituraAutomatica: Bool? { get set } }` em `UserDefaults` (chave `consentimentoLeituraAutomatica`; `nil` = ainda não perguntado); `func sobraDepois(de valor: Decimal, resumo: ResumoViagem) -> Decimal`.

- [ ] **Passo 1: testes que falham** — `Consentimento.leituraAutomatica` começa `nil`, guarda `true`/`false`; `sobraDepois(de: 43.10, resumo: r)` com gasto de hoje 104,60 e diária 450 == 302,30.
- [ ] **Passo 2:** Rodar. FAIL. **Passo 3:** Implementar. **Passo 4:** Rodar. PASS.
- [ ] **Passo 5:** Fluxo: "Fotografar comprovante" → se `Consentimento.leituraAutomatica == nil` mostra a tela 8 (texto do HTML: serviço Google Gemini, "Permitir leitura" / "Agora não, preencho eu") → câmera (tela 9, com "Galeria" e "Sem foto") → `ConfirmarGastoView` (tela 10: miniatura, valor grande, descrição, data e hora, categorias com as 5 de hoje, faixa "Hoje ainda sobra R$ X depois deste" em `Tema.ok`, ou em `Tema.alertaTexto` "Passa R$ X da diária" se negativo) → salvar com a mesma função de hoje. Sem consentimento: não chama a leitura; a foto vai anexada e os campos ficam em branco. "＋" do início abre `ConfirmarGastoView` sem foto.
- [ ] **Passo 6:** `DetalheGastoView` (tela 11): foto grande com ampliar, nome, valor, data, categoria, "✓ anexado" ou "Adicionar comprovante", "Editar" (reusa `ConfirmarGastoView` em modo edição → `editGasto`), "Apagar gasto" com confirmação.
- [ ] **Passo 7:** Build, capturas 8–11 nos dois temas. **Review Focus 5:** desligar a rede do Mac, lançar um gasto com foto e confirmar que aparece no início na hora.
- [ ] **Passo 8:** Commit `feat: lançar gasto com consentimento, confirmação e detalhe`.

### Tarefa 7: Todos os gastos e avisos de diária (telas 12, 13)

**Files:**
- Create: `SoftexVamo/SoftexVamo/Scenes/TodosGastosView.swift`, `SoftexVamo/SoftexVamo/Services/AvisoDiaria.swift`, `SoftexVamo/SoftSpendTests/AvisoDiariaTests.swift`
- Modify: `SoftexVamo/SoftexVamo/Scenes/CiclosListView.swift` (a lista longa sai dela; o arquivo fica só se ainda for usado)

**Interfaces:**
- Consumes: `FiltroGastos`, `Rota` (Tarefa 5), `ResumoViagem` (Tarefa 2).
- Produces: `enum AvisoDiaria { case oitentaPorCento(livre: Decimal), passou(valor: Decimal, data: Date); static func avaliar(gastoHoje: Decimal, diaria: Decimal, jaAvisados: Set<String>, hoje: Date) -> [AvisoDiaria]; var chave: String /* "80-yyyy-MM-dd" | "passou-yyyy-MM-dd" */ }`; `func agendar(_ aviso: AvisoDiaria, cidade: String) async`.

- [ ] **Passo 1: testes que falham** — gasto 360 de 450 → `[.oitentaPorCento(livre: 90)]`; o mesmo com a chave do dia já em `jaAvisados` → `[]`; gasto 488 → `.passou(valor: 38, …)` (e o de 80% se ainda não avisado); diária 0 → `[]`.
- [ ] **Passo 2:** FAIL. **Passo 3:** Implementar `avaliar` e `agendar` com `UNUserNotificationCenter` (textos da tela 13: "Você usou 80% da diária de hoje" / "Ainda dá para gastar R$ 90,00 em Cuiabá."; "Passou R$ 38,00 da diária" / "Segunda, 21/07. Os próximos dias continuam com R$ 450."). Chaves avisadas em `UserDefaults`. Chamar depois de salvar/editar gasto. Pedir permissão de notificação na primeira vez que um aviso for disparado. **Passo 4:** PASS.
- [ ] **Passo 5:** `TodosGastosView` (tela 12): busca por título, filtros Todos / Sem comprovante (com contagem) / Categoria; seções por dia com "total de diária" à direita (dia estourado em `Tema.estouro` com "+N"); toque → `.detalheGasto`.
- [ ] **Passo 6:** Build, capturas 12 nos dois temas e uma notificação de cada tipo (tela 13).
- [ ] **Passo 7:** Commit `feat: todos os gastos e avisos de diária`.

### Tarefa 8: Nova viagem e Viagens (telas 4, 16)

**Files:**
- Modify: `SoftexVamo/SoftexVamo/Scenes/NewCicloView.swift`, `SoftexVamo/SoftexVamo/Scenes/HistoricoView.swift` (vira Viagens; renomear o tipo para `ViagensView`)

**Interfaces:**
- Consumes: `ValoresViagem`, `codigoCidade` (Tarefa 2), `abrirViagem` (Tarefa 3).

- [ ] **Passo 1:** Nova viagem (tela 4): destino, ida, volta, "N dias, contando ida e volta", seletor Diária | Cartão corporativo ("em breve", desabilitado), campos ligados **Total da viagem** (principal, borda `Tema.marca`) ⇅ **Diária**: editar um recalcula o outro com `ValoresViagem`; mudar as datas recalcula a diária a partir do total. Salvar chama `createNewCiclo(startDate:endDate:totalValue:titulo:)` como hoje. Editar viagem antiga continua pelo total.
- [ ] **Passo 2:** Viagens (tela 16): "AGORA" (a de `cicloInicio`, com barra de progresso) e "ANTERIORES" (DE→PARA, cidade e período, total, link "PDF" → `.fecharViagem`); "＋" → `.novaViagem`. Tocar numa viagem → `abrirViagem` (não troca o início).
- [ ] **Passo 3:** Build, capturas 4 e 16 nos dois temas; criar uma viagem de 6 dias digitando só a diária 450 e conferir total 2.700 salvo.
- [ ] **Passo 4:** Commit `feat: nova viagem com total e diária ligados; tela de viagens`.

### Tarefa 9: Fechar viagem, PDF, perfil, entrar e criar conta (telas 1, 2, 14, 15, 17)

**Files:**
- Create: `SoftexVamo/SoftexVamo/Scenes/FecharViagemView.swift`
- Modify: `SoftexVamo/SoftexVamo/Scenes/PerfilView.swift`, `ConfiguracoesView.swift`, `LoginView.swift`, `RegisterView.swift`; geração do PDF onde ela é montada hoje (seguir `exportarCiclo` em `CiclosViewModel.swift:887` e `NetworkManager.exportarCiclo`) — só se o layout for montado no app; se o PDF vem pronto do servidor, **não mexer** (backend fora do escopo) e registrar na nota do projeto que o visual da tela 15 fica para uma tarefa de backend.

- [ ] **Passo 1:** Fechar viagem (tela 14): resumo (gasto de total, sobra, dias que passaram), checklist (com comprovante ✓ / sem comprovante ! + "Resolver"), formato PDF | CSV, "Gerar e compartilhar" usando `exportarCiclo(formato:)` e o `ActivityViewController` que já existe; gerar com pendências é permitido.
- [ ] **Passo 2:** Perfil e ajustes (tela 17): conta (nome, e-mail, senha), preferências (Avisos de diária, Leitura automática do comprovante ligada a `Consentimento.leituraAutomatica`, Tema: Automático/Claro/Escuro via `@AppStorage` + `.preferredColorScheme`), "Sair da conta". Saem as estatísticas em cartões; "Ambiente API" só em `#if DEBUG`.
- [ ] **Passo 3:** Entrar e Criar conta (telas 1 e 2): sem degradê; acentos corrigidos; o campo "Nome de usuário" sai da tela e o `username` enviado ao servidor vira a parte do e-mail antes do "@" (só letras, números, "." e "_"; o servidor já exige `username`, ver `UserDTO.swift`); botão com contraste AA.
- [ ] **Passo 4:** Build, capturas 1, 2, 14, 17 nos dois temas; gerar um PDF e um CSV de verdade e abrir.
- [ ] **Passo 5:** Commit `feat: fechar viagem, perfil e telas de acesso no visual novo`.

### Tarefa 10: Limpeza e conferência final

**Files:**
- Modify/Delete: `SoftexVamo/SoftexVamo/Extensions/Color+App.swift` (gradientes `appPurple`/`cardMain`), imagens `bagagem` e `maleta` e cores antigas (`roxoInicial`, `roxoFinal`, `purplePrimary`…) quando nada mais usar; `CardMainView.swift`, `CardCiclosView.swift`, `CardCategoryView.swift`, `MenuView.swift` se ficaram sem uso.

- [ ] **Passo 1:** `grep -rn "LinearGradient\|appPurple\|cardMain\|bagagem\|maleta\|sparkles\|roxoInicial\|roxoFinal\|\.monospaced()\|textCase(.uppercase)\| · " SoftexVamo/SoftexVamo` — Esperado: nada fora de código removido.
- [ ] **Passo 2:** Rodar `test` (todos PASS) e build.
- [ ] **Passo 3:** Capturar as telas 1–17 nos dois temas e colocar lado a lado com o HTML; corrigir diferenças.
- [ ] **Passo 4:** Commit `chore: remove o visual antigo`. Abrir PR da `redesenho-visual` para a `main` com as capturas. **Não** fazer merge: o usuário decide.

(A tela 18, conciliação do cartão, é só desenho e não entra neste plano.)
