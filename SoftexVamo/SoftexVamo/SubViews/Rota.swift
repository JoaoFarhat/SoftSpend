import SwiftUI

/// Filtro com que "Todos os gastos" abre.
enum FiltroGastos: Hashable {
    case todos
    case semComprovante
    case categoria(Categoria)
}

/// Destinos empilhados a partir do início (`.navigationDestination(for: Rota.self)` no `MainView`).
enum Rota: Hashable {
    case novaViagem
    case viagens
    case viagem(UUID)
    case todosGastos(filtro: FiltroGastos)
    case detalheGasto(UUID)
    case fecharViagem(UUID)
    case perfil
}

extension EnvironmentValues {
    /// Empilha uma rota no `NavigationStack` do `MainView`.
    @Entry var abrirRota: (Rota) -> Void = { _ in }
}
