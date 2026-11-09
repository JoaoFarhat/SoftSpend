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
    /// `cicloId` nil = a viagem do início; com id, os gastos daquela viagem
    /// (ex.: "Resolver" em Fechar viagem, aberta a partir de Viagens).
    case todosGastos(filtro: FiltroGastos, cicloId: UUID? = nil)
    case detalheGasto(UUID)
    case fecharViagem(UUID)
    case perfil
}

extension EnvironmentValues {
    /// Empilha uma rota no `NavigationStack` do `MainView`.
    @Entry var abrirRota: (Rota) -> Void = { _ in }
}
