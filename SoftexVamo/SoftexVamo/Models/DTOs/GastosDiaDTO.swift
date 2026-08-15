//
//  GastosDiaDTO.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import Foundation

struct GastosDiaResponse: Codable {
    let id: Int?
    let clientId: String?
    let dia_id: Int?
    let valor: Float
    let titulo: String
    let categoria: Categoria
    let comprovante_url: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case dia_id
        case valor
        case titulo
        case categoria
        case comprovante_url
    }
    
    func toGastosDia() -> GastosDia {
        let gasto = GastosDia(
            clientId: clientId ?? UUID().uuidString,
            valor: valor,
            titulo: titulo,
            categoria: categoria,
            diaId: dia_id,
            comprovanteUrl: comprovante_url
        )
        gasto.backendId = id
        gasto.syncStatus = .synced
        return gasto
    }
}

struct GastoCreateRequest: Codable {
    let client_id: String?
    let titulo: String
    let valor: Float
    let categoria: Categoria
    let dia_id: Int
}

struct GastoUpdateRequest: Codable {
    let titulo: String
    let valor: Float
    let categoria: Categoria
    let dia_id: Int?
}
