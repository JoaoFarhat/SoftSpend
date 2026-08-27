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
    let saldo: Decimal
    let gastos: [GastosDiaResponse]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case data
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
    
    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case data
    }
}
