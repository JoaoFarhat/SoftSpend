//
//  DiaSoftexDTO.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//

import Foundation

nonisolated struct DiaSoftexResponse: Codable, Sendable {
    let id: Int?
    let clientId: String?
    let data: Date
    /// `"yyyy-MM-dd"`: o dia como data de calendário (`docs/data-do-dia.md`).
    /// Opcional — servidor antigo não devolve, e aí `data` vale como antes.
    let dataLocal: String?
    let saldo: Decimal
    let gastos: [GastosDiaResponse]?

    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case data
        case dataLocal = "data_local"
        case saldo
        case gastos
    }

    nonisolated func toDiaSoftex() -> DiaSoftex {
        DiaSoftex(from: self)
    }
}

nonisolated struct DiaLoteRequest: Codable, Sendable {
    let clientId: String?
    let data: Date
    /// `"yyyy-MM-dd"` no `Calendar.current` do aparelho (`DiaDoCalendario`):
    /// o servidor a grava como a data de calendário do dia. Sempre preenchido
    /// na criação — servidor antigo ignora o campo.
    let dataLocal: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case data
        case dataLocal = "data_local"
    }

    nonisolated init(clientId: String?, data: Date) {
        self.clientId = clientId
        self.data = data
        self.dataLocal = DiaDoCalendario.texto(de: data)
    }
}
