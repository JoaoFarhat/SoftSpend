# Assinatura, parte 2: Apple no servidor (AS2) e StoreKit no app (I1 e I2)

Especificação, **sem código**, escrita pelo Claude em 13/11/2026. Continua `docs/publicacao.md` §1.4 e §1.5 e a AS1 (PR #59: tabelas `assinaturas` e `apple_notificacoes`, `calcular_acesso`, `GET /api/assinatura`, interruptor `BILLING_ENFORCEMENT`, `exigir_assinatura`).

> **Este documento vale mais que `publicacao.md` §1.4–1.5 onde os dois divergem.** As diferenças: o teste grátis é de **14 dias** (não 7); **exportar** e **importar fatura** também bloqueiam (decisões U1, U2 e F1 da nota); preço R$ 14,90 por mês e R$ 144,90 por ano.
>
> Os nomes de tabela, coluna e função da AS1 abaixo seguem o texto da tarefa do PR #59. **Conferir com o que foi para a `main`** antes de implementar; se algo divergir, vale o código mergeado e o Devin anota a diferença no PR.

## 1. Princípios

1. **O servidor é a única autoridade sobre o acesso.** O app compra, repassa o comprovante assinado pela Apple (JWS) e pergunta ao servidor. O app **nunca** destrava nada pelo estado local do StoreKit (`Transaction.currentEntitlements`): duas contas do SoftSpend no mesmo Apple ID dividiriam a mesma compra.
2. **Um único caminho de cálculo:** a função `reconciliar` (§2.5). `/transacoes`, o webhook e a conciliação diária só a chamam; nenhum deles decide o estado sozinho.
3. **Dado do usuário nunca vira refém.** Só bloqueiam: ciclo novo, ler comprovante com IA, importar fatura e exportar. Ver, lançar à mão, sincronizar, sair e excluir a conta nunca bloqueiam.
4. **O app offline não perde nada por causa da cobrança** (§3.4).
5. Segredos da Apple só no `.env` da EC2, nunca no repositório nem em log.

## 2. Servidor (AS2)

Só depois do merge da AS1 (PR #59 e a migration `f2c4e6a8b0d2` + a da AS1 nos dois bancos).

### 2.1 Biblioteca e verificação do JWS

- **Biblioteca oficial:** `app-store-server-library` (PyPI; repositório `apple/app-store-server-library-python`). O Devin confere versão, manutenção e licença antes de fixar a versão em `requirements.txt` e confere no README o que a **produção** exige. O que se espera, e o Devin confirma:
  - `SignedDataVerifier(root_certificates, enable_online_checks, environment, bundle_id, app_apple_id)`; em **Production** o `app_apple_id` (número do app na App Store Connect) é obrigatório e as verificações online ficam ligadas;
  - `AppStoreServerAPIClient(signing_key, key_id, issuer_id, bundle_id, environment)`.
- **Certificados raiz da Apple** (Apple Root CA G3 e afins): baixados uma vez de `apple.com/certificateauthority`, guardados no repositório em `Python/certificados_apple/` (são públicos) e lidos do disco. Nunca baixados em tempo de requisição.
- **Um verificador por ambiente.** O JWS traz o campo `environment` (`Production` ou `Sandbox`) no payload. Como é preciso decodificar para ler o campo, a ordem é: tentar o verificador de **Production**; se a cadeia de certificados falhar com erro de ambiente, tentar o de **Sandbox**; se os dois falharem, recusar. O ambiente que validou é gravado em `assinaturas.ambiente`.
- **Sandbox aceito em produção** (decisão de `publicacao.md` §1.4: a revisão da Apple compra no Sandbox mesmo com o app em produção). Consequências, que valem estar escritas:
  - a assinatura Sandbox tem `ambiente = Sandbox` e passa a valer como qualquer outra;
  - o tempo no Sandbox é acelerado (uma renovação mensal dura minutos), então ela expira e renova sozinha em minutos; **o teste de expiração é feito aqui**;
  - um testador do TestFlight assina de graça. Aceito como risco, porque a pessoa precisa ter o app do TestFlight; mitigação: o painel (futuro) separa por `ambiente`, e a conciliação diária consulta a API **do mesmo ambiente** da linha (`api.storekit.itunes.apple.com` para Production, `api.storekit-sandbox.itunes.apple.com` para Sandbox).
- **Injeção para teste:** o verificador e o cliente da App Store Server API ficam atrás de duas funções fábrica (`obter_verificador(ambiente)`, `obter_cliente_apple(ambiente)`) que os testes substituem por fakes com fixtures. **Nenhum teste chama a Apple nem precisa de certificado real.**

### 2.2 Variáveis de ambiente novas (na EC2, nunca no repositório)

| Variável | Descrição |
| --- | --- |
| `APPLE_BUNDLE_ID` | `br.com.softspend.app` |
| `APPLE_APP_ID` | Número do app na App Store Connect (obrigatório em Production) |
| `APPLE_ISSUER_ID` | Issuer ID da chave de In-App Purchase |
| `APPLE_KEY_ID` | Key ID da mesma chave |
| `APPLE_PRIVATE_KEY` | Conteúdo do `.p8` (ou `APPLE_PRIVATE_KEY_PATH`, arquivo fora do repositório com permissão 600) |
| `BILLING_ENFORCEMENT` | já existe (AS1): `off` por padrão |
| `APPLE_ACEITA_SANDBOX` | `true` por padrão; `false` recusa Sandbox (para depois que a loja estiver estável) |

Sem as variáveis `APPLE_*`: `/transacoes` e o job respondem `503` e o webhook também; `GET /api/assinatura` continua funcionando (AS1). O `/health` não depende delas.

### 2.3 Rotas

**Ligação com a AS1.** `assinaturas.original_transaction_id` precisa ser **único entre usuários** (o Devin confere se a AS1 criou o índice único; se não, esta tarefa acrescenta na migration da AS2).

**`POST /api/assinatura/transacoes`** (autenticada; sujeita a rate limit como as outras)
- Corpo: `{"jws": "<JWS da transação>"}` (a `jwsRepresentation` do StoreKit 2).
- Passos: verificar o JWS (§2.1) → conferir `bundleId` → **conferir `appAccountToken` do JWS == `assinaturas.app_account_token` do usuário logado** → chamar `reconciliar` (§2.5) → responder o mesmo corpo do `GET /api/assinatura`.
- Erros:
  - JWS inválido, de outro app ou de outro ambiente recusado: `400` ("Comprovante da compra inválido.");
  - `appAccountToken` diferente do usuário: `409` ("Esta assinatura pertence a outra conta do SoftSpend.");
  - `original_transaction_id` já ligado a **outro** usuário: `409`, mesma mensagem. Isso impede uma conta de "roubar" a compra de outra reenviando o JWS dela;
  - Apple indisponível ao consultar a API: `503` ("Tente de novo em instantes."); **nada é gravado pela metade**.
- **JWS sem `appAccountToken`** (compra por código de oferta fora do app, por exemplo): como o app compra sempre com o token, uma transação sem ele só chega por **Restaurar compras** de quem comprou antes do token existir ou por canal externo. Decisão: **aceitar só se o `original_transaction_id` ainda não estiver ligado a ninguém**, ligar ao usuário logado e gravar o token dele; se já estiver ligado a outro usuário, `409`. Registrar no log (sem dados da compra).
- Idempotente: reenviar a mesma transação repete o resultado, sem duplicar linha.
- Só **assinaturas** (`type = Auto-Renewable Subscription`) e só os dois produtos do §5; outro `productId` recebe `400`.

**`POST /api/webhooks/apple`** (Server Notifications V2)
- **Sempre registrada** (não depende de `OPEN_FINANCE_ENABLED`, de login nem de `BILLING_ENFORCEMENT`); a única autenticação é a assinatura do JWS (`signedPayload`) verificada com a cadeia da Apple.
- Corpo: `{"signedPayload": "..."}`.
- Fluxo: verificar → se **inválido: `400` e nada gravado** → se `notificationUUID` já existe em `apple_notificacoes`: `200`, nada a fazer → gravar a notificação (`tipo`, `subtipo`, `original_transaction_id`, `recebida_em`) → achar a linha por `original_transaction_id` (ou, se ainda não ligada, pelo `appAccountToken` da transação) → `reconciliar`.
- **Transação desconhecida** (conta excluída, compra ainda não enviada pelo app): grava a notificação, responde **`200`**. Responder erro faria a Apple repetir por dias.
- **Fora de ordem ou antiga:** a notificação serve de **gatilho**, não de verdade. `reconciliar` relê o estado atual na App Store Server API (`Get All Subscription Statuses`) em vez de aplicar o que a notificação diz; assim uma `DID_RENEW` atrasada não desfaz um `EXPIRED` mais novo. Se a API estiver fora do ar, usa o `signedDate` da notificação e **só aplica se for mais novo** que `assinaturas.atualizado_em`.
- Falha interna ao reconciliar: `500` (a Apple repete, e o `notificationUUID` só fica gravado **depois** do sucesso, para a repetição não ser tratada como duplicata).
- `TEST` (notificação de teste da App Store Connect): `200`, sem reconciliar.

### 2.4 Tabela: tipo de notificação → estado esperado

Os nomes vêm dos enums `NotificationTypeV2` e `Subtype` da biblioteca; o Devin confere cada um contra a versão fixada. **A tabela mostra o resultado esperado, para o teste; o estado gravado sempre sai de `reconciliar` com a transação e o `renewalInfo` do momento**, não do tipo.

| `notificationType` | `subtype` | Estado esperado | Observação |
| --- | --- | --- | --- |
| `SUBSCRIBED` | `INITIAL_BUY` | `trial` se a oferta introdutória grátis foi usada, senão `active` | Primeira compra |
| `SUBSCRIBED` | `RESUBSCRIBE` | `active` | Voltou depois de expirar |
| `DID_RENEW` | (vazio) ou `BILLING_RECOVERY` | `active` | Renovou; `BILLING_RECOVERY` = pagamento recuperado |
| `DID_CHANGE_RENEWAL_STATUS` | `AUTO_RENEW_DISABLED` | segue `active`/`trial` | Só marca `renovacao_automatica = false` |
| `DID_CHANGE_RENEWAL_STATUS` | `AUTO_RENEW_ENABLED` | segue | `renovacao_automatica = true` |
| `DID_CHANGE_RENEWAL_PREF` | `UPGRADE`/`DOWNGRADE` | segue | Troca de plano; atualiza `produto` |
| `DID_FAIL_TO_RENEW` | `GRACE_PERIOD` | `grace` | Acesso até `carencia_ate` |
| `DID_FAIL_TO_RENEW` | (vazio) | `billing_retry` | Sem acesso |
| `GRACE_PERIOD_EXPIRED` | | `billing_retry` | Carência acabou, Apple ainda tenta cobrar |
| `EXPIRED` | `VOLUNTARY`, `BILLING_RETRY`, `PRICE_INCREASE`, `PRODUCT_NOT_FOR_SALE` | `expired` | |
| `REFUND` | | `revoked` | Sem acesso |
| `REVOKE` | | `revoked` | Compartilhamento em família retirado |
| `REFUND_REVERSED` | | volta ao estado da API | Reembolso desfeito |
| `REFUND_DECLINED` | | sem mudança | Só registra |
| `OFFER_REDEEMED` | | por `reconciliar` | Código de oferta |
| `PRICE_INCREASE` | `PENDING`/`ACCEPTED` | sem mudança de acesso | Só registra |
| `RENEWAL_EXTENDED` / `RENEWAL_EXTENSION` | | por `reconciliar` | Apple estendeu a data |
| `CONSUMPTION_REQUEST`, `ONE_TIME_CHARGE`, `EXTERNAL_PURCHASE_TOKEN` | | sem mudança | Só registra (não usamos) |
| `TEST` | | sem mudança | Só confirma que o endereço responde |

Códigos de `Get All Subscription Statuses` (campo `status`) que `reconciliar` traduz: `1` ativa → `active` (ou `trial`, §2.6); `2` expirada → `expired`; `3` em nova tentativa de cobrança → `billing_retry`; `4` em carência → `grace` (com `carencia_ate` = `gracePeriodExpiresDate` do `renewalInfo`); `5` revogada → `revoked`.

### 2.5 `reconciliar` e o cálculo do acesso

`services/assinatura_service.reconciliar(db, assinatura, transacao, renewal_info, agora)`:
- grava `original_transaction_id`, `produto`, `ambiente`, `expira_em` (`expiresDate`), `carencia_ate`, `renovacao_automatica` (`autoRenewStatus`), `atualizado_em` e o **status**, traduzido do estado da Apple (§2.4);
- o **acesso** continua sendo calculado por `calcular_acesso(assinatura, agora)` da AS1 (`trial`, `active` e `grace` até `carencia_ate` dão acesso; o resto, não). **Um `active` com `expira_em` no passado e sem notificação ainda vale `expired`**: o acesso nunca depende de a notificação ter chegado;
- função pura sobre os dados que recebe; quem consulta a Apple é a camada de cima. Teste de tabela cobrindo cada linha da §2.4 e as bordas de data (mesmo segundo do vencimento, carência vencida).

### 2.6 O teste grátis é a oferta introdutória da Apple, de 14 dias

- **Não existe contagem de 14 dias no servidor.** O teste é uma **oferta introdutória "grátis, 14 dias"** configurada nos dois produtos na App Store Connect. A Apple decide a elegibilidade (uma vez por grupo de assinatura e por Apple ID).
- `trial` = transação com `offerType = 1` (introdutória) e `offerDiscountType = FREE_TRIAL` dentro do período. O servidor deriva isso dos campos da transação; **não inventa trial nenhum**.
- **Consequência para o produto (decisão a confirmar, §6):** quando o bloqueio for ligado, uma conta nova começa em `none` e **precisa iniciar o teste da Apple** (passando pela tela de planos, com cartão/Apple ID) para criar a primeira viagem. Não há "14 dias sem cadastrar nada". Isso é o jeito padrão da loja.
- **Contas antigas:** quando `BILLING_ENFORCEMENT` virar `on`, todo usuário existente também vira `none`. Pergunta ao usuário na §6 (carência para contas antigas).

### 2.7 Conciliação diária

- Um **timer do systemd** (`softspend-assinaturas.timer` + `.service`, mesmo molde do backup em `deploy/ec2/`), uma vez por dia, que roda um comando do próprio app (`python -m services.assinatura_job`), sem rota pública e sem depender do uvicorn.
- Para cada linha `assinaturas` com `original_transaction_id` e status diferente de `expired`/`revoked`, **ou** que expirou nos últimos 7 dias: consulta `Get All Subscription Statuses` **no ambiente da linha** e chama `reconciliar`. Serve de rede de segurança para webhook perdido.
- Falha de uma linha não derruba as outras; o resumo vai ao log (só contagens, sem ids nem valores). Limite de vazão simples (pausa curta entre linhas) para não estourar a cota da Apple.
- Instalado pelo `deploy/ec2/setup.sh`, **desligado** até existirem as variáveis `APPLE_*` (como o timer do backup).

### 2.8 Tarefas AS2 e testes

Os testes usam o verificador falso (§2.1):
1. `reconciliar`: uma linha por linha da §2.4; borda de data; `active` vencido sem notificação vira `expired`.
2. `/transacoes`: JWS válido liga a assinatura e devolve o estado; repetir não duplica; JWS inválido `400`; token de outro usuário `409`; transação já de outro usuário `409`; sem token e livre liga ao usuário; sem token e de outro `409`; `productId` desconhecido `400`; Apple fora do ar `503` sem gravar nada.
3. Webhook: assinatura inválida `400` e nada gravado; `notificationUUID` repetido `200` sem efeito; transação desconhecida `200` e notificação registrada; notificação antiga não desfaz estado mais novo; `TEST` `200`; falha interna `500` e UUID **não** gravado.
4. Webhook e `/transacoes` registrados com `OPEN_FINANCE_ENABLED=false` e com `BILLING_ENFORCEMENT=off`.
5. Job diário: reconcilia só as linhas certas; uma falha não impede as outras; usa a API do ambiente da linha.
6. **Replay de `POST /ciclos` (correção do servidor):** com `BILLING_ENFORCEMENT=on`, usuário **sem acesso** e `client_id` que **já existe** para ele: `POST /ciclos` devolve **200 com o ciclo existente** (sem criar nada). Com `client_id` novo: `403 subscription_required`. Isso muda a AS1: **a checagem de assinatura passa a vir depois da busca por `client_id`** (em vez de ser dependência antes da rota). Motivo no §3.3.
7. `pytest -q` inteiro continua passando.

## 3. App (I1 e I2)

### 3.1 Formato do 403

O servidor responde `403` pela `http_exception_handler` → `build_error_response`, que **reescreve o corpo**: o app recebe `{"error": "subscription_required", "request_id": "..."}`, **não** `{"detail": ...}` (a tarefa da AS1 fala em `detail`; vale o que o handler faz, e o Devin da AS1/AS2 confere com um teste do corpo real).

No app, `NetworkManager` já transforma isso em `APIError.serverError(message: "subscription_required", requestId:, statusCode: 403)`. A regra:
- **Detecção:** `statusCode == 403 && message == "subscription_required"` no erro **tipado**, antes de qualquer conversão para `localizedDescription` (que é o que `syncError` guarda hoje). Um helper `APIError.assinaturaNecessaria` (computed `Bool`) concentra isso.
- **Esse 403 nunca dispara renovação de token nem logout.** Hoje só o `401` faz isso (`NetworkManager.execute`); continua assim, com um teste.

### 3.2 I1: `LojaAssinatura` (StoreKit 2)

Depende do PR do iOS 17 (#58) e da tarefa "preparar o projeto para a loja" (bundle id `br.com.softspend.app`, mesmo `project.pbxproj`).

**Identificadores (permanentes, escolhidos aqui; não dá para trocar depois de criados):**
- Grupo de assinatura: **SoftSpend** (referência `softspend_assinatura`).
- Produtos: `br.com.softspend.app.assinatura.mensal` (R$ 14,90) e `br.com.softspend.app.assinatura.anual` (R$ 144,90). Os dois no mesmo grupo (a pessoa troca de plano, não assina os dois).

**`Services/LojaAssinatura.swift`** é o **único** arquivo que importa StoreKit. Por trás de um protocolo `LojaAssinaturaProtocolo` (produtos, comprar, restaurar, ouvir atualizações), para o resto do app e os testes de CI usarem uma loja falsa; compra real só no Mac e no TestFlight.
- **Carregar produtos** (`Product.products(for:)`); falha de rede mostra "Não foi possível carregar os planos" com "Tentar de novo".
- **Comprar:** `product.purchase(options: [.appAccountToken(token)])`, com o `app_account_token` do `GET /api/assinatura`. Tratar os três resultados: `.success` (verificada) → manda a `jwsRepresentation` para `POST /api/assinatura/transacoes` → **só depois do servidor aceitar** chama `transaction.finish()`; `.pending` (Pergunte antes de comprar, controle parental) → mensagem "Compra aguardando aprovação" e nada trava; `.userCancelled` → volta à tela sem mensagem de erro. Resultado `.unverified` → trata como falha, sem destravar.
- **Se o servidor falhar** depois de uma compra aprovada pela Apple: **não** chamar `finish()`; a transação fica pendente no StoreKit e é reenviada na próxima abertura (por `Transaction.updates`/`unfinished`). A tela diz "Compra recebida; confirmando com o servidor…" e **nunca cobra duas vezes** (a Apple já cobrou; só falta o aviso ao servidor).
- **`Transaction.updates`** ouvido **desde a abertura do app** (na cena raiz), inclusive renovações em segundo plano e compras de outro aparelho. Transação chegando **sem usuário logado** fica sem `finish()` até haver login (então reenvia, usando o token da conta logada **só se** o `appAccountToken` da transação bater; se não bater, o servidor responde `409` e o app não finaliza nem repete em loop).
- **Restaurar compras:** botão obrigatório. Chama `AppStore.sync()`, depois reenvia ao servidor cada `Transaction.currentEntitlements` (e as `unfinished`) para `/transacoes`. Mostra o resultado ("Assinatura restaurada" / "Não encontramos assinatura para esta conta").
- **Depois de uma compra ou restauração:** `GET /api/assinatura` de novo e `SyncManager.sync(forcar: true)` (para subir o que ficou bloqueado, §3.4).
- **Desbloqueio só por `tem_acesso` do servidor** (princípio 1). O estado do StoreKit serve para mostrar o plano e o botão "Gerenciar assinatura", nunca para liberar recurso.

**Tela de planos** (design system do app; o que a regra 3.1.2 da Apple exige):
- nome do plano, **duração** ("1 mês" / "1 ano") e **preço vindo de `Product.displayPrice`** (nunca escrito no código);
- **texto do teste:** "14 dias grátis" **só se** a pessoa é elegível (`product.subscription?.isEligibleForIntroOffer`), com a duração tirada de `introductoryOffer` (não escrita no código), e a frase "Depois, R$ … por mês/ano" com o preço real;
- texto de **renovação automática** ("A assinatura renova sozinha, a menos que seja cancelada pelo menos 24 horas antes do fim do período; cancele em Ajustes › Apple ID › Assinaturas");
- links para **Termos de Uso** e **Política de Privacidade** (dependência: ainda **não estão hospedados**; os rascunhos estão em `docs/legal/` no PR #50, que não foi mesclado. A tela não pode ir para a loja sem essas duas URLs);
- botões **Restaurar compras** e **Gerenciar assinatura** (`AppStore.showManageSubscriptions` / `manageSubscriptionsSheet`);
- a lista do que o assinante recebe ("Viagens novas, leitura de comprovante e de fatura por IA, relatório em PDF e CSV");
- estado "Você já assina" com o plano, a data de renovação/expiração e, se `grace`/`billing_retry`, a faixa "Seu pagamento falhou. Atualize a forma de pagamento".

**Entradas** na tela de planos: (a) o cartão **"Assinatura" em Perfil**, **sempre disponível**, **mesmo com `BILLING_ENFORCEMENT=off`** (a revisão da Apple precisa alcançar a compra); (b) os bloqueios da §3.5; (c) a faixa de pagamento falhando.

**Exclusão da conta:** o aviso "Excluir a conta não cancela a assinatura da App Store" (já numa tarefa do Devin) leva um botão "Gerenciar assinatura".

### 3.3 Bug a fechar: reenvio de `POST /ciclos` contra o bloqueio

`exigir_assinatura` hoje (AS1) é dependência da rota e roda **antes** da busca por `client_id`. Dois problemas reais, por isso o §2.8 item 6 muda o servidor:
1. Uma viagem **criada com assinatura ativa** cuja resposta se perdeu, reenviada depois do vencimento, receberia 403 **mesmo existindo no servidor**.
2. A **exclusão (T7)**: apagar uma viagem sem `backendId` mas com `podeTerSidoCriadoNoServidor` (falha ou `syncError`) manda um `POST` com o mesmo `client_id` só para obter o id (`recuperarBackendId`). Com o 403 isso virava `.falhou` → backoff, e a exclusão nunca terminava.

Com o servidor corrigido, **403 significa "com certeza não está no servidor"** (o `client_id` existente passaria). Por isso, no app, o marcador de assinatura **sai** de `podeTerSidoCriadoNoServidor` (como a falha final do T4) e `classificar` devolve `.naoExiste` para ele; a viagem some só do aparelho, sem nenhuma requisição a mais.

### 3.4 I2a: `SyncActor` e o 403 (não depende do StoreKit; pode rodar em paralelo com a AS2)

Só `SoftexVamo/` (`SyncManager.swift`, `APIError`, `EstadoEnvio`, testes). **Sem `@Model` novo, sem V2** (reusa `syncStatus` e `syncError`).

**Comportamento.** No `catch` do `POST` de ciclo de `syncCiclos`, **antes** do `marcarFalha`:
- se `error` é `assinaturaNecessaria` (§3.1): chamar um novo `marcarAguardandoAssinatura(atual)`: `syncStatus = .pending`, `tentativas` **inalterado**, `proximaTentativaEm = nil`, `syncError = SyncActor.erroAssinaturaNecessaria` (nova constante, texto "Assinatura necessária para enviar esta viagem"), **sem** `mudouDuranteEnvio` (não é para rodar nova passada), **sem logout, sem descarte**;
- qualquer outro erro (inclusive um `403` com **outra** mensagem) segue para `marcarFalha`, como hoje.

**Em cascata**, nada a mudar: `syncDias` e `syncGastos` só enviam itens cujo pai já tem `backendId`, então os dias e gastos da viagem bloqueada **ficam na fila sem serem enviados**, e o loop de passadas para sozinho (`pendentesDepois >= pendentesAntes`). Só um `POST` de ciclo por viagem bloqueada por `sync()`.

**Mensagem na tela.** `EstadoEnvio` ganha um caso próprio (ex.: `.aguardandoAssinatura`), tratado como `.pending` pelo contador e mostrado como "Assinatura necessária" (com toque que abre a tela de planos quando o I1b existir); o texto do erro não aparece como "falha".

**Depois da compra:** o `sync(forcar: true)` do I1 sobe a viagem e toda a cascata na **mesma** invocação (a regra do `AGENTS.md`).

**Quem não é bloqueado:** `PUT` de ciclo (editar), `DELETE` e `POST` de dia e de gasto de viagem que já existe no servidor continuam funcionando; viagem criada com acesso e editada depois do vencimento sincroniza normalmente.

**Testes em `SoftSpendTests/` com o `FakeSyncAPI`** (`falhar(.postCiclo, com: APIError.serverError(message: "subscription_required", requestId: "-", statusCode: 403))`; arquivo novo `AssinaturaSyncTests.swift`):
1. viagem nova com 403: fica `.pending`, `tentativas == 0`, `proximaTentativaEm == nil`, `syncError == erroAssinaturaNecessaria`;
2. dias e gastos dessa viagem **nunca são enviados** (contagem de chamadas no fake);
3. só **um** `postCiclo` por `sync()` (não gira);
4. ao tirar a falha (`FakeSyncAPI` sem erro) e rodar `sync(forcar: true)`, **ciclo, dias e gastos sobem na mesma chamada**;
5. `403` com mensagem diferente ainda vai para `marcarFalha` (`.failed`, backoff);
6. `500` e erro de rede seguem como hoje;
7. **não chama logout** nem renovação de token;
8. **apagar a viagem bloqueada** não faz nenhuma requisição e o item some do aparelho (usa `podeTerSidoCriadoNoServidor` sem o marcador, §3.3);
9. viagem que já tem `backendId`, editada, com `postCiclo` falhando em 403: o `PUT` segue normal (o 403 do `POST` não afeta).

### 3.5 I2b: bloqueios na tela (depois do I1)

Regra única: **antes** de chamar o servidor, se o último `GET /api/assinatura` conhecido diz `tem_acesso == false`, abrir a tela de planos em vez da ação. Se o estado é **desconhecido** (nunca carregou, ou sem internet), **deixa passar**: o servidor decide no envio (§3.4) e o 403 direto abre a tela de planos. **Nunca** mostrar "Erro no servidor" para esse 403.

| Onde | Arquivo | Comportamento sem acesso |
| --- | --- | --- |
| Nova viagem | `SubViews/MainView.swift` (abertura do `NewCicloView`, ~linha 267) | Abre os planos. **Editar** viagem existente (`InicioView`, `ViagensView`) fica livre |
| Ler com IA | `Services/LancamentoGasto.swift` (~linha 137, `extrairGastoDeImagem`) | Abre os planos; o gasto à mão segue livre |
| Exportar | `ViewModels/CiclosViewModel.swift` `exportarCiclo` e `Scenes/FecharViagemView.swift` | Abre os planos |
| Importar fatura | `ViewModels/ImportarFaturaViewModel.swift` `ler()` | Abre os planos |

- O `GET /api/assinatura` é lido na abertura do app, ao voltar para o primeiro plano e depois de compra ou restauração; o resultado fica em memória (e em `UserDefaults` só como dica de interface, nunca como autorização).
- **Estados na faixa de aviso:** `grace`/`billing_retry` mostram "Seu pagamento falhou"; `trial` mostra "Teste grátis até DD/MM".
- Testes: viewmodel com loja falsa e `tem_acesso` falso → 4 gatilhos abrem os planos e **não** chamam a rede; `tem_acesso` verdadeiro e estado desconhecido → chamam; um 403 `subscription_required` direto → abre os planos (sem alerta de erro).

## 4. Ligar o bloqueio (passo do usuário, só no fim)

Com `BILLING_ENFORCEMENT=off` o `tem_acesso` é sempre verdadeiro e **nada** abre a tela de planos sozinho; por isso o cartão de Perfil (§3.2) é a entrada que sempre funciona, inclusive para a revisão da Apple.

Ordem, **depois** que a versão da loja com I1 e I2 estiver publicada e os produtos aprovados:
1. Conferir, com uma conta Sandbox e `BILLING_ENFORCEMENT=off`, a compra, a restauração e o `GET /api/assinatura` mostrando `trial`/`active`.
2. Decidir sobre as contas antigas (§6).
3. Na EC2, trocar `BILLING_ENFORCEMENT` para `on` e reiniciar o serviço.
4. Conferir no iPhone: conta sem assinatura bloqueia as quatro ações; conta com assinatura não.
5. Se algo der errado: voltar a `off` (instantâneo; nada foi apagado).

## 5. O que o usuário cria na App Store Connect

Nesta ordem (a maior parte só depois da conta Apple no CNPJ):
1. **Contrato "Apps Pagos" (Paid Applications)**, com **dados bancários e fiscais do CNPJ**. Sem ele, os produtos de assinatura costumam não carregar nem no Sandbox. (Conferir no primeiro teste.)
2. **Registro do app** com o bundle `br.com.softspend.app` e o nome definitivo (U5). Anotar o **ID numérico do app** (vira `APPLE_APP_ID`).
3. **Grupo de assinatura** "SoftSpend" com **dois produtos**: `br.com.softspend.app.assinatura.mensal` (R$ 14,90) e `br.com.softspend.app.assinatura.anual` (R$ 144,90). Disponíveis **só no Brasil**, textos em pt-BR (nome e descrição) e uma **captura de tela da tela de planos** para a revisão.
4. **Oferta introdutória "grátis, 14 dias"** nos dois produtos (só para quem nunca assinou o grupo).
5. **Período de carência de cobrança (Billing Grace Period):** ligar; a duração é decisão (§6; as opções aparecem no painel da Apple; recomendo 16 dias).
6. **Notificações do servidor (V2):** em Informações do app, colocar a URL de **produção** e a de **Sandbox** como `https://softspend.com.br/api/webhooks/apple`; mandar uma **notificação de teste** e conferir que o servidor respondeu 200.
7. **Chave de In-App Purchase** (Usuários e acesso › Integrações › In-App Purchase): gerar e baixar o **`.p8` (só dá para baixar uma vez)**. Guardar em local seguro; o **Issuer ID** e o **Key ID** vão para o `.env` da EC2 junto com o conteúdo do `.p8`. Nunca no repositório, em e-mail ou em conversa.
8. **Testadores Sandbox** (Usuários e acesso › Sandbox): 2 contas com e-mails que não sejam Apple ID reais.
9. **Small Business Program** (15% de taxa): inscrever.
10. **Compartilhamento em Família: desligado** (recomendação; evita uma conta pagar por várias).
11. **URLs de Política de Privacidade e do Contrato de licença (EULA/Termos)**: precisam estar hospedadas (rascunhos em `docs/legal/`, PR #50).
12. **Texto "App Privacy"** da loja alinhado ao `PrivacyInfo.xcprivacy` (tarefa "preparar o projeto para a loja").

## 6. Decisões do usuário (produto; não são do Claude)

- **Contas antigas** ao ligar o bloqueio: viram `none` e precisam assinar. Dar uma carência (ex.: 30 dias grátis só para quem já tem conta) ou todo mundo começa pelo teste da Apple? Hoje só o usuário e quem ele convidou usam o app.
- **Conta nova começa em `none`** e precisa iniciar o teste de 14 dias (com Apple ID) **antes** de criar a primeira viagem. Confirmar que é isso mesmo (é o padrão da loja).
- **Duração da carência de cobrança** (§5 item 5).
- **Sandbox em produção** continua aceito (§2.1) até quando? Sugestão: ligado até a primeira versão aprovada, depois `APPLE_ACEITA_SANDBOX=false` só se a revisão já passou.
- **Hospedar Termos e Privacidade** (bloqueia a loja; ver `docs/legal/`).

## 7. Tarefas do Devin, na ordem

| # | Tarefa | Depende de | Pronto quando |
| --- | --- | --- | --- |
| 1 | **AS2**: biblioteca, verificador injetável, `/api/assinatura/transacoes`, `/api/webhooks/apple`, `reconciliar`, job diário + timer, correção do replay do `POST /ciclos`, `AGENTS.md` | AS1 (PR #59) mesclado | `pytest -q` com os testes do §2.8 |
| 2 | **I2a**: `SyncActor` e o 403 (§3.4), com os 9 testes | nada de StoreKit; pode rodar com a AS2, mas **só mescla depois** da correção do servidor (§3.3) | CI do PR compila e os testes passam |
| 3 | **I1**: `LojaAssinatura`, tela de planos, restaurar, `Transaction.updates`, cartão em Perfil | PR #58 (iOS 17) e "preparar o projeto para a loja"; AS2 no ar para a compra real | CI compila; testes com loja falsa; **compra real só no Mac/TestFlight** |
| 4 | **I2b**: bloqueios na tela (§3.5) e a faixa de aviso | I1 | CI compila e os testes do §3.5 passam |

Em todos: **sem commit direto na `main`**, PR para o usuário aprovar; a migration da AS2 (se houver) vai nos **dois** bancos; nada de segredo no repositório.

## 8. Riscos conhecidos

- **Webhook sem login:** a única proteção é a assinatura do JWS. Qualquer erro de verificação tem que recusar, não "deixar passar". Teste com JWS adulterado.
- **Chave `.p8` vazada** permite consultar e (em parte) mexer em assinaturas; fica só na EC2, com permissão 600; se vazar, revogar na App Store Connect e gerar outra.
- **Sandbox em produção** deixa testadores assinarem de graça (§2.1).
- **Vínculo pelo `appAccountToken`** impede uma conta de reivindicar a compra de outra; o `409` do §2.3 é o que garante isso.
- **Dependência da Apple:** com a Apple fora do ar, `/transacoes` dá `503` e a compra fica pendente no app; o acesso já concedido segue valendo até `expira_em`.
