//
//  DiaSoftexDTO.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//

import Foundation

struct DiaSoftexResponse: Codable {
    let id: Int?
    let data: Date
    let saldo: Float
    let gastos: [GastosDiaResponse]?
    
    func toDiaSoftex() -> DiaSoftex {
        DiaSoftex(from: self)
    }
}

struct DiaLoteRequest: Codable {
    let data: Date
}
