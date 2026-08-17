import Foundation
import Combine
import SwiftData

/// Wrapper imutável para exibir dias com gastos filtrados na UI.
/// NÃO muta o modelo SwiftData — mutar `DiaSoftex.gastos` durante
/// a renderização da view causa ciclo infinito de observação
/// (`@Model` change → re-render → mutação → change → ...) e crash.
struct DiaComGastosFiltrados: Identifiable {
    let dia: DiaSoftex
    let gastosFiltrados: [GastosDia]
    var id: UUID { dia.id }
    var data: Date { dia.data }
}

@MainActor
final class GastosViewModel: ObservableObject {

    @Published var dias: [DiaSoftex]
    @Published var searchGastoText: String = ""
    @Published var categoriaFiltro: Categoria? = nil

    var modelContext: ModelContext?

    init(dias: [DiaSoftex], modelContext: ModelContext? = nil) {
        self.dias = dias
        self.modelContext = modelContext
    }

    func dateToString(date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"
        return dateFormatter.string(from: date)
    }

    /// Retorna dias com gastos filtrados SEM mutar o modelo SwiftData.
    /// O bug anterior fazia `dia.gastos = gastosQueBatem`, que muta
    /// o `@Model` durante o body da view, causando crash/freeze.
    var secoesExibidas: [DiaComGastosFiltrados] {
        return dias.compactMap { dia in
            let gastosQueBatem = dia.gastos.filter { gasto in
                let matchesTexto = searchGastoText.isEmpty || gasto.titulo.localizedCaseInsensitiveContains(searchGastoText)
                let matchesCategoria = categoriaFiltro == nil || gasto.categoria == categoriaFiltro
                // Não exibe gastos deletados (aguardando sync de deleção).
                let matchesDeletado = gasto.deletadoEm == nil
                return matchesTexto && matchesCategoria && matchesDeletado
            }

            if gastosQueBatem.isEmpty { return nil }

            return DiaComGastosFiltrados(dia: dia, gastosFiltrados: gastosQueBatem)
        }
    }
}
