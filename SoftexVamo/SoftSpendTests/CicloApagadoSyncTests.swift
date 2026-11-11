import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T8 de `docs/revisao-sync-offline-ios.md` (R8): apagar um ciclo não pode
/// fazer os filhos pendentes subirem nem ficarem contados como pendentes —
/// o `DELETE` do ciclo apaga tudo em cascata no servidor. `syncDias`,
/// `syncGastos`, `syncComprovantes` e `contarPendentes` ignoram itens cujo pai
/// tem `deletadoEm` (filtro em memória depois do fetch).
@MainActor
struct CicloApagadoSyncTests {
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

    /// Ciclo → dia → gasto criados e já sincronizados com o servidor falso.
    /// O log de chamadas é zerado ao final.
    func subirViagem() async throws {
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

        #expect(await sync() == 0)
        try #require(api.gastos.count == 1)
        api.limparChamadas()
    }

    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    func cicloLocal(_ ctx: ModelContext) throws -> CicloSoftex {
        try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
    }

    // MARK: Testes

    /// Cenário do R8: dia e gasto novos (`pending`, sem `backendId`) num ciclo
    /// que o usuário apaga. Antes, o sync subia os filhos e depois apagava o
    /// ciclo — lixo no servidor e `pendentesRestantes` errado. Agora só sai o
    /// `DELETE` do ciclo e o servidor apaga os filhos em cascata.
    @Test func apagarCicloNaoSobeFilhosPendentes() async throws {
        try await subirViagem()

        // Dia e gasto novos criados offline depois do sync.
        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let diaNovo = DiaSoftex(data: .now.addingTimeInterval(86400), saldo: 100)
        ctx.insert(diaNovo)
        diaNovo.ciclo = ciclo
        let gastoNovo = GastosDia(valor: 40, titulo: "Jantar", categoria: .ALIMENTACAO, dia: diaNovo)
        ctx.insert(gastoNovo)
        try ctx.save()

        // Como o `deleteCiclo` faz: marca só o ciclo — os filhos continuam vivos.
        ciclo.deletadoEm = .now
        ciclo.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        // Nenhum POST de dia/gasto: só o DELETE do ciclo.
        #expect(api.chamadas == [.deleteCiclo])
        #expect(api.ciclos.isEmpty)
        #expect(api.dias.isEmpty)
        #expect(api.gastos.isEmpty)

        // Os filhos pendentes ficam no aparelho — o `limparDadosMortos` os
        // remove junto com o ciclo — mas não contam como pendentes nem sobem.
        // (Contexto novo: o `ctx` da montagem pode ter cópias velhas do que o
        // SyncActor gravou.)
        let leitura = ModelContext(container)
        let diasLocais = try leitura.fetch(FetchDescriptor<DiaSoftex>())
        let gastosLocais = try leitura.fetch(FetchDescriptor<GastosDia>())
        #expect(diasLocais.count == 2)
        #expect(gastosLocais.count == 2)
        #expect(try cicloLocal(leitura).syncStatus == .synced)
        #expect(diasLocais.allSatisfy { $0.deletadoEm == nil })
        #expect(gastosLocais.contains { $0.syncStatus == .pending })
    }

    /// Gasto `pending` num dia que já tem `deletadoEm`: não sobe nem conta
    /// como pendente — o `DELETE` do dia resolve no servidor (cascata).
    @Test func gastoPendenteEmDiaApagadoNaoSobe() async throws {
        try await subirViagem()

        // Gasto novo, ainda não enviado, no dia já sincronizado.
        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let dia = try #require(ciclo.dias?.first)
        let gastoNovo = GastosDia(valor: 40, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gastoNovo)

        // Só o dia é marcado — o gasto novo continua `pending` e vivo.
        dia.deletadoEm = .now
        dia.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.deleteDia])
        #expect(api.dias.isEmpty)
        // O gasto novo nunca existiu no servidor; o que existia ("Almoço")
        // foi junto com o dia, em cascata.
        #expect(api.gastos.isEmpty)
        let leitura = ModelContext(container)
        let gastosLocais = try leitura.fetch(FetchDescriptor<GastosDia>())
        #expect(gastosLocais.count == 2)
        #expect(gastosLocais.first { $0.titulo == "Jantar" }?.backendId == nil)
    }
}
