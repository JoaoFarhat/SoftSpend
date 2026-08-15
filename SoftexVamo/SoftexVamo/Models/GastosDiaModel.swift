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
    
    var clientId: String
    var backendId: Int?
    var diaId: Int?
    var valor: Float
    var titulo: String
    var categoria: Categoria
    var comprovanteUrl: String?
    var comprovanteDataCriptografado: Data?
    var comprovanteData: Data? {
        get {
            guard let comprovanteDataCriptografado else { return nil }
            return try? ComprovanteCrypto.shared.descriptografar(comprovanteDataCriptografado)
        }
        set {
            if let newValue {
                comprovanteDataCriptografado = try? ComprovanteCrypto.shared.criptografar(newValue)
            } else {
                comprovanteDataCriptografado = nil
            }
        }
    }
    var comprovanteParaRemover: Bool = false
    
    var syncStatusRaw: String = SyncStatus.pending.rawValue
    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
        set { syncStatusRaw = newValue.rawValue }
    }
    var syncError: String?
    var tentativas: Int = 0
    var proximaTentativaEm: Date?
    var criadoEm: Date = Date.now
    var atualizadoEm: Date = Date.now
    var deletadoEm: Date?
    
    init(
        id: UUID = UUID(),
        clientId: String = UUID().uuidString,
        valor: Float,
        titulo: String,
        categoria: Categoria,
        diaId: Int? = nil,
        backendId: Int? = nil,
        comprovanteUrl: String? = nil,
        comprovanteData: Data? = nil,
        comprovanteParaRemover: Bool = false
    ) {
        self.id = id
        self.clientId = clientId
        self.valor = valor
        self.titulo = titulo
        self.categoria = categoria
        self.diaId = diaId
        self.backendId = backendId
        self.comprovanteUrl = comprovanteUrl
        self.comprovanteDataCriptografado = nil
        self.comprovanteData = comprovanteData
        self.comprovanteParaRemover = comprovanteParaRemover
    }
    
    convenience init(from dto: GastosDiaResponse) {
        self.init(
            clientId: dto.clientId ?? UUID().uuidString,
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
            clientId: clientId,
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
