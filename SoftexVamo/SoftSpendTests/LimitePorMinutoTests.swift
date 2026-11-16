import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// 429 do limite por minuto (slowapi) no `SyncActor`: não é falha — o item
/// fica `.pending` sem contar tentativa e sem erro na tela, tenta de novo
/// depois de 60 s, e nenhuma chamada à API acontece depois dele no mesmo
/// `sync` (etapas seguintes e passadas restantes param, mesmo com `forcar`).
///
/// O outro 429 — `daily_ai_limit`, teto diário de leituras por IA — continua
/// no caminho antigo (`.failed` com backoff).
@MainActor
struct LimitePorMinutoTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    /// O erro que o servidor devolve no limite por minuto.
    static let limite = APIError.serverError(
        message: "Rate limit exceeded", requestId: "", statusCode: 429)

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

    func sync(agora: Date = .now, forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: agora, userId: userId, forcar: forcar)
    }

    /// 429 no POST do gasto: ciclo e dia sobem, o gasto fica `.pending` sem
    /// contar tentativa e sem erro na tela.
    @Test func gastoRecusadoFicaPendingSemErro() async throws {
        try criarViagemOffline()
        api.falhar(.postGasto, com: Self.limite)
        let agora = Date()

        let restantes = await sync(agora: agora)

        #expect(restantes == 1)
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        #expect(api.gastos.isEmpty)
        let local = try lerLocal()
        #expect(local.ciclo.syncStatus == .synced)
        #expect(local.dia.syncStatus == .synced)
        #expect(local.gasto.syncStatus == .pending)
        #expect(local.gasto.tentativas == 0)
        #expect(local.gasto.syncError == nil)
        #expect(local.gasto.proximaTentativaEm == agora.addingTimeInterval(60))
    }

    /// Sem o erro, o sync seguinte (61 s depois) sobe o que ficou esperando.
    @Test func depoisDeUmMinutoSobeTudo() async throws {
        try criarViagemOffline()
        api.falhar(.postGasto, com: Self.limite)
        let agora = Date()
        _ = await sync(agora: agora)

        api.pararDeFalhar(.postGasto)
        api.limparChamadas()
        let restantes = await sync(agora: agora.addingTimeInterval(61))

        #expect(restantes == 0)
        #expect(api.chamadas == [.postGasto])
        let local = try lerLocal()
        #expect(local.gasto.syncStatus == .synced)
        #expect(local.gasto.backendId == api.gastos.first?.id)
    }

    /// Antes dos 60 s o `proximaTentativaEm` é respeitado: nenhuma chamada.
    @Test func antesDeUmMinutoNaoTentaDeNovo() async throws {
        try criarViagemOffline()
        api.falhar(.postGasto, com: Self.limite)
        let agora = Date()
        _ = await sync(agora: agora)

        api.pararDeFalhar(.postGasto)
        api.limparChamadas()
        _ = await sync(agora: agora.addingTimeInterval(30))

        #expect(api.chamadas.isEmpty)
        #expect(try lerLocal().gasto.syncStatus == .pending)
    }

    /// 429 logo no POST da viagem: nenhuma chamada à API depois dele — nem o
    /// segundo ciclo da mesma etapa, nem dias/gastos/exclusões, nem as
    /// passadas seguintes — mesmo com `forcar: true`.
    @Test func limiteNaViagemParaTodasAsEtapasMesmoForcado() async throws {
        try criarViagemOffline()
        try criarViagemOffline()
        api.falhar(.postCiclo, com: Self.limite)

        _ = await sync(agora: .now, forcar: true)

        #expect(api.chamadas == [.postCiclo])
        #expect(api.ciclos.isEmpty && api.dias.isEmpty && api.gastos.isEmpty)
        let ctx = ModelContext(container)
        let ciclos = try ctx.fetch(FetchDescriptor<CicloSoftex>())
        #expect(ciclos.count == 2)
        for ciclo in ciclos {
            #expect(ciclo.syncStatus == .pending)
            #expect(ciclo.tentativas == 0)
            #expect(ciclo.syncError == nil)
        }
    }

    /// O outro 429 — `daily_ai_limit` (teto diário de IA) — continua no
    /// caminho antigo: conta tentativa, marca `.failed` e liga backoff.
    @Test func limiteDiarioIAContinuaFalha() async throws {
        try criarViagemOffline()
        api.falhar(.postGasto, com: APIError.serverError(
            message: "daily_ai_limit", requestId: "-", statusCode: 429))

        _ = await sync(agora: .now)

        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        let local = try lerLocal()
        #expect(local.gasto.syncStatus == .failed)
        #expect(local.gasto.tentativas == 1)
        #expect(local.gasto.syncError != nil)
        #expect(local.gasto.proximaTentativaEm != nil)
    }

    /// 500 continua no caminho antigo: `.failed` com backoff.
    @Test func erroQuinhentosContinuaFalha() async throws {
        try criarViagemOffline()
        api.falhar(.postGasto)  // erroSimulado: serverError 500

        _ = await sync(agora: .now)

        let local = try lerLocal()
        #expect(local.gasto.syncStatus == .failed)
        #expect(local.gasto.tentativas == 1)
        #expect(local.gasto.syncError != nil)
        #expect(local.gasto.proximaTentativaEm != nil)
    }
}
