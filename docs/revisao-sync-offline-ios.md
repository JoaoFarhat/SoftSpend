# Revisão do sync offline do app iOS

Data: 11/11/2026. Escopo: `SoftexVamo/SoftexVamo/Services/SyncManager.swift` (`SyncManager` e `SyncActor`),
as escritas locais em `ViewModels/CiclosViewModel.swift` e as rotas de `Python/services/{gasto,dia,ciclo}_service.py`.

**Como foi feito:** leitura de código. Nada foi executado (o app só compila no Mac). Cada risco diz se o caminho
está confirmado no código ou depende de um comportamento do SwiftData que precisa de teste.

Os três cenários pedidos estão nos riscos R1 a R9. Gravidade: **Alta** = perde ou duplica gasto sem o usuário ver;
**Média** = acontece em situação menos comum ou o usuário percebe; **Baixa** = incômodo.

## Resumo

- O sync em si (fila, cascata, backoff, `client_id`) é sólido para o caso simples: um aparelho, sem editar durante o envio.
- O maior problema **não está no `SyncActor`**: está no refresh do servidor (`CiclosViewModel`), que sobrescreve o que ainda
  está pendente e o marca como sincronizado (R1).
- O segundo é o envio em lote de dias (`sincronizar_dias_lote`), que **apaga no servidor** todo dia (e os gastos dele)
  que não está na lista do aparelho (R3).
- O terceiro é que o `SyncActor` marca `.synced` depois do `await` sem conferir se o item mudou nesse meio tempo (R2).

## Riscos

### R1 — Alta — Refresh do servidor apaga edição e exclusão pendentes (confirmado no código)

`salvarOuAtualizarCicloLocal`, `salvarOuAtualizarDiaLocal` e `salvarOuAtualizarGastoLocal` (`CiclosViewModel.swift`)
copiam os campos do servidor por cima do registro local e fazem `syncStatus = .synced`, **sem olhar se ele estava
`pending`/`failed`**. Roda em `loadCiclos` (abrir o app) e em `carregarDiasDoServidor` (abrir a viagem).

Consequências:
- **Edição offline perdida:** edita um gasto sem internet, abre o app com internet; o refresh traz o valor antigo e marca
  `synced`. A edição nunca sobe.
- **Exclusão offline nunca enviada:** gasto/ciclo com `deletadoEm` e `pending` vira `synced`; o `syncDeletions` só busca
  `syncStatusRaw != synced`, então o delete não é enviado. Fica escondido aqui e vivo no servidor (aparece no outro
  aparelho e volta depois que `limparDadosMortos` apaga a cópia local, 7 dias depois).
- É a janela "app abre online" que roda `loadCiclos` e `sync` quase juntos; é o caso comum, não raro.

### R2 — Alta — Editar (ou apagar) durante o envio: o `.synced` do `SyncActor` vence (confirmado o padrão; o efeito exato depende do SwiftData)

Em `syncGastos`, a requisição é montada antes do `await` e, depois da resposta, o código chama `marcarSucesso(gasto)`
sem conferir se o gasto mudou. Se o usuário editou o gasto (`editGasto` na MainActor, que põe `.pending`) enquanto o
POST/PUT estava em voo, o `SyncActor` grava `.synced` e a edição fica só no aparelho. Vale também para:
- **POST em voo + apagar:** o gasto ainda não tem `backendId`; o usuário apaga (`deletadoEm`, `.pending`); a resposta
  chega, `marcarSucesso` põe `.synced` e o delete nunca é enviado: o gasto fica no servidor.
- **Comprovante:** `sincronizarComprovante` faz `comprovanteData = nil` depois do upload; uma foto nova anexada durante o
  upload é descartada.
- **Ciclo:** `sincronizarEdicaoCiclo` tem `houveReedicao`, mas só protege os campos; `ciclo.syncStatus = .synced` é
  incondicional.

Incerteza a testar: o `ModelContext` do `SyncActor` pode não enxergar a edição feita no contexto da tela durante o
`await`. Por isso a correção (T2) relê o item num contexto novo em vez de confiar no objeto já carregado.

Também: `SyncManager.sync` descarta a chamada se `isSyncing` (o `sync(forcar:)` disparado pela própria edição). A edição
fica `pending` até o próximo gatilho (abrir o app, voltar a rede). Não perde dado, mas atrasa (R9).

### R3 — Alta — `dias/lote` apaga dias e gastos de outro aparelho (confirmado no código)

`sincronizarEdicaoCiclo` manda ao servidor a lista de dias que **este aparelho** conhece, em toda edição pendente do ciclo
(até só mudar o título). No servidor, `sincronizar_dias_lote` remove todo dia cuja data não está na lista, **com os gastos**
(cascata) e ajusta `gasto_total`.

Cenário "mesmo usuário em dois aparelhos": o aparelho A estende o período (dias novos) e lança gastos neles. O aparelho B,
que ainda não buscou esses dias, edita o título do ciclo. O lote de B não tem os dias novos, e o servidor apaga os dias e
os gastos de A. Sem aviso, sem desfazer.

Mesmo risco, em menor escala, com a lista local incompleta de uma viagem grande (a busca é paginada).

### R4 — Média — Gasto lançado/editado para um dia apagado em outro aparelho trava em `failed` (confirmado)

`syncGastos` trata qualquer erro como falha com backoff (`marcarFalha`); 404 não é tratado como terminal (só os deletes
tratam 404). Um gasto novo ou editado cujo `dia_id` (ou o próprio gasto) já não existe no servidor tenta de novo para
sempre, fica `failed` com `proximaTentativaEm` até 1 h, e continua em `contarPendentes`. O dado do usuário não é
perdido, mas também não é enviado nem explicado. Mesma coisa para `syncDias` (ciclo apagado em outro lugar).

### R5 — Média — Exclusões feitas em outro aparelho nunca chegam (confirmado no código)

Só há remoção local de **dias sem gasto** (`removerDiasSumidos`). Não existe para gastos nem para ciclos: um gasto
apagado no aparelho A continua na tela do B para sempre, enquanto o `gasto_total` do ciclo (que vem do servidor) já o
descontou. Os números ficam inconsistentes entre o total e a lista.

### R6 — Média — Gasto duplicado no aparelho (confirmado no código)

`salvarOuAtualizarGastoLocal` casa só por `backendId`; o gasto não tem fallback por `clientId` (o dia tem, desde 10/11).
Se o servidor já criou o gasto mas o aparelho ainda não gravou o `backendId` (resposta perdida, ou refresh rodando durante
o POST em voo), o refresh insere um **segundo** gasto local com o mesmo `backendId`. Não há dedup local de gasto
(existe para ciclo e dia). Resultado: gasto aparece duas vezes e o total mostrado na lista dobra para aquele gasto.

### R7 — Média — Apagar ciclo/dia/gasto que ainda não tem `backendId` não apaga no servidor se o POST já tinha dado certo (confirmado)

`deleteCiclo` (e o caminho de dia/gasto sem `backendId` em `syncDeletions`) apaga só localmente quando não há `backendId`.
Se o servidor processou o POST e a resposta se perdeu, o registro existe lá com o `client_id`. Na próxima busca ele
volta (para ciclo: `loadCiclos` insere de novo). É o cenário "timeout com a requisição já processada" que o `client_id`
foi criado para tratar, só que o delete não o usa.

### R8 — Média — Apagar ciclo com dias/gastos pendentes deixa filhos zumbis (confirmado)

`deleteCiclo` marca só o ciclo. Os dias e gastos pendentes continuam `deletadoEm == nil`:
- na mesma passada, `syncDias` e `syncGastos` ainda enviam os filhos (rodam antes de `syncDeletions`) e depois o ciclo é apagado;
- se o ciclo é apagado antes de os filhos terem `backendId`, na passada seguinte eles dão 404 e ficam `failed` para sempre,
  e `contarPendentes` nunca chega a zero (o `pendentesRestantes` mostrado fica errado) até o `limparDadosMortos`
  apagar o ciclo, 7 dias depois;
- se a apagada acontece com o POST do ciclo em voo (R2), o ciclo é criado no servidor depois que o usuário o apagou e volta
  na próxima busca.

Não perde gasto que o usuário quer manter, mas gera lixo no servidor e estado "pendente" falso.

### R9 — Baixa — Dois detalhes

- **Sync descartado enquanto outro roda:** ver R2. Sugestão: lembrar que houve pedido durante o sync e rodar de novo ao fim.
- **Lote por data, não por `clientId`:** se dois aparelhos criam o mesmo dia (mesma data) offline, o lote reconhece pela data,
  devolve o dia com o `clientId` do outro aparelho e o app insere um segundo dia local para a mesma data; depois o `syncDias`
  ainda pode criar um dia repetido no servidor. (Raro: exige criar dias de mesma data nos dois aparelhos.)

### O que está bom (não mexer)

- Criação idempotente por `client_id` nos três níveis; PUT idempotente (diferença calculada contra o valor do servidor);
  DELETE trata 404 como sucesso; cascata ciclo → dia → gasto → comprovante; saldo e `gasto_total` atualizados com
  `UPDATE ... SET x = x + valor` (atômico no banco).
- Isolamento por `userId` nos fetches.

## Tarefas para o Devin

**Status: todas as tarefas abaixo já estão mergeadas na `main`; falta só a validação no Mac** (build + testes no
simulador).

Ordem sugerida: T0, T1, T2, T3, T8, T6, T4, T5, T7, T9. Cada uma vira um PR pequeno. Todas dependem do Mac para rodar
`xcodebuild` e os testes; descrever o resultado no PR. Todas são só do app (nenhuma mexe no backend).

### T0 — Poder testar o SyncActor (pré-requisito) — Complexa

`SyncActor` chama `NetworkManager.shared` direto, então nada acima é testável. Extrair um protocolo (por exemplo
`SyncAPI`) com só as chamadas usadas pelo `SyncActor` (`postCiclo`, `putCiclo`, `syncDiasLote`, `postDiasLote`, `postGasto`,
`putGasto`, `deleteGasto/Dia/Ciclo`, `fetch*` não entram, `uploadComprovante`, `deleteComprovante`); `NetworkManager` o implementa; o `SyncActor`
recebe a API no `init` (padrão: `NetworkManager.shared`). Testes em `SoftexVamo/SoftSpendTests/` com um `ModelContainer`
em memória e uma API falsa que pode atrasar a resposta (`await` controlado) e falhar sob comando. Manter `nonisolated`
(ver `AGENTS.md`). Pronto quando o `xcodebuild` compilar e um teste simples (ciclo → dia → gasto sobem em cascata) passar.

### T1 — Refresh do servidor não pode apagar o que está pendente (R1) — Complexa

Nas três funções `salvarOuAtualizar*Local`: se o registro local existe e `syncStatus != .synced` (ou `deletadoEm != nil`),
**não copiar campos nem mudar o status**: só preencher o que falta (`backendId`, `clientId`) para o casamento. Para o gasto
pendente de exclusão, nunca reviver. Testes: edição pendente sobrevive a um refresh que traz o valor antigo e depois sobe;
exclusão pendente sobrevive ao refresh e o `syncDeletions` a envia; registro `synced` continua sendo atualizado.

**Feito (11/11, falta rodar no Mac):** regra em `CiclosViewModel.temAlteracaoLocal`; testes em
`SoftSpendTests/RefreshPendenteTests.swift`. Dois ajustes a mais, necessários para a exclusão de dia chegar ao servidor:
- `diaLocal(clientId:)` também acha dia com `deletadoEm` (dia apagado antes de receber o `backendId` voltava como novo).
- `carregarDiasLocais` põe em `atualCiclo.dias` também os dias apagados: com só os vivos, o SwiftData fazia
  `dia.ciclo = nil` no dia com exclusão pendente e o `syncDeletions` (filtra por `dia.ciclo?.userId`) o ignorava.

### T2 — Não marcar `.synced` se o item mudou durante o envio (R2) — Complexa

Em `syncGastos` (POST e PUT), `syncComprovantes`, `sincronizarEdicaoCiclo` e `syncDias`: guardar uma foto dos campos enviados
(título, valor, categoria, `dia_id`, `deletadoEm`, `comprovanteDataCriptografado`, `comprovanteParaRemover`) antes do `await`.
Depois da resposta, **gravar sempre o `backendId` devolvido** (para o POST não se repetir), mas só chamar `marcarSucesso` se
uma leitura **em contexto novo** (`ModelContext(modelContainer)`, buscando por `clientId`) mostra os mesmos valores da
foto. Se mudou, deixar `.pending` (sem `tentativas`/backoff, é mudança do usuário, não falha) e pedir nova passada.
`sincronizarComprovante` não pode zerar `comprovanteData` se ele mudou durante o upload. Em `sincronizarEdicaoCiclo`,
`.synced` também só se nada mudou. Testes (API falsa com `await` controlado): editar durante POST, editar durante PUT,
apagar durante POST, anexar comprovante novo durante upload; em todos o estado final tem que ser `.pending` e o servidor
falso deve acabar com o valor novo / sem o gasto.

**Feito (11/11, falta rodar no Mac):** em `SyncActor` (`Services/SyncManager.swift`); testes em
`SoftSpendTests/MudancaDuranteEnvioTests.swift`. Escolhas:
- O `SyncActor` não usa mais o próprio `modelContext`: cada etapa lista num contexto novo e a resposta é gravada
  em outro contexto novo (`gravar`), aberto depois do `await`. Assim a próxima passada envia o valor novo.
- A releitura busca pelo `id` (UUID único) em vez do `clientId`.
- O "`.pending`" é conferido quando a próxima chamada chega; no fim do mesmo `sync()` o item já subiu e está `.synced`.
- Também protegidos: POST do ciclo; dia apagado durante o `dias/lote` não é revivido; saldo do dia não é sobrescrito
  se mudou durante o POST.

### T3 — Parar de usar o lote que apaga (R3) — Simples (só app, depois da T0)

Confirmado no código: `NetworkManager.syncDiasLote` é `PUT /ciclos/{id}/dias/lote` (rota `sincronizar_dias_lote`, que
**remove** o que não está na lista); `postDiasLote` é `POST` no mesmo caminho (`criar_dias_lote`, só cria e deduplica por
`client_id`).

- Em `sincronizarEdicaoCiclo`, **remover a chamada `syncDiasLote`** e o bloco que reconcilia os dias com a resposta
  (o que marca `deletadoEm` em dia que "sumiu" do servidor). Fica só o `putCiclo`.
- Nada se perde: dia novo criado em `editCiclo` já nasce `pending` (padrão do model) e sobe pelo `syncDias`
  (`postDiasLote`, idempotente); dia removido já tem `deletadoEm` e sobe pelo `syncDeletions` (`DELETE /dias/{id}`).
- Sem mudança no backend: o `PUT` continua existindo para versões já instaladas do app. Se um app antigo estiver em uso
  fora dos aparelhos de teste (pergunta do TestFlight na nota), avaliar depois um guarda no servidor (por exemplo o
  parâmetro `somente_adicionar`); hoje não é necessário.
- Testes (API falsa da T0): editar só o título não chama o lote nem apaga dia; estender o período sobe os dias novos pelo
  `syncDias`; reduzir o período apaga só os dias removidos, por `DELETE`.
- Pronto quando o `xcodebuild` compilar e os testes passarem no simulador (Mac).

**Feito (11/11, falta rodar no Mac):** `sincronizarEdicaoCiclo` ficou só com o `putCiclo`; o `syncDiasLote` continua no
`SyncAPI`/`NetworkManager`/`FakeSyncAPI` (o `PUT` segue no backend para versões já instaladas). Testes em
`SoftSpendTests/EdicaoCicloSyncTests.swift`, incluindo o cenário do R3 (dia e gasto criados por outro aparelho
sobrevivem a uma edição de título).

### T8 — Apagar ciclo com filhos pendentes (R8) — Simples

Em `deleteCiclo` (com `backendId`), marcar também os dias e gastos vivos do ciclo como `deletadoEm` (como o `editCiclo`
já faz para dias removidos) **ou** fazer `syncDias`, `syncGastos`, `syncComprovantes` e `contarPendentes` ignorarem filhos de
ciclo com `deletadoEm != nil`. Preferir a segunda (não gera DELETEs inúteis, o servidor apaga em cascata). Teste: ciclo com dia
e gasto pendentes, apagar, sincronizar: `contarPendentes == 0`, nenhum POST dos filhos depois do delete.

**Feito e mergeado (11/11, PR #20). Pendência: validação no Mac:** segunda opção — `syncDias`, `syncGastos`, `syncComprovantes` e `contarPendentes`
ignoram, em memória depois do fetch, dia cujo `ciclo?.deletadoEm != nil` e gasto cujo `dia?.deletadoEm != nil` ou
`dia?.ciclo?.deletadoEm != nil`. O `syncDeletions` não mudou: como o `deleteCiclo` não marca os filhos, só sai o
`DELETE` do ciclo e o servidor apaga o resto em cascata. Testes em `SoftSpendTests/CicloApagadoSyncTests.swift`.

### T6 — Casar gasto também por `clientId` e deduplicar (R6) — Simples

Em `salvarOuAtualizarGastoLocal`, se não achar por `backendId`, procurar por `clientId` (nos gastos do mesmo dia) e preencher
o `backendId` nele em vez de inserir outro. Adicionar `absorverDuplicatasDeGasto` (mesmo `backendId`, registros diferentes;
fica o que tem comprovante local pendente ou o mais antigo), chamado ao carregar os dias, como já existe para dia.
Testes: refresh durante POST em voo não duplica; duplicata já existente é absorvida.

**Feito e mergeado (11/11, PR #21). Pendência: validação no Mac:** casamento por `clientId` em `gastoLocal(clientId:no:)` (prefere o gasto vivo, como
`diaLocal(clientId:)`); com alteração local só preenche o `backendId` (regra da T1). `absorverDuplicatasDeGasto(no:)` roda
junto do `absorverDuplicatas(de:)` nos dois ramos de `salvarOuAtualizarDiaLocal`: para cada `backendId` dos gastos do dia,
busca global e fica o registro com `comprovanteDataCriptografado` (upload ainda não feito), senão o de `criadoEm` menor.
Testes em `SoftSpendTests/GastoDuplicadoTests.swift`.

### T4 — 404 ao criar/editar gasto ou dia: parar de tentar e avisar (R4) — Simples (depende de decisão do usuário)

Tratar 404 em `syncGastos` (PUT e POST) e `syncDias` como terminal: sem backoff, `syncStatus = .failed`, `syncError` com
texto claro ("O dia/gasto foi apagado em outro aparelho") e fora do `contarPendentes`. O que fazer com o gasto depois é
**decisão do usuário** (ver abaixo); até lá, manter o gasto local, sem apagar.

**Feito e mergeado (11/11, PR #22, `fdc255e`). Pendência: validação no Mac** — build + `FalhaFinal404Tests` + suíte
completa no simulador, ainda não rodada (o trabalho foi feito no Windows, sem Xcode). Implementação em `SyncActor`
(`Services/SyncManager.swift`). `isNotFoundError` no catch de
`syncGastos` e `syncDias` chama `marcarFalhaFinal`: `.failed` + `syncError = SyncActor.erroApagadoEmOutroAparelho`
("O dia ou a viagem foi apagado em outro aparelho"), sem tocar em `tentativas`/`proximaTentativaEm`. O texto fixo é o
identificador (`falhouDefinitivo`) — `syncDias`, `syncGastos`, `syncComprovantes` e `contarPendentes` ignoram esses
itens em memória; `syncDeletions` não (o DELETE de item apagado pelo usuário continua saindo, 404 lá é sucesso).
Uma edição do usuário limpa o `syncError` (`editGasto` já faz isso) e o item volta a tentar — e toma 404 de novo se o
pai seguir apagado. Testes em `SoftSpendTests/FalhaFinal404Tests.swift`: POST e PUT de gasto, POST de dia e o
contraste do 500 com backoff.

### T5 — Propagar exclusões do servidor (R5) — Complexa

Com a lista de dias completa (`listaCompleta`, como em `removerDiasSumidos`): gasto local `synced`, com `backendId`, que não
veio na lista do dia, sai do aparelho. Para ciclos, com a lista completa de `fetchCicloResumo`, ciclo `synced` com `backendId`
ausente sai. Nunca remover item `pending`/`failed` nem com `deletadoEm`. Depende de T1. Testes dos dois casos mais o
"item pendente é preservado".

**Feito e mergeado (PR #24). Pendência: validação no Mac** — build + `ExclusaoNoServidorTests` + suíte
completa no simulador (feito no Windows, sem Xcode). Implementação em `CiclosViewModel`:
- Gastos (`removerSumidos`, que substitui `removerDiasSumidos`): candidatos são os gastos `synced`, com `backendId` e sem
  `deletadoEm` antes da busca; comparados com os gastos de **todos** os dias da lista (gasto movido de dia não sai).
- Dia ausente da lista sai só se todos os gastos dele também saem (o delete em cascata nunca leva gasto vivo ou pendente).
- Ciclos (`iniciarLeituraDeCiclos` + `registrarPaginaDeCiclos`): acumula as páginas desde `skip == 0`; só apaga na última
  página (menor que `limit`) e só se nenhuma foi pulada (`proximoSkip`); falha, cancelamento ou offline invalidam a leitura.
- Ciclo fica se ele ou qualquer dia/gasto dele tiver alteração local; se a viagem aberta sai, abre a do início.
- Limite conhecido: ciclo apagado no servidor **entre** duas páginas desloca a lista e pode tirar daqui um ciclo que
  existe; ele volta no próximo carregamento (só sai o que já estava sincronizado, nada pendente se perde).

### T7 — Apagar o que talvez já exista no servidor sem `backendId` (R7) — Complexa

Em `syncDeletions` e `deleteCiclo`: item sem `backendId` mas com `tentativas > 0` ou `syncStatus == .failed` pode ter sido
criado no servidor. Mantê-lo com `deletadoEm` e, no sync, repetir o POST idempotente (mesmo `client_id`) só para descobrir o
`backendId` e então apagar. Item que nunca foi enviado (`tentativas == 0` e sem `syncError`) continua apagando só local.
Teste com API falsa: POST processado com resposta perdida, usuário apaga, o servidor falso termina sem o item.

**Feito e mergeado (PR #25). Pendência: validação no Mac** — build + `ApagarSemBackendIdTests` + suíte
completa no simulador (feito no Windows, sem Xcode).
- Regra única `Syncavel.podeTerSidoCriadoNoServidor` (`SyncManager.swift`): `tentativas > 0`, `.failed` ou `syncError`;
  a falha final por 404 do T4 não conta (o pai não existe no servidor).
- `syncDeletions`: item sem `backendId` que pode existir repete o POST com o mesmo `client_id` (gasto, `dias/lote`,
  ciclo), grava o id e manda o `DELETE`. 404 no POST = não existe; outra falha = backoff, tenta de novo.
- `deleteCiclo`: viagem sem `backendId` mas com envio tentado é marcada (não sai só do aparelho).
  `deleteGasto` e os dias removidos no `editCiclo` já marcavam sempre; o `syncDeletions` decide.
- Nunca enviado: nenhuma requisição (viagem sai do aparelho na hora; gasto/dia ficam marcados como feitos).
- Limite conhecido: viagem/gasto apagado **enquanto** o primeiro POST está no ar (`tentativas == 0`) sai só do
  aparelho e pode ficar no servidor; a resposta do POST é descartada ("item não existe mais").

### T9 — Repetir o sync pedido durante outro sync (R9) — Simples

Em `SyncManager.sync`, se chegar um pedido com `isSyncing == true`, guardar `pedidoPendente = true` (e o `forcar`) e rodar
mais uma vez no fim. Teste: duas chamadas seguidas executam duas passadas.

**Feito e mergeado (11/11, PR #20). Pendência: validação no Mac:** `pedidoPendente`/`forcarPendente` (OU) num `repeat` dentro do `sync(forcar:)`;
a rodada lembrada roda dentro da mesma chamada que estava no ar. Para o teste, `SyncManager.injetarSyncActor` liga um
`SyncActor` com a `FakeSyncAPI` sem disparar o sync automático do `configure`. Teste em
`SoftSpendTests/SyncManagerPedidoTests.swift` (gasto em backoff só sobe na rodada lembrada e forçada).

## Decisões para o usuário (não são técnicas)

1. **Gasto cujo dia foi apagado em outro aparelho (T4):** manter o gasto num dia ainda existente do ciclo (sugestão: o mais
   próximo, com aviso) ou descartar? Hoje ele fica preso. O padrão sugerido é manter e avisar; nenhuma das duas perde dinheiro
   registrado sem aviso.
2. **Dois aparelhos editando o mesmo gasto:** vale "o último a sincronizar vence" (como hoje) ou queremos avisar do conflito?
   Sugestão: manter "o último vence"; avisar custa um campo de versão no banco e uma migração local (V2).
3. **Prioridade:** T1, T2 e T3 evitam perda de dado e valem antes de distribuir o app a mais gente (liga com a pergunta do
   TestFlight já feita na nota).
