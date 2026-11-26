//
//  DiaDoCalendario.swift
//  SoftSpend
//

import Foundation

/// O dia da viagem como data de calendário (`"yyyy-MM-dd"`), sem hora nem fuso
/// (spec `docs/data-do-dia.md`).
///
/// `DiaSoftex.data` é um instante — a meia-noite local de quando o dia foi
/// criado. Como instante, "21/07 em Paris" e "21/07 em São Paulo" são dois
/// valores diferentes, e o servidor lia o dia em UTC — um dia a menos em todo
/// fuso a leste de Greenwich. Por isso o dia trafega também como `data_local`,
/// a data que o usuário vê, e ao receber o app reconstrói `data` como o início
/// daquele dia no fuso do aparelho: dois aparelhos em fusos diferentes
/// concordam sobre qual é o dia.
///
/// O calendário (que carrega o fuso) entra por parâmetro — padrão `.current`,
/// o do aparelho — para os testes não dependerem do fuso do CI.
nonisolated enum DiaDoCalendario {

    /// `"yyyy-MM-dd"` dos componentes de `data` no `calendario` — a data de
    /// calendário que a tela mostra, não o instante.
    static func texto(de data: Date, calendario: Calendar = .current) -> String {
        let c = calendario.dateComponents([.year, .month, .day], from: data)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// O início do dia `"yyyy-MM-dd"` no `calendario`. `nil` se o texto não é
    /// uma data nesse formato — uma resposta fora do esperado não pode
    /// derrubar a decodificação.
    static func inicioDoDia(de texto: String, calendario: Calendar = .current) -> Date? {
        let partes = texto.split(separator: "-", omittingEmptySubsequences: false)
        guard partes.count == 3,
              partes[0].count == 4, partes[1].count == 2, partes[2].count == 2,
              let ano = Int(partes[0]), let mes = Int(partes[1]), let dia = Int(partes[2]),
              let inicio = calendario.date(from: DateComponents(year: ano, month: mes, day: dia)),
              // `date(from:)` normaliza fora de faixa (32/13 vira outra data):
              // só aceita se a volta bate com o texto recebido.
              self.texto(de: inicio, calendario: calendario) == texto else {
            return nil
        }
        return inicio
    }
}
