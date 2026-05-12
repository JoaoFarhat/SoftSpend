//
//  GastoExtraidoResponse.swift
//  SoftexVamo
//

import Foundation

struct GastoExtraidoResponse: Codable {
    let titulo: String
    let valor: Float
    let categoria: Categoria
}
