//
//  CicloSoftexDTO.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//

import Foundation

struct CicloCreateRequest: Codable {
    let client_id: String?
    let titulo: String
    let valor_total: Float
    let diaria: Float
    let periodo: String
}

struct CicloUpdateRequest: Codable {
    let titulo: String
    let valor_total: Float
    let diaria: Float
    let periodo: String
}

struct CicloResponse: Codable {
    let id: Int?
    let clientId: String?
    let valor_total: Float
    let gasto_total: Float
    let periodo: String
    let diaria: Float
    let titulo: String
    let dias: [DiaSoftexResponse]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case valor_total
        case gasto_total
        case periodo
        case diaria
        case titulo
        case dias
    }
}
