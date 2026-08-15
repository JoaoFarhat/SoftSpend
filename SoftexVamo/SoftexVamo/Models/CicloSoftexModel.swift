//
//  CicloSoftexModel.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import Foundation
import SwiftData

@Model
final class CicloSoftex {
    @Attribute(.unique) var id: UUID
    
    var clientId: String
    var backendId: Int?
    var valor_total: Float
    var gasto_total: Float
    var periodo: String
    var diaria: Float
    var titulo: String
    
    @Relationship(deleteRule: .cascade) var dias: [DiaSoftex]?
    
    var syncStatus: SyncStatus {
            get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
            set { syncStatusRaw = newValue.rawValue }
        }
    var syncStatusRaw: String = SyncStatus.pending.rawValue
    var syncError: String?
    var tentativas: Int = 0
    
    var proximaTentativaEm: Date?
    var criadoEm: Date = Date.now
    var atualizadoEm: Date = Date.now
    var deletadoEm: Date?
    
    init(
        id: UUID = UUID(),
        clientId: String = UUID().uuidString,
        valor_total: Float,
        gasto_total: Float,
        periodo: String,
        diaria: Float,
        titulo: String,
        dias: [DiaSoftex]? = nil
    ) {
        self.id = id
        self.clientId = clientId
        self.valor_total = valor_total
        self.gasto_total = gasto_total
        self.periodo = periodo
        self.diaria = diaria
        self.titulo = titulo
        self.dias = dias
    }
    
    convenience init(from dto: CicloResponse) {
        self.init(
            clientId: dto.clientId ?? UUID().uuidString,
            valor_total: dto.valor_total,
            gasto_total: dto.gasto_total,
            periodo: dto.periodo,
            diaria: dto.diaria,
            titulo: dto.titulo,
            dias: dto.dias?.map { DiaSoftex(from: $0) }
        )
        self.backendId = dto.id
        self.syncStatus = .synced
    }
    
    func toDTO() -> CicloResponse {
        CicloResponse(
            id: backendId,
            clientId: clientId,
            valor_total: valor_total,
            gasto_total: gasto_total,
            periodo: periodo,
            diaria: diaria,
            titulo: titulo,
            dias: dias?.map { $0.toDTO() }
        )
    }
    
    static let examples = [
        CicloSoftex(valor_total: 2145, gasto_total: 214, periodo: "10/03 - 17/03", diaria: 180, titulo: "Fortaleza", dias: DiaSoftex.examples),
        CicloSoftex(valor_total: 2446, gasto_total: 214, periodo: "18/03 - 25/03", diaria: 167, titulo: "Cuiába", dias: DiaSoftex.examples),
        CicloSoftex(valor_total: 2162, gasto_total: 214, periodo: "26/03 - 01/04", diaria: 172, titulo: "Belém", dias: DiaSoftex.examples),
    ]
    
    static let example = CicloSoftex(valor_total: 2145, gasto_total: 214, periodo: "10/03 - 17/03", diaria: 180, titulo: "Fortaleza", dias: DiaSoftex.examples)
    static let vazio = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
}
