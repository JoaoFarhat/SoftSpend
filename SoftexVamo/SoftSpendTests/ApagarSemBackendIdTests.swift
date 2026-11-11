import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T7 de `docs/revisao-sync-offline-ios.md` (R7): item apagado no aparelho que
/// ainda não tem `backendId`, mas cujo POST já foi tentado, pode existir no
/// servidor (a requisição foi atendida e a resposta se perdeu). O app marca
/// `deletadoEm` e o `syncDeletions` repete o POST com o mesmo `client_id` só
/// para descobrir o id e mandar o `DELETE`. Item nunca enviado sai só do
/// aparelho, sem requisição.
@MainActor
struct ApagarSemBackendIdTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    // MARK: Apoio

    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    func hoje(mais dias: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: dias, to: Calendar.current.startOfDay(for: .now))!
    }

    /// Viagem com um dia, criada localmente (nada enviado ainda).
    @discardableResult
    func criarViagem() throws -> CicloSoftex {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: hoje(), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        try ctx.save()
        return ciclo
    }

    /// Viagem com um dia já sincronizada; o log de chamadas é zerado.
    func subirViagem() async throws {
        try criarViagem()
        #expect(await sync() == 0)
        try #require(api.dias.count == 1)
        api.limparChamadas()
    }

    /// Abre a viagem num `CiclosViewModel` com um contexto novo (que enxerga
    /// o que o `SyncActor` salvou), como a tela faz.
    func viewModel() throws -> (CiclosViewModel, CicloSoftex) {
        let ctx = ModelContext(container)
        let ciclo = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.allCiclos = [ciclo]
        vm.atualCiclo = ciclo
        return (vm, ciclo)
    }

    func ciclosLocais() throws -> [CicloSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>())
    }

    func gastosLocais() throws -> [GastosDia] {
        try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
    }

    /// Estado de quem ficou com o POST "no ar": sem id, com a tentativa contada.
    func esperarRespostaPerdida(_ item: any Syncavel, backendId: Int?) {
        #expect(backendId == nil)
        #expect(item.syncStatus == .failed)
        #expect(item.tentativas == 1)
    }

    // MARK: Resposta perdida → o servidor termina sem o item

    /// Viagem: o POST foi atendido mas a resposta se perdeu; o usuário apaga a
    /// viagem. Ela fica marcada no aparelho e o sync descobre o id (POST com o
    /// mesmo client_id) e manda o DELETE.
    @Test func viagemComRespostaPerdidaSaiDoServidor() async throws {
        try criarViagem()
        api.perderResposta(.postCiclo)
        _ = await sync()
        try #require(api.ciclos.count == 1)
        let local = try #require(try ciclosLocais().first)
        esperarRespostaPerdida(local, backendId: local.backendId)

        let (vm, ciclo) = try viewModel()
        try await vm.deleteCiclo(ciclo: ciclo)

        // Não foi apagada só no aparelho: está marcada para o sync.
        let marcada = try #require(try ciclosLocais().first)
        #expect(marcada.deletadoEm != nil)

        api.limparChamadas()
        #expect(await sync() == 0)

        #expect(api.ciclos.isEmpty)
        #expect(api.chamadas == [.postCiclo, .deleteCiclo])
        let final = try #require(try ciclosLocais().first)
        #expect(final.syncStatus == .synced)
        #expect(final.backendId != nil)
    }

    /// Gasto: mesmo caso, pelo `deleteGasto`.
    @Test func gastoComRespostaPerdidaSaiDoServidor() async throws {
        try await subirViagem()
        let ctx = ModelContext(container)
        let dia = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        ctx.insert(GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()

        api.perderResposta(.postGasto)
        _ = await sync()
        try #require(api.gastos.count == 1)
        let local = try #require(try gastosLocais().first)
        esperarRespostaPerdida(local, backendId: local.backendId)

        let (vm, _) = try viewModel()
        try await vm.deleteGasto(gastoID: local.id)

        api.limparChamadas()
        #expect(await sync() == 0)

        #expect(api.gastos.isEmpty)
        #expect(api.chamadas == [.postGasto, .deleteGasto])
        let final = try #require(try gastosLocais().first)
        #expect(final.deletadoEm != nil)
        #expect(final.syncStatus == .synced)
    }

    /// Dia removido na edição da viagem (`editCiclo`) cujo POST se perdeu: o
    /// sync descobre o id e apaga; o outro dia fica.
    @Test func diaRemovidoNaEdicaoComRespostaPerdidaSaiDoServidor() async throws {
        try await subirViagem()
        let ctx = ModelContext(container)
        let ciclo = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        let diaNovo = DiaSoftex(data: hoje(mais: 1), saldo: 100)
        ctx.insert(diaNovo)
        diaNovo.ciclo = ciclo
        try ctx.save()

        api.perderResposta(.postDiasLote)
        _ = await sync()
        try #require(api.dias.count == 2)
        let diaPerdidoNoServidor = try #require(api.dias.last).id
        let diaQueFica = try #require(api.dias.first).id

        // A edição mantém só o primeiro dia.
        let (vm, aberto) = try viewModel()
        let cicloId = try #require(aberto.backendId)
        await vm.editCiclo(cicloId: cicloId, ciclo: aberto, dias: [DiaLoteRequest(clientId: UUID().uuidString, data: hoje())])

        api.limparChamadas()
        #expect(await sync() == 0)

        #expect(api.dias.map(\.id) == [diaQueFica])
        #expect(!api.dias.contains { $0.id == diaPerdidoNoServidor })
        #expect(api.chamadas.contains(.postDiasLote))
        #expect(api.chamadas.contains(.deleteDia))
    }

    /// Se a recuperação do id falhar (servidor fora), o item continua marcado,
    /// com backoff, e sai do servidor no sync seguinte.
    @Test func recuperacaoQueFalhaTentaDeNovo() async throws {
        try criarViagem()
        api.perderResposta(.postCiclo)
        _ = await sync()
        let (vm, ciclo) = try viewModel()
        try await vm.deleteCiclo(ciclo: ciclo)

        api.falhar(.postCiclo)
        api.limparChamadas()
        _ = await sync()
        #expect(api.chamadas == [.postCiclo])
        #expect(api.ciclos.count == 1)
        let marcada = try #require(try ciclosLocais().first)
        #expect(marcada.deletadoEm != nil)
        #expect(marcada.syncStatus == .failed)
        #expect(marcada.tentativas == 2)

        api.pararDeFalhar(.postCiclo)
        _ = await sync()
        #expect(api.ciclos.isEmpty)
    }

    // MARK: Nunca enviado → só no aparelho, sem requisição

    /// Viagem criada offline e nunca enviada: sai do aparelho na hora e o sync
    /// não faz nenhuma requisição.
    @Test func viagemNuncaEnviadaNaoGeraRequisicao() async throws {
        try criarViagem()
        let (vm, ciclo) = try viewModel()
        try await vm.deleteCiclo(ciclo: ciclo)

        #expect(try ciclosLocais().isEmpty)
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)
        #expect(api.ciclos.isEmpty)
    }

    /// Gasto nunca enviado (num dia já sincronizado): o sync só o dá como
    /// resolvido, sem requisição.
    @Test func gastoNuncaEnviadoNaoGeraRequisicao() async throws {
        try await subirViagem()
        let ctx = ModelContext(container)
        let dia = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        try ctx.save()
        let gastoId = gasto.id

        let (vm, _) = try viewModel()
        try await vm.deleteGasto(gastoID: gastoId)

        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)
        #expect(api.gastos.isEmpty)
        let final = try #require(try gastosLocais().first)
        #expect(final.deletadoEm != nil)
        #expect(final.syncStatus == .synced)
    }

    /// Regra do "talvez no servidor": só conta envio já tentado. A falha final
    /// por 404 (T4) fica de fora mesmo com tentativas — o pai não existe lá e o
    /// item, se chegou a ser criado, foi apagado junto.
    @Test func regraDoTalvezNoServidor() throws {
        let gasto = GastosDia(valor: 1, titulo: "x", categoria: .ALIMENTACAO, dia: nil)
        #expect(!gasto.podeTerSidoCriadoNoServidor)        // nunca enviado

        gasto.tentativas = 1
        #expect(gasto.podeTerSidoCriadoNoServidor)         // POST tentado

        gasto.tentativas = 0
        gasto.syncStatus = .failed
        gasto.syncError = "timeout"
        #expect(gasto.podeTerSidoCriadoNoServidor)         // falhou

        gasto.syncError = SyncActor.erroApagadoEmOutroAparelho
        gasto.tentativas = 1
        #expect(!gasto.podeTerSidoCriadoNoServidor)        // T4: 404 final
    }
}
