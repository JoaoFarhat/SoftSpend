# Janela de tolerância no `/auth/refresh`

Análise do caso de borda deixado pelo PR #8 e especificação da correção.

## 1. O problema

`refresh_access_token` (`Python/services/auth_service.py`) rotaciona o refresh
token: marca o antigo com `revoked_at` e emite um novo. Se o app **não recebe a
resposta** (servidor já commitou), o app ainda tem o token antigo. Se ele
reapresentar esse token, o backend vê `revoked_at` preenchido, entende como
roubo e chama `revogar_todos_refresh_tokens_por_usuario`. Desde o PR #8 isso
também derruba na hora todos os access tokens (claim `sid`), em todos os
aparelhos do usuário.

## 2. Medição do risco (leitura do código, sem telemetria)

Caminho do app: `execute` recebe 401 → `TokenRefresher.refresh()` lê o refresh
token do Keychain → `POST /auth/refresh` (timeout de 8 s) → grava os dois tokens
no Keychain **depois** da resposta.

| Cenário | O que acontece hoje | Chega ao "reuso"? |
| --- | --- | --- |
| Resposta perdida por timeout/queda de rede, app vivo | O `catch` de `execute` (NetworkManager.swift, `allowRefresh`) chama `logout(revogandoNoServidor: false)` para **qualquer** erro, que apaga os tokens do Keychain. O usuário volta ao login. | Não. O token antigo some; o login novo abre outra sessão. Custo: relogar. |
| App morto/suspenso e encerrado pelo iOS entre a resposta do servidor e o `saveRefreshToken` | Keychain fica com o token antigo. Na próxima abertura, 401 → refresh com o token antigo. | **Sim.** Derruba todas as sessões. |
| Falha ao gravar no Keychain (rara) | Igual ao anterior. | Sim. |
| Duas requisições de refresh simultâneas com o mesmo token (ex.: dois processos) | No app, o `TokenRefresher` (actor) junta as chamadas, então não ocorre. | Só fora do app (improvável). |

Conclusão:

- **Probabilidade: baixa.** Só o caso "app encerrado no meio do refresh" chega ao
  reuso. O caso mais comum (timeout) já termina em logout local, sem reuso.
- **Impacto: médio, sem perda de dado.** O usuário é deslogado em todos os
  aparelhos e precisa entrar de novo. Os dados offline do SwiftData ficam
  (filtrados por `userId`) e voltam a sincronizar após o login.
- **Vale a pena?** Sim, porque o custo é pequeno (só backend, sem migration) e
  deixa a detecção de reuso mais precisa: ela passa a disparar só para reuso de
  verdade, não para uma réplica logo após a rotação.

## 3. Especificação

Só backend. Sem migration, sem mudança no app.

### Regra

Em `refresh_access_token`, no ramo `rt.revoked_at is not None`:

1. Se `REFRESH_REUSE_GRACE_SECONDS > 0` **e** `agora - rt.revoked_at <= grace`
   **e** `auth_repository.sessao_ativa(db, rt.session_id, rt.user_id)` é
   verdadeiro, tratar como **réplica da rotação**: não revogar nada, emitir um
   novo par (`criar_access_token` + `criar_refresh_token` com o mesmo
   `rt.session_id`) e devolver. Logar em nível `info` (sem o token).
2. Caso contrário, manter o comportamento atual (revogar todas as sessões,
   `db.commit()`, erro).

Variável de ambiente `REFRESH_REUSE_GRACE_SECONDS`, default `60`; `0` desliga a
tolerância. Documentar no `AGENTS.md` (tabela de autenticação).

### Por que não precisa de coluna nova

`revogar_sessao` e `revogar_todos_refresh_tokens_por_usuario` só atualizam linhas
com `revoked_at IS NULL`. Portanto, num token já rotacionado, `revoked_at` é o
instante exato da rotação. E a checagem `sessao_ativa` cobre os casos em que a
sessão acabou:

- logout depois da rotação → nenhuma linha ativa → sem réplica (não ressuscita a sessão);
- reuso anterior ou `REVOKE_OLD_REFRESH_TOKENS_ON_LOGIN` → nenhuma linha ativa;
- token novo expirado → `sessao_ativa` filtra `expires_at > agora`.

A trava `FOR UPDATE` na linha do token antigo continua serializando chamadas
simultâneas: a segunda enxerga `revoked_at` e cai na regra da réplica.

### Trade-off de segurança (aceito)

Quem roubar um refresh token **e** usá-lo até 60 s depois da rotação legítima
recebe um par válido na mesma sessão, sem disparar o alarme. O alarme volta a
valer depois da janela, e o logout derruba a sessão inteira. A janela é curta e
configurável; o endpoint já tem limite de taxa. O token da réplica e o da
rotação original coexistem até expirarem ou o logout.

### O que a janela não cobre

Reabertura do app **depois** de 60 s: o token antigo vira reuso de verdade. É
aceitável: o app encerrado no meio do refresh e reaberto mais de 1 minuto depois
é ainda mais raro. Não aumentar a janela por causa disso.

### Fora do escopo (decisão separada)

O `catch` de `execute` no app desloga em qualquer erro do refresh, inclusive
timeout ou 5xx. Mudar isso para só deslogar em 401/403 seria melhor para quem
tem rede ruim, **mas** deixa o token antigo no Keychain após uma resposta
perdida, e uma nova tentativa depois da janela viraria reuso e derrubaria todas
as sessões (pior que o logout local de hoje). Só vale fazer isso depois da
tolerância no ar, e com atenção ao tempo da janela. Não está nesta tarefa.

**Atualização (app iOS, 11/11/2026):** com a tolerância no ar, o
`TokenRefresher.refresh()` passou a repetir o refresh em falha transitória
(`URLError` ou `APIError.serverError` com status >= 500), até 2 vezes, com
esperas de 1 s e 3 s (`repetindoSeTransitorio` em `NetworkManager.swift`).

- Todas as tentativas reenviam o mesmo token, lido do Keychain uma vez no início.
- Pior caso: 3 × 8 s de timeout + 4 s de espera = 28 s, dentro dos 60 s.
- 401/403, outro erro ou 3 falhas: logout local como antes; o token antigo
  não é guardado para tentar depois (fora da janela seria reuso).
- O `currentTask` continua compartilhado: chamadas simultâneas esperam a mesma
  sequência de tentativas.

## 4. Testes (em `Python/tests/test_auth_sessao.py`)

Controlar o tempo ajustando `revoked_at` do token antigo no banco (ou
monkeypatch de `auth_service._utc_now_naive`).

1. Refresh normal e, em seguida, reapresentar o token antigo dentro da janela →
   200 com par novo; o access token novo e o da rotação original funcionam; a
   outra sessão do mesmo usuário continua válida.
2. Reapresentar o token antigo **fora** da janela → 401 e todas as sessões do
   usuário caem (comportamento atual preservado).
3. Logout depois da rotação e réplica dentro da janela → 401 (não ressuscita).
4. `REFRESH_REUSE_GRACE_SECONDS=0` → réplica dentro do tempo cai no reuso (401 +
   sessões revogadas). O valor é lido na importação; usar o padrão do repositório
   para recarregar o módulo ou fazer a leitura por chamada.
5. Réplica dentro da janela com o token novo já expirado (`expires_at` no
   passado) → 401.
