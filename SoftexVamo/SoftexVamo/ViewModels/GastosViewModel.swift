import Foundation
import Combine
import SwiftData

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
    
    var secoesExibidas: [DiaSoftex] {
        return dias.compactMap { dia in
            let gastosQueBatem = dia.gastos.filter { gasto in
                let matchesTexto = searchGastoText.isEmpty || gasto.titulo.localizedCaseInsensitiveContains(searchGastoText)
                let matchesCategoria = categoriaFiltro == nil || gasto.categoria == categoriaFiltro
                return matchesTexto && matchesCategoria
            }
            
            if gastosQueBatem.isEmpty { return nil }
            
            var diaFiltrado = dia
            diaFiltrado.gastos = gastosQueBatem
            return diaFiltrado
        }
    }
    
    func deleteGasto(dia: DiaSoftex, offsets: IndexSet) -> Int? {
        let gastosExibidos = dia.gastos.filter { gasto in
            let matchesTexto = searchGastoText.isEmpty || gasto.titulo.localizedCaseInsensitiveContains(searchGastoText)
            let matchesCategoria = categoriaFiltro == nil || gasto.categoria == categoriaFiltro
            return matchesTexto && matchesCategoria
        }
        
        guard let firstOffset = offsets.first,
              firstOffset < gastosExibidos.count else { return nil }
        
        let gastoParaRemover = gastosExibidos[firstOffset]
        
        guard let backendID = gastoParaRemover.backendId else { return nil }
        
        if let diaIndex = dias.firstIndex(where: { $0.id == dia.id }) {
            dias[diaIndex].gastos.removeAll(where: { $0.id == gastoParaRemover.id })
        }
        
        return backendID
    }
}
