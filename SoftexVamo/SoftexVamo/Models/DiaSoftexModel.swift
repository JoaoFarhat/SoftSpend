//
//  DiaSoftexModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import SwiftData
import Foundation

@Model
nonisolated final class DiaSoftex {
    @Attribute(.unique) var id: UUID
    
    var clientId: String
    var backendId: Int?
    var ciclo: CicloSoftex?
    @Relationship(deleteRule: .cascade, inverse: \GastosDia.dia) var gastos: [GastosDia]
    var data: Date
    var saldo: Decimal
    
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
        data: Date,
        saldo: Decimal,
        gastos: [GastosDia] = []
    ) {
        self.id = id
        self.clientId = clientId
        self.data = data
        self.saldo = saldo
        self.gastos = gastos
        
        self.tentativas = 0
        self.syncStatusRaw = SyncStatus.pending.rawValue
    }
    
    convenience init(from dto: DiaSoftexResponse) {
        self.init(
            clientId: dto.clientId ?? UUID().uuidString,
            data: dto.data,
            saldo: dto.saldo,
            gastos: dto.gastos?.map { GastosDia(from: $0) } ?? []
        )
        self.backendId = dto.id
        self.syncStatus = .synced
    }
    
    func toDTO() -> DiaSoftexResponse {
        DiaSoftexResponse(
            id: backendId,
            clientId: clientId,
            data: data,
            saldo: saldo,
            gastos: gastos.map { $0.toDTO() }
        )
    }
    
    static let examples = [
        DiaSoftex(id: UUID(), data: .now, saldo: 64, gastos: GastosDia.examples),
        DiaSoftex(id: UUID(), data: .now.addingTimeInterval(86400), saldo: 52),
        DiaSoftex(id: UUID(), data: .now.addingTimeInterval(172800), saldo: 42),
        DiaSoftex(id: UUID(), data: .now.addingTimeInterval(259200), saldo: 126),
        DiaSoftex(id: UUID(), data: .now.addingTimeInterval(345600), saldo: 126)
    ]
}


