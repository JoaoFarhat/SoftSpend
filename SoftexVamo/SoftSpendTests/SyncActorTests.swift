import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Testes do `SyncActor` com banco em memória e a `FakeSyncAPI` no lugar da rede.
///
/// O `SyncActor` tem o próprio `ModelContext`; por isso os dados são gravados
/// com `save()` antes do sync e lidos depois num contexto novo.
@MainActor
struct SyncActorTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    /// Ciclo → dia → gasto criados offline (nenhum com `backendId`), já salvos.
    func criarViagemOffline() throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        try ctx.save()
    }

    struct Local {
        let ciclo: CicloSoftex
        let dia: DiaSoftex
        let gasto: GastosDia
    }

    /// Lê o banco local num contexto novo (vê o que o `SyncActor` salvou).
    func lerLocal() throws -> Local {
        let ctx = ModelContext(container)
        let ciclos = try ctx.fetch(FetchDescriptor<CicloSoftex>())
        let dias = try ctx.fetch(FetchDescriptor<DiaSoftex>())
        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        try #require(ciclos.count == 1 && dias.count == 1 && gastos.count == 1)
        return Local(ciclo: ciclos[0], dia: dias[0], gasto: gastos[0])
    }

    func sync(forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    /// Pronto da T0: tudo criado offline sobe numa única chamada de `sync()`,
    /// cada etapa destravada pelo `backendId` do pai.
    @Test func cicloDiaEGastoSobemEmCascata() async throws {
        try criarViagemOffline()

        let restantes = await sync()

        #expect(restantes == 0)
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])

        let cicloRemoto = try #require(api.ciclos.first)
        let diaRemoto = try #require(api.dias.first)
        let gastoRemoto = try #require(api.gastos.first)
        #expect(diaRemoto.cicloId == cicloRemoto.id)
        #expect(gastoRemoto.diaId == diaRemoto.id)

        let local = try lerLocal()
        #expect(local.ciclo.backendId == cicloRemoto.id)
        #expect(local.dia.backendId == diaRemoto.id)
        #expect(local.gasto.backendId == gastoRemoto.id)
        #expect(local.ciclo.clientId == cicloRemoto.clientId)
        #expect(local.dia.clientId == diaRemoto.clientId)
        #expect(local.gasto.clientId == gastoRemoto.clientId)
        #expect(local.ciclo.syncStatus == .synced)
        #expect(local.dia.syncStatus == .synced)
        #expect(local.gasto.syncStatus == .synced)
    }

    /// Se o ciclo não sobe, nada abaixo dele é enviado; com a falha resolvida,
    /// um sync forçado (ignora o backoff) sobe tudo.
    @Test func falhaNoCicloSeguraOsFilhos() async throws {
        try criarViagemOffline()
        api.falhar(.postCiclo)

        let restantes = await sync()

        #expect(restantes == 3)
        #expect(api.chamadas == [.postCiclo])
        #expect(api.ciclos.isEmpty)
        var local = try lerLocal()
        #expect(local.ciclo.syncStatus == .failed)
        #expect(local.ciclo.tentativas == 1)
        #expect(local.ciclo.proximaTentativaEm != nil)
        #expect(local.dia.syncStatus == .pending)
        #expect(local.gasto.syncStatus == .pending)

        api.pararDeFalhar(.postCiclo)
        let depois = await sync(forcar: true)

        #expect(depois == 0)
        local = try lerLocal()
        #expect(local.ciclo.syncStatus == .synced)
        #expect(local.ciclo.tentativas == 0)
        #expect(local.gasto.backendId == api.gastos.first?.id)
    }

    /// A API falsa segura a resposta: o sync fica parado no POST do ciclo até o
    /// teste liberar, e então continua a cascata.
    @Test func respostaAtrasadaSeguraOSyncAteLiberar() async throws {
        try criarViagemOffline()
        let portao = api.segurar(.postCiclo)
        let syncActor = SyncActor(modelContainer: container, api: api)
        let usuario = self.userId

        let tarefa = Task { await syncActor.sync(agora: .now, userId: usuario) }
        await portao.aguardarChegada()

        #expect(api.chamadas == [.postCiclo])
        #expect(api.ciclos.isEmpty)

        await portao.liberar()
        let restantes = await tarefa.value

        #expect(restantes == 0)
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        #expect(try lerLocal().gasto.syncStatus == .synced)
    }
}
