//
//  GastosViewModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 27/07/26.
//

import Foundation
import Combine

final class GastosViewModel: ObservableObject {
    
    @Published var ciclo: CicloSoftex
    @Published var searchGastoText: String = ""
    @Published var categoriaFiltro: Categoria? = nil
    
    init(ciclo: CicloSoftex) {
        self.ciclo = ciclo
    }
    
    func dateToString(date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"
        return dateFormatter.string(from: date)
    }
    
    var secoesExibidas: [DiaSoftex] {
        guard let dias = ciclo.dias else { return []}
        
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
        
        if let diaIndex = ciclo.dias?.firstIndex(where: { $0.id == dia.id }) {
            ciclo.dias?[diaIndex].gastos.removeAll(where: { $0.id == gastoParaRemover.id })
        }
        
        return backendID
    }}
