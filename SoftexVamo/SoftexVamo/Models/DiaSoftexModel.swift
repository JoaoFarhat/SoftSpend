//
//  DiaSoftexModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import SwiftData
import Foundation

@Model
final class DiaSoftex {
    @Attribute(.unique) var id: UUID
    
    var backendId: Int?
    @Relationship(deleteRule: .cascade) var gastos: [GastosDia]
    var data: Date
    var saldo: Float
    
    var syncStatus: SyncStatus = SyncStatus.pending
    var syncError: String?
    var criadoEm: Date = Date.now
    var atualizadoEm: Date = Date.now
    var deletadoEm: Date?
    
    init(
        id: UUID = UUID(),
        data: Date,
        saldo: Float,
        gastos: [GastosDia] = []
    ) {
        self.id = id
        self.data = data
        self.saldo = saldo
        self.gastos = gastos
    }
    
    convenience init(from dto: DiaSoftexResponse) {
        self.init(
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


