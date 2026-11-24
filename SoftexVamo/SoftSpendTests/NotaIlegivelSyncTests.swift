import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Nota guardada no aparelho que a chave atual não abre (cifrada por outra
/// chave ou corrompida): o gasto não pode virar `.synced` sem a nota subir.
/// Fica `.failed` com o motivo na tela (`SyncActor.erroNotaNaoAbre`) e
/// backoff — o sync não insiste a cada passada — e os bytes ficam guardados
/// para o caso de a nota voltar a abrir.
@MainActor
struct NotaIlegivelSyncTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    func sync(forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    /// Viagem com um gasto já sincronizado (tem `backendId` no servidor).
    func criarGastoSincronizado() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        ctx.insert(GastosDia(valor: 25, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()
        #expect(await sync() == 0)
        try #require(try lerGasto().syncStatus == .synced)
    }

    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    /// Bytes que a chave atual não abre: nada sobe, o gasto fica `.failed`
    /// com o motivo na tela e backoff, e a passada seguinte não repete.
    @Test func notaIlegivelMarcaFalhaComMotivoEBackoff() async throws {
        try await criarGastoSincronizado()
        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        let ilegiveis = Data([0x01, 0x02, 0x03])
        gasto.comprovanteDataCriptografado = ilegiveis
        gasto.syncStatus = .pending
        try ctx.save()

        let restantes = await sync()

        #expect(restantes == 1)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let falhou = try lerGasto()
        #expect(falhou.syncStatus == .failed)
        #expect(falhou.syncError == SyncActor.erroNotaNaoAbre)
        #expect(falhou.tentativas == 1)
        #expect(falhou.proximaTentativaEm != nil)
        #expect(falhou.comprovanteDataCriptografado == ilegiveis)
        #expect(falhou.comprovanteUrl == nil)
        #expect(EstadoEnvio.de(falhou) == .falhou(SyncActor.erroNotaNaoAbre))

        // Backoff: sem forçar, a passada seguinte não tenta de novo.
        api.limparChamadas()
        _ = await sync()
        #expect(api.chamadas.isEmpty)
        #expect(try lerGasto().tentativas == 1)
    }
}
