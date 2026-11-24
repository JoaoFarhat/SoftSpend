//
//  CicloSoftexModel.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import Foundation
import SwiftData

@Model
nonisolated final class CicloSoftex {
    @Attribute(.unique) var id: UUID

    var clientId: String
    var backendId: Int?
    var userId: String
    var valor_total: Decimal
    var gasto_total: Decimal
    var periodo: String
    var diaria: Decimal
    var titulo: String

    @Relationship(deleteRule: .cascade, inverse: \DiaSoftex.ciclo) var dias: [DiaSoftex]?

    var syncStatusRaw: String = SyncStatus.pending.rawValue
    var syncError: String?
    var tentativas: Int = 0
    var proximaTentativaEm: Date?

    @Transient
    var syncStatus: SyncStatus {
            get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
            set { syncStatusRaw = newValue.rawValue }
        }
    
    var criadoEm: Date = Date.now
    var atualizadoEm: Date = Date.now
    var deletadoEm: Date?
    
    init(
        id: UUID = UUID(),
        clientId: String = UUID().uuidString,
        userId: String = "",
        valor_total: Decimal,
        gasto_total: Decimal,
        periodo: String,
        diaria: Decimal,
        titulo: String,
        dias: [DiaSoftex]? = nil
    ) {
        self.id = id
        self.clientId = clientId
        self.userId = userId
        self.valor_total = valor_total
        self.gasto_total = gasto_total
        self.periodo = periodo
        self.diaria = diaria
        self.titulo = titulo
        self.dias = dias

        self.tentativas = 0
        self.syncStatusRaw = SyncStatus.pending.rawValue
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

// `nonisolated` (não `@MainActor`): usado pelo `CiclosViewModel` e pelo `SyncActor`.
nonisolated extension CicloSoftex {
    /// Registro com edição ou exclusão ainda não enviada ao servidor: o refresh não pode
    /// sobrescrever os campos nem marcar `.synced` (o `SyncActor` sobe a versão local depois).
    static func temAlteracaoLocal(_ status: SyncStatus, deletadoEm: Date?) -> Bool {
        status != .synced || deletadoEm != nil
    }

    /// Quantos dias e gastos da viagem (inclusive os apagados cujo `DELETE` ainda
    /// não subiu — eles ainda entrariam no relatório montado pelo servidor) têm
    /// alteração local que o servidor ainda não conhece. A edição da própria
    /// viagem não conta.
    var alteracoesNaoEnviadas: Int {
        (dias ?? []).reduce(0) { total, dia in
            total
                + (Self.temAlteracaoLocal(dia.syncStatus, deletadoEm: dia.deletadoEm) ? 1 : 0)
                + dia.gastos.filter {
                    Self.temAlteracaoLocal($0.syncStatus, deletadoEm: $0.deletadoEm)
                }.count
        }
    }

    /// Algum dia ou gasto da viagem com alteração local que o servidor ainda
    /// não conhece.
    var temAlteracaoNaViagem: Bool {
        alteracoesNaoEnviadas > 0
    }

    /// Copia o `gasto_total` que veio do servidor só quando nenhum dia ou gasto da
    /// viagem tem alteração local pendente. Senão o servidor ainda não conta essa
    /// mudança (gasto feito sem internet, `DELETE` que não subiu) e o total local,
    /// que já conta, fica.
    func receberGastoTotalDoServidor(_ total: Decimal) {
        guard !temAlteracaoNaViagem else { return }
        gasto_total = total
    }
}
