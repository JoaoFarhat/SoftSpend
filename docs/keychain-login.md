# Login no Keychain: quando o iPhone recusa gravar ou ler

Spec do que o app faz quando o Keychain não entrega ou não aceita o access
token e o refresh token. Escrita sobre o PR #199 (que já separa `.achou`,
`.naoExiste` e `.indisponivel(OSStatus)` na leitura e grava com `SecItemUpdate`
antes de `SecItemAdd`) e sobre o #202 (`AuthService`). Implementar depois do
merge dos dois.

Os tokens ficam com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: com o
iPhone trancado, ler e gravar falham com `errSecInteractionNotAllowed`
(-25308). O servidor só tolera reuso de refresh token por
`REFRESH_REUSE_GRACE_SECONDS` (60 s); depois disso o reuso derruba **todas** as
sessões da pessoa. É isso que decide as regras abaixo.

## 1. Gravar

`KeychainManager.saveAccessToken`/`saveRefreshToken` hoje devolvem `Void` e só
logam. Passam a devolver `ResultadoGravacaoToken` (`nonisolated`, `Sendable`,
`Equatable`): `.gravou` ou `.recusou(OSStatus)`. `CofreDeTokens.gravarAccessToken`
e `gravarRefreshToken` devolvem o mesmo tipo (o `CofreEmMemoria` dos testes
sempre `.gravou`, e um cofre falso pode recusar sob comando).

### 1.1 Renovação (o caso grave)

O servidor já trocou o refresh token quando a resposta chega. Se a gravação
falhar (o iPhone trancou durante a ida e volta da rede), o Keychain ainda tem
o refresh **antigo**: reenviá-lo depois de 60 s é reuso.

Regras, no `TokenRefresher`:

1. Grava o refresh primeiro, depois o access (como hoje). Se o refresh não
   gravou, **não** grava o access (o par antigo no Keychain continua
   consistente entre si).
2. Se qualquer gravação foi recusada, o par novo fica numa **sessão em memória**
   (`ParDeTokensPendente`: refresh, access, ainda não gravados) guardada no
   `NetworkManager`. A renovação **dá certo** — o pedido segue com o token
   novo, sem erro e sem logout.
3. Enquanto houver par pendente, ele vale como "o cofre": leitura de access e
   refresh (`buscarAccessToken`/`buscarRefreshToken`, a comparação de sessão do
   `execute` e do `TokenRefresher`) olha o pendente antes do Keychain. O
   Keychain nunca é consultado para um token que o app sabe estar velho.
4. Nova tentativa de gravar o par pendente: no começo de cada pedido
   (`makeRequest`, só quando há pendente — custo zero no caminho normal), ao
   voltar para o primeiro plano e antes de uma nova renovação. Gravou os dois:
   o pendente some. Gravou só um: continua pendente (a ordem refresh → access
   vale na retomada).
5. O pendente é descartado em logout, troca de conta e `deleteAccount`, e é só
   de memória: nunca vai para disco, log ou `UserDefaults`.
6. Se o app morrer antes de gravar, resta o refresh antigo no Keychain. Com
   menos de 60 s é a janela de tolerância do servidor; depois, reuso e logout
   em todos os aparelhos. Risco aceito: é a mesma janela que já existia entre
   as duas gravações, agora só com o iPhone trancado no pior momento. O log
   registra `Par de tokens renovado ficou só em memória` (status, sem token).

Falha de gravação **permanente** (status que não volta com o desbloqueio, ver
§2.1) na renovação: mesmo tratamento do pendente, mais o aviso da §3 — o app
funciona nesta sessão, mas a pessoa precisa saber que o login não está sendo
guardado.

### 1.2 Entrar e cadastrar (`saveUser`)

O iPhone está destrancado (a pessoa acabou de digitar a senha), então uma
recusa aqui é anormal e **fecha o acesso** (fail-closed), ao contrário da §1.1:

1. Grava refresh, depois access, **antes** de marcar `isAuthenticated = true` e
   de guardar `user_data`.
2. Alguma gravação recusada: não entra. `errorMessage` = "Não foi possível
   guardar seu login neste iPhone. Reinicie o iPhone e tente de novo." (o
   código do status só no log). Apaga o que gravou (`deleteAllTokens`) e revoga
   a sessão criada no servidor em segundo plano (`/auth/logout` com o refresh
   token recebido, sem esperar resposta).
3. Cadastro: a conta já foi criada. A mensagem é "Sua conta foi criada, mas não
   foi possível guardar o login neste iPhone. Reinicie o iPhone e entre com seu
   e-mail e senha."

### 1.3 Apagar (`deleteAllTokens`, no logout)

`SecItemDelete` com o iPhone trancado pode falhar. O logout local continua
imediato (a UI não espera): `user_data` sai, `isAuthenticated = false`. Sobra
token no Keychain? Sem `user_data` o `checkAuthentication` não autentica, e o
próximo login sobrescreve por `SecItemUpdate`. Só loga o status. A revogação no
servidor, quando o refresh não pôde ser lido (`.indisponivel`), não é feita:
a sessão expira sozinha em 7 dias. Aceito.

## 2. Ler

### 2.1 O que é "espere o desbloqueio"

Hoje todo `OSStatus` fora de `errSecItemNotFound` vira `.indisponivel` e o
app responde "Desbloqueie o iPhone". Um erro que o desbloqueio não resolve
prenderia a pessoa nessa mensagem para sempre. Passa a valer:

| Status | Resultado |
| --- | --- |
| `errSecSuccess` | `.achou` / `.naoExiste` (bytes que não viram texto) |
| `errSecItemNotFound` | `.naoExiste` |
| `errSecInteractionNotAllowed` (-25308), `errSecNotAvailable` (-25291, antes do primeiro desbloqueio depois de ligar) | `.indisponivel(status)` → espera o desbloqueio |
| qualquer outro | `.ilegivel(status)` → não volta com o desbloqueio |

`ResultadoLeituraToken` ganha `.ilegivel(OSStatus)`. A função pura
`statusEsperaDesbloqueio(_:) -> Bool` fica ao lado do enum e tem teste de
tabela.

Mesmo `errSecInteractionNotAllowed` deixa de valer como espera quando o
iPhone claramente **não** está trancado: o app está ativo
(`scenePhase == .active`) e `UIApplication.shared.isProtectedDataAvailable`
é `true`. Isso é decidido por uma closure injetável
(`iPhoneProvavelmenteTrancado: @Sendable () -> Bool`, padrão: dados protegidos
indisponíveis **ou** app fora do primeiro plano) que o `CofreDeTokensKeychain`
recebe no `init`; falsa, o status vira `.ilegivel`. Assim o app não fica em
"Desbloqueie o iPhone" com o iPhone aberto na mão.

### 2.2 O que cada resultado faz

- `.indisponivel`: como no #199 — o pedido não sai, `APIError.chaveIndisponivel`
  ("Desbloqueie o iPhone para continuar."), sem rede, sem 401, sem logout, o
  sync espera 60 s sem contar tentativa.
- `.naoExiste`: como hoje (sem token → 401 → refresh → logout).
- `.ilegivel`: o login deste aparelho não é recuperável por espera. O pedido
  não sai e vira `APIError.loginIlegivel` ("Não foi possível ler seu login
  neste iPhone. Entre de novo."). O app **não apaga nada às cegas**: quem trata
  o erro (o mesmo ponto que hoje trata `.authentication`) chama o logout local
  sem revogar no servidor, e a tela de entrada aparece com essa mensagem. Dados
  offline ficam (isolamento por `userId`) e sobem quando a pessoa entrar de
  novo. Entrar de novo grava por `SecItemUpdate`/`SecItemAdd`; se a gravação
  também for recusada, vale a §1.2.
- No `TokenRefresher`, `.ilegivel` na conferência de sessão depois da rede
  (`conferirMesmaSessao`) tem o mesmo efeito de `.indisponivel`: lança, não
  grava, não desloga; o erro sobe e o próximo pedido cai no ramo acima.
- `deveDeslogarAposFalhaDeRefresh(.chaveIndisponivel)` continua `false`;
  `deveDeslogarAposFalhaDeRefresh(.loginIlegivel)` é `false` também (o logout
  vem do ponto acima, uma vez só, não de cada pedido em voo).
- `AuthService.checkAuthentication` segue só lendo. `.ilegivel` na abertura
  não autentica e não apaga; a tela de entrada aparece, e o `onChange` da cena
  ativa repete a leitura (iPhone que acabou de destrancar entra sem digitar).

## 3. O que a pessoa vê

Duas mensagens, sem jargão e sem código de erro na tela:

- Espera: "Desbloqueie o iPhone para continuar." (já existe).
- Falha permanente de leitura ou gravação: "Não foi possível guardar/ler seu
  login neste iPhone. Reinicie o iPhone e entre de novo." O status vai só para
  o log (`privacy: .public`; é um número, não um token).

Sem faixa nova no `MainView`: a falha de gravação da §1.1 aparece como a
mensagem permanente só na próxima vez que o login for pedido (entrar de novo).

## 4. Testes (todos com `CofreDeTokensFalso`, sem Keychain)

`SoftSpendTests/FalhaDoKeychainLoginTests.swift`:

1. Tabela de `statusEsperaDesbloqueio` (-25308 e -25291 esperam; -34018,
   -26275, -50, -108, 0 não).
2. Leitura com iPhone não trancado + -25308 vira `.ilegivel`.
3. Renovação com gravação do refresh recusada: o pedido volta 200 com o token
   novo; o cofre não recebe o access; o pedido seguinte usa o token novo da
   memória e **nenhum** pedido de renovação reenvia o refresh antigo.
4. Pendente: a primeira tentativa de gravar volta recusada, a segunda grava os
   dois (nesta ordem) e o pendente some.
5. Logout, troca de conta e `deleteAccount` descartam o pendente.
6. `.ilegivel` no access: o pedido não sai, vem `loginIlegivel`, logout local
   uma vez só (vários pedidos em voo não chamam o logout várias vezes).
7. `saveUser` com gravação recusada: `isAuthenticated` continua falso,
   `user_data` não é gravado, `deleteAllTokens` e a revogação rodam, a mensagem
   é a da §1.2. Idem para o cadastro, com a mensagem própria.
8. O `execute` atual (`NetworkManagerExecuteTests`, `SessaoTrocadaRedeTests`,
   `TokenComIPhoneTrancadoTests`) segue passando sem mudança.

## 5. Não faz parte

- Guardar tokens em outro lugar (arquivo, `UserDefaults`) por conta de uma
  recusa do Keychain: nunca.
- Trocar a acessibilidade para `AfterFirstUnlock`: decisão de segurança que
  fica com o usuário (o app foi escrito com `WhenUnlocked` de propósito).
- Mudar o servidor.
