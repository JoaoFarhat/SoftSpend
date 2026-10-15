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
    let valor: Decimal
    let titulo: String
    let categoria: Categoria
    let comprovante_url: String?
    let openFinanceStatus: String?
    let openFinanceMatch: ExpenseTransactionMatchResponse?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case dia_id
        case valor
        case titulo
        case categoria
        case comprovante_url
        case openFinanceStatus = "open_finance_status"
        case openFinanceMatch = "open_finance_match"
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
    let valor: Decimal
    let categoria: Categoria
    let dia_id: Int
}

nonisolated struct GastoUpdateRequest: Codable, Sendable {
    let titulo: String
    let valor: Decimal
    let categoria: Categoria
    let dia_id: Int?
}
