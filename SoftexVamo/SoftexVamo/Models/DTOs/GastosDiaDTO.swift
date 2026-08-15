//
//  GastosDiaDTO.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import Foundation

nonisolated struct GastosDiaResponse: Codable, Sendable {
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
    
    // Cria um GastosDia a partir do DTO.
    // IMPORTANTE: O caller deve estabelecer a relação "dia" via "dia.gastos.append(gasto)" ou "gasto.dia = dia.
    nonisolated func toGastosDia() -> GastosDia {
        let gasto = GastosDia(
            clientId: clientId ?? UUID().uuidString,
            valor: valor,
            titulo: titulo,
            categoria: categoria,
            comprovanteUrl: comprovante_url
        )
        gasto.backendId = id
        gasto.syncStatus = .synced
        return gasto
    }
}

nonisolated struct GastoCreateRequest: Codable, Sendable {
    let client_id: String?
    let titulo: String
    let valor: Float
    let categoria: Categoria
    let dia_id: Int
}

nonisolated struct GastoUpdateRequest: Codable, Sendable {
    let titulo: String
    let valor: Float
    let categoria: Categoria
    let dia_id: Int?
}
