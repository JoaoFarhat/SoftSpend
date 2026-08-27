//
//  GastosDiaModel.swift
//  SoftexVamo
//
//  Created by Joao Victor on 14/08/26.
//

import SwiftData
import Foundation
import os

@Model
nonisolated final class GastosDia {
    private static let logger = Logger(subsystem: "br.com.softspend", category: "GastosDiaModel")

    @Attribute(.unique) var id: UUID
    
    var clientId: String
    var backendId: Int?
    @Transient
    var diaId: Int? {
        return dia?.backendId
    }
    var dia: DiaSoftex?
    var valor: Decimal
    var titulo: String
    var categoria: Categoria
    var comprovanteUrl: String?
    var comprovanteDataCriptografado: Data?

    @Transient
    var comprovanteData: Data? {
        get {
            guard let comprovanteDataCriptografado else { return nil }
            do {
                return try ComprovanteCrypto.shared.descriptografar(comprovanteDataCriptografado)
            } catch {
                GastosDia.logger.error("ComprovanteCrypto: falha ao descriptografar comprovante: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        set {
            if let newValue {
                do {
                    comprovanteDataCriptografado = try ComprovanteCrypto.shared.criptografar(newValue)
                } catch {
                    GastosDia.logger.error("ComprovanteCrypto: falha ao criptografar comprovante: \(error.localizedDescription, privacy: .public)")
                    comprovanteDataCriptografado = nil
                }
            } else {
                comprovanteDataCriptografado = nil
            }
        }
    }
    var comprovanteParaRemover: Bool = false
    
    var syncStatusRaw: String = SyncStatus.pending.rawValue
    @Transient
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
        valor: Decimal,
        titulo: String,
        categoria: Categoria,
        dia: DiaSoftex? = nil,
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
        self.dia = dia
        self.backendId = backendId
        self.comprovanteUrl = comprovanteUrl
        self.comprovanteDataCriptografado = nil
        self.comprovanteData = comprovanteData
        self.comprovanteParaRemover = comprovanteParaRemover

        self.tentativas = 0
        self.syncStatusRaw = SyncStatus.pending.rawValue
    }

    convenience init(from dto: GastosDiaResponse) {
        self.init(
            clientId: dto.clientId ?? UUID().uuidString,
            valor: dto.valor,
            titulo: dto.titulo,
            categoria: dto.categoria,
            backendId: dto.id,
            comprovanteUrl: dto.comprovante_url
        )
        self.syncStatus = .synced
    }
    
    @Transient
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

nonisolated struct GastoExtraidoResponse: Codable, Sendable {
    let titulo: String
    let valor: Decimal
    let categoria: Categoria
}
