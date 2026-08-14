//
//  GastosDiaModel.swift
//  SoftexVamo
//
//  Created by Joao Victor on 14/08/26.
//

import SwiftData
import Foundation

@Model
final class GastosDia {
    @Attribute(.unique) var id: UUID
    
    var backendId: Int?
    var diaId: Int?
    var valor: Float
    var titulo: String
    var categoria: Categoria
    var comprovanteUrl: String?
    
    var syncStatus: SyncStatus = SyncStatus.pending
    var syncError: String?
    var criadoEm: Date = Date.now
    var atualizadoEm: Date = Date.now
    var deletadoEm: Date?
    
    init(
        id: UUID = UUID(),
        valor: Float,
        titulo: String,
        categoria: Categoria,
        diaId: Int? = nil,
        backendId: Int? = nil,
        comprovanteUrl: String? = nil
    ) {
        self.id = id
        self.valor = valor
        self.titulo = titulo
        self.categoria = categoria
        self.diaId = diaId
        self.backendId = backendId
        self.comprovanteUrl = comprovanteUrl
    }
    
    convenience init(from dto: GastosDiaResponse) {
        self.init(
            valor: dto.valor,
            titulo: dto.titulo,
            categoria: dto.categoria,
            diaId: dto.dia_id,
            backendId: dto.id,
            comprovanteUrl: dto.comprovante_url
        )
        self.syncStatus = .synced
    }
    
    var temComprovante: Bool {
        comprovanteUrl != nil
    }
    
    func toDTO() -> GastosDiaResponse {
        GastosDiaResponse(
            id: backendId,
            dia_id: diaId,
            valor: valor,
            titulo: titulo,
            categoria: categoria,
            comprovante_url: comprovanteUrl
        )
    }
    
    static let examples = [
        GastosDia(valor: 20, titulo: "Almoco", categoria: .ALIMENTACAO),
        GastosDia(valor: 30, titulo: "Jantar", categoria: .ALIMENTACAO),
        GastosDia(valor: 10, titulo: "Uber", categoria: .TRANSPORTE)
    ]
    
    static let example = GastosDia(valor: 12, titulo: "Uber", categoria: .TRANSPORTE)
}

struct GastoExtraidoResponse: Codable {
    let titulo: String
    let valor: Float
    let categoria: Categoria
}
