//
//  EncurtarViagem.swift
//  SoftexVamo
//

import Foundation

/// Aviso antes de encurtar a viagem: `CiclosViewModel.editCiclo` apaga os dias
/// fora das novas datas e os gastos deles. A tela conta quantos gastos estão
/// em risco e pede confirmação em vez de excluir sem aviso.
nonisolated enum EncurtarViagem {
    /// Número de gastos vivos (`deletadoEm == nil`) dos dias vivos que ficam
    /// fora de `ida...volta`. Mesma comparação do `editCiclo`: o dia sobrevive
    /// se bate (`Calendar.isDate(_:inSameDayAs:)`) com uma das novas datas,
    /// geradas como em `createAllDiasLoteRequest` (ida + i dias, no mínimo 1).
    static func gastosForaDoPeriodo(dias: [DiaSoftex], ida: Date, volta: Date,
                                    calendario: Calendar = .current) -> Int {
        let quantidade = max(calendario.datesBetween(ida, and: volta), 1)
        var novasDatas: [Date] = []
        for i in 0..<quantidade {
            if let data = calendario.date(byAdding: .day, value: i, to: ida) {
                novasDatas.append(data)
            }
        }

        var total = 0
        for dia in dias where dia.deletadoEm == nil {
            let ficaDentro = novasDatas.contains { calendario.isDate($0, inSameDayAs: dia.data) }
            guard !ficaDentro else { continue }
            total += dia.gastos.reduce(0) { $0 + ($1.deletadoEm == nil ? 1 : 0) }
        }
        return total
    }
}
