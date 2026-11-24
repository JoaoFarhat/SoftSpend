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

    /// Viagem (ciclo + dia + gasto) já sincronizada; o log de chamadas é
    /// zerado: o que a montagem enviou não conta no teste.
    func subirViagem() async throws {
        try criarViagemOffline()
        #expect(await sync() == 0)
        try #require(api.gastos.count == 1)
        api.limparChamadas()
    }

    /// Item recusado pelo 429: `.pending`, sem erro na tela, tenta de novo
    /// daqui a 60 s (`agora` é o mesmo passado ao `sync`).
    func esperarAguardandoLimite(_ item: any Syncavel, desde agora: Date) {
        #expect(item.syncStatus == .pending)
        #expect(item.syncError == nil)
        #expect(item.proximaTentativaEm == agora.addingTimeInterval(60))
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

    /// `NSError` solto com `userInfo["statusCode"] = 429` não é o limite por
    /// minuto — nada no app cria esse erro (o 429 real chega sempre no
    /// `APIError.serverError`). Segue a falha comum: `.failed`, tentativa
    /// contada e backoff, sem ligar o freio do `sync`.
    @Test func nsErrorComStatusCode429ContinuaFalha() async throws {
        try criarViagemOffline()
        api.falhar(.postGasto, com: NSError(
            domain: "teste", code: 1, userInfo: ["statusCode": 429]))

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

    /// 429 no PUT da viagem (`sincronizarEdicaoCiclo`): a edição fica
    /// `.pending` sem contar tentativa e um dia novo pendente nem chega a
    /// ser enviado — o freio vale para as etapas seguintes.
    @Test func edicaoDaViagemRecusadaFicaPendingSemErro() async throws {
        try await subirViagem()

        // Como a tela faz ao editar: título novo, um dia a mais, tudo pending.
        let ctx = ModelContext(container)
        let ciclo = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        ciclo.titulo = "Chapada dos Guimarães"
        ciclo.syncStatus = .pending
        let diaNovo = DiaSoftex(
            data: Calendar.current.startOfDay(for: .now).addingTimeInterval(3 * 86400),
            saldo: 100
        )
        ctx.insert(diaNovo)
        diaNovo.ciclo = ciclo
        try ctx.save()

        api.falhar(.putCiclo, com: Self.limite)
        let agora = Date()
        let restantes = await sync(agora: agora, forcar: true)

        #expect(restantes == 2)
        #expect(api.chamadas == [.putCiclo])
        let ctx2 = ModelContext(container)
        let cicloFinal = try #require(try ctx2.fetch(FetchDescriptor<CicloSoftex>()).first)
        esperarAguardandoLimite(cicloFinal, desde: agora)
        #expect(cicloFinal.tentativas == 0)
        // O dia pendente nem foi tentado: segue `.pending`, sem hora marcada.
        let diaNovoId = diaNovo.id
        let diaFinal = try #require(try ctx2.fetch(FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.id == diaNovoId })).first)
        #expect(diaFinal.syncStatus == .pending)
        #expect(diaFinal.proximaTentativaEm == nil)
        #expect(diaFinal.tentativas == 0)
    }

    /// 429 no DELETE do comprovante (`syncComprovantes`): o gasto fica
    /// `.pending` sem contar tentativa e a remoção tenta de novo em 60 s.
    @Test func comprovanteRecusadoFicaPendingSemErro() async throws {
        try await subirViagem()

        // Como o `removerComprovante`: a remoção fica pendente (o arquivo
        // continua no servidor até o DELETE passar).
        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        gasto.comprovanteParaRemover = true
        gasto.syncStatus = .pending
        try ctx.save()

        api.falhar(.deleteComprovante, com: Self.limite)
        let agora = Date()
        let restantes = await sync(agora: agora, forcar: true)

        #expect(restantes == 1)
        #expect(api.chamadas == [.putGasto, .deleteComprovante])
        let local = try lerLocal()
        esperarAguardandoLimite(local.gasto, desde: agora)
        #expect(local.gasto.tentativas == 0)
        #expect(local.gasto.comprovanteParaRemover)
    }

    /// 429 no DELETE (`syncDeletions`): a exclusão fica `.pending` sem contar
    /// tentativa e o freio segura o segundo item do mesmo laço. Sem o erro,
    /// o sync seguinte (61 s depois) conclui as duas exclusões.
    @Test func exclusaoRecusadaFicaPendingSemErro() async throws {
        try await subirViagem()

        // Segundo gasto já no servidor; depois os dois marcados para apagar
        // (como o `deleteGasto`: tira do total, marca `deletadoEm` + pending).
        var ctx = ModelContext(container)
        let dia = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        ctx.insert(GastosDia(valor: 40, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()
        #expect(await sync() == 0)
        try #require(api.gastos.count == 2)
        api.limparChamadas()

        ctx = ModelContext(container)
        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>(sortBy: [SortDescriptor(\.criadoEm)]))
        try #require(gastos.count == 2)
        for gasto in gastos {
            gasto.dia?.ciclo?.gasto_total -= gasto.valor
            gasto.deletadoEm = .now
            gasto.syncStatus = .pending
        }
        try ctx.save()

        api.falhar(.deleteGasto, com: Self.limite)
        let agora = Date()
        _ = await sync(agora: agora, forcar: true)

        // O 429 no primeiro DELETE freia o laço: o segundo nem é tentado.
        #expect(api.chamadas == [.deleteGasto])
        #expect(api.gastos.count == 2)
        let locais = try ModelContext(container).fetch(
            FetchDescriptor<GastosDia>(sortBy: [SortDescriptor(\.criadoEm)]))
        esperarAguardandoLimite(locais[0], desde: agora)
        #expect(locais[0].tentativas == 0)
        #expect(locais[0].deletadoEm != nil)
        // Não alcançado: continua pendente, sem hora marcada.
        #expect(locais[1].syncStatus == .pending)
        #expect(locais[1].deletadoEm != nil)
        #expect(locais[1].proximaTentativaEm == nil)

        // Sem o erro, o sync seguinte conclui as duas exclusões.
        api.pararDeFalhar(.deleteGasto)
        api.limparChamadas()
        _ = await sync(agora: agora.addingTimeInterval(61), forcar: true)
        #expect(api.chamadas == [.deleteGasto, .deleteGasto])
        #expect(api.gastos.isEmpty)
        let finais = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        #expect(finais.allSatisfy { $0.syncStatus == .synced && $0.deletadoEm != nil })
    }

    /// 429 no POST de recuperação do T7 (item apagado sem `backendId`: o
    /// `syncDeletions` repete o POST para descobrir o id): também não é
    /// falha — a exclusão espera 60 s sem contar tentativa nova.
    @Test func recuperacaoDeIdRecusadaFicaPendingSemErro() async throws {
        try await subirViagem()

        // Gasto cujo POST foi atendido com a resposta perdida (tentativa
        // contada, sem backendId); o usuário o apaga antes do próximo sync.
        var ctx = ModelContext(container)
        let dia = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        ctx.insert(GastosDia(valor: 40, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()
        api.perderResposta(.postGasto)
        _ = await sync()
        try #require(api.gastos.count == 2)

        ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.titulo == "Jantar" })).first)
        try #require(gasto.backendId == nil && gasto.tentativas == 1)
        gasto.dia?.ciclo?.gasto_total -= gasto.valor
        gasto.deletadoEm = .now
        gasto.syncStatus = .pending
        try ctx.save()

        api.falhar(.postGasto, com: Self.limite)
        api.limparChamadas()
        let agora = Date()
        _ = await sync(agora: agora, forcar: true)

        // A recuperação do id foi recusada: nem o DELETE acontece — e a
        // exclusão só espera 60 s, sem falha.
        #expect(api.chamadas == [.postGasto])
        let final = try #require(try ModelContext(container).fetch(FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.titulo == "Jantar" })).first)
        esperarAguardandoLimite(final, desde: agora)
        #expect(final.tentativas == 1)  // fica a do POST perdido; nenhuma nova
        #expect(final.backendId == nil)
        #expect(final.deletadoEm != nil)
        #expect(api.gastos.count == 2)
    }
}
