//
//  DiaSoftexDTO.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//

import Foundation

struct DiaSoftexResponse: Codable {
    let id: Int?
    let clientId: String?
    let data: Date
    let saldo: Float
    let gastos: [GastosDiaResponse]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case data
        case saldo
        case gastos
    }
    
    func toDiaSoftex() -> DiaSoftex {
        DiaSoftex(from: self)
    }
}

struct DiaLoteRequest: Codable {
    let clientId: String?
    let data: Date
    
    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case data
    }
}
