import Testing

/// Suítes que dependem do usuário global (`AuthService.shared.currentUser`).
///
/// O `CiclosViewModel` e o `SyncManager` leem esse usuário na hora de cada chamada, e o
/// `SyncManagerPedidoTests` precisa trocá-lo (o `SyncManager` exige um id não vazio).
/// Como o Swift Testing roda as suítes em paralelo, essa troca no meio de outro teste
/// fazia o `salvarOuAtualizarCicloLocal` não achar a viagem dele e criar uma cópia
/// (`RefreshPendenteTests` via duas viagens). O `.serialized` vale para as suítes
/// aninhadas: elas rodam uma de cada vez entre si; o resto continua em paralelo.
///
/// Suíte nova que leia ou troque o usuário global entra aqui, num
/// `extension UsuarioGlobalTests { ... }`.
@Suite(.serialized)
struct UsuarioGlobalTests {}
