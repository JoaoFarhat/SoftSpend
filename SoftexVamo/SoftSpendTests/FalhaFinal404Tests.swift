import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T4 de `docs/revisao-sync-offline-ios.md` (R4), com a decisão do usuário de
/// 12/11: 404 no POST/PUT de gasto ou no POST de dia quer dizer que o pai (dia
/// ou viagem) ou o próprio item foi apagado em outro aparelho. O item é
/// descartado no aparelho — some do banco e o valor sai do `gasto_total` da
/// viagem —, sem nenhuma requisição a mais. Itens guardados por versões
/// anteriores com `SyncActor.erroApagadoEmOutroAparelho` são descartados do
/// mesmo jeito no começo do `sync`. Erro 500 segue o backoff normal.
@MainActor
struct FalhaFinal404Tests {
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

    /// Ciclo → dia → gasto (R$ 25) criados e já sincronizados com o servidor
    /// falso, com `gasto_total` local de 25. O log de chamadas é zerado ao final.
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

        let ajuste = ModelContext(container)
        try cicloLocal(ajuste).gasto_total = 25
        try ajuste.save()
        api.limparChamadas()
    }

    /// `forcar: true` de propósito: nem o sync forçado pode reenviar um item
    /// descartado.
    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    func cicloLocal(_ ctx: ModelContext) throws -> CicloSoftex {
        try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
    }

    func diaLocal(_ ctx: ModelContext) throws -> DiaSoftex {
        try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
    }

    func diasLocais(_ ctx: ModelContext) throws -> [DiaSoftex] {
        try ctx.fetch(FetchDescriptor<DiaSoftex>())
    }

    func gastosLocais(_ ctx: ModelContext) throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    /// Como o `addGasto` faz: o gasto entra pendente e o valor soma no total.
    func novoGasto(_ titulo: String, valor: Decimal, no dia: DiaSoftex, ctx: ModelContext) throws -> GastosDia {
        let gasto = GastosDia(valor: valor, titulo: titulo, categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        try cicloLocal(ctx).gasto_total += valor
        return gasto
    }

    // MARK: Testes

    /// POST de gasto cujo dia foi apagado em outro aparelho: o servidor
    /// responde 404 e o gasto é descartado — some do aparelho e o valor sai do
    /// total, com uma única chamada (o próprio POST).
    @Test func postGasto404DescartaGasto() async throws {
        try await subirViagem()

        // Outro aparelho apagou o dia (leva o gasto "Almoço" junto, em cascata).
        let diaRemoto = try #require(api.dias.first)
        try await api.deleteDia(diaId: diaRemoto.id)
        api.limparChamadas()

        // Gasto novo, pendente, no dia local que ainda tem backendId.
        let ctx = ModelContext(container)
        _ = try novoGasto("Táxi", valor: 30, no: try diaLocal(ctx), ctx: ctx)
        try ctx.save()
        #expect(try cicloLocal(ModelContext(container)).gasto_total == 55)

        #expect(await sync() == 0)
        #expect(api.chamadas == [.postGasto])

        // Segundo sync (forçado): nenhuma requisição nova.
        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        let leitura = ModelContext(container)
        let gastos = try gastosLocais(leitura)
        #expect(gastos.map(\.titulo) == ["Almoço"])
        #expect(try cicloLocal(leitura).gasto_total == 25)
    }

    /// PUT de gasto que já não existe no servidor (apagado em outro
    /// aparelho): mesmo tratamento do POST — descartado, sem reenvio.
    @Test func putGasto404DescartaGasto() async throws {
        try await subirViagem()

        // Outro aparelho apagou o gasto; aqui o usuário o edita offline.
        let gastoRemoto = try #require(api.gastos.first)
        try await api.deleteGasto(gastoId: gastoRemoto.id)
        api.limparChamadas()

        // Como o editGasto faz: volta para pending com o valor novo e ajusta o total.
        let ctx = ModelContext(container)
        let gasto = try #require(gastosLocais(ctx).first)
        gasto.titulo = "Almoço caro"
        gasto.valor = 50
        gasto.syncStatus = .pending
        gasto.syncError = nil
        try cicloLocal(ctx).gasto_total += 25
        try ctx.save()

        #expect(await sync() == 0)
        #expect(api.chamadas == [.putGasto])

        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        let leitura = ModelContext(container)
        #expect(try gastosLocais(leitura).isEmpty)
        #expect(try diasLocais(leitura).count == 1)
        #expect(try cicloLocal(leitura).gasto_total == 0)
    }

    /// POST de dia cuja viagem foi apagada em outro aparelho: o dia é
    /// descartado com os gastos dele, e os gastos vivos saem do total. O gasto
    /// do dia novo nem chega a ser enviado (o dia nunca ganhou `backendId`).
    @Test func postDia404DescartaDiaEGastos() async throws {
        try await subirViagem()

        // Outro aparelho apagou a viagem inteira.
        let cicloRemoto = try #require(api.ciclos.first)
        try await api.deleteCiclo(cicloId: cicloRemoto.id)
        api.limparChamadas()

        // Dia novo, pendente, no ciclo local que ainda tem backendId, com um
        // gasto vivo (R$ 40) e um já apagado pelo usuário (R$ 10, fora do total).
        let ctx = ModelContext(container)
        let diaNovo = DiaSoftex(data: .now.addingTimeInterval(86400), saldo: 100)
        ctx.insert(diaNovo)
        diaNovo.ciclo = try cicloLocal(ctx)
        _ = try novoGasto("Hotel", valor: 40, no: diaNovo, ctx: ctx)
        let apagado = try novoGasto("Café", valor: 10, no: diaNovo, ctx: ctx)
        apagado.deletadoEm = .now
        try cicloLocal(ctx).gasto_total -= 10
        try ctx.save()
        #expect(try cicloLocal(ModelContext(container)).gasto_total == 65)

        #expect(await sync() == 0)
        #expect(api.chamadas == [.postDiasLote])

        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        let leitura = ModelContext(container)
        let dias = try diasLocais(leitura)
        #expect(dias.count == 1)
        #expect(dias.first?.backendId != nil)
        #expect(try gastosLocais(leitura).map(\.titulo) == ["Almoço"])
        #expect(try cicloLocal(leitura).gasto_total == 25)
    }

    /// Dia e gastos guardados por versões anteriores com a falha final por 404
    /// (`syncError == erroApagadoEmOutroAparelho`) são descartados no começo do
    /// `sync`, sem requisição. Um gasto antigo dentro de um dia antigo sai do
    /// total uma vez só.
    @Test func itensAntigosComFalhaFinalSaoDescartados() async throws {
        try await subirViagem()

        let ctx = ModelContext(container)
        // Gasto antigo num dia que continua valendo.
        let taxi = try novoGasto("Táxi", valor: 30, no: try diaLocal(ctx), ctx: ctx)
        taxi.syncStatus = .failed
        taxi.syncError = SyncActor.erroApagadoEmOutroAparelho

        // Dia antigo com um gasto comum (R$ 40) e um gasto também antigo (R$ 15).
        let diaAntigo = DiaSoftex(data: .now.addingTimeInterval(86400), saldo: 100)
        ctx.insert(diaAntigo)
        diaAntigo.ciclo = try cicloLocal(ctx)
        diaAntigo.syncStatus = .failed
        diaAntigo.syncError = SyncActor.erroApagadoEmOutroAparelho
        _ = try novoGasto("Hotel", valor: 40, no: diaAntigo, ctx: ctx)
        let cafe = try novoGasto("Café", valor: 15, no: diaAntigo, ctx: ctx)
        cafe.syncStatus = .failed
        cafe.syncError = SyncActor.erroApagadoEmOutroAparelho
        try ctx.save()
        #expect(try cicloLocal(ModelContext(container)).gasto_total == 110)

        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        let leitura = ModelContext(container)
        #expect(try diasLocais(leitura).count == 1)
        #expect(try gastosLocais(leitura).map(\.titulo) == ["Almoço"])
        #expect(try cicloLocal(leitura).gasto_total == 25)
    }

    /// Erro 500 não é terminal: segue o backoff (tentativas/proximaTentativaEm),
    /// conta como pendente e sobe quando o servidor volta.
    @Test func erro500SegueComBackoff() async throws {
        try await subirViagem()
        api.falhar(.postGasto)

        let ctx = ModelContext(container)
        let gastoNovo = GastosDia(valor: 30, titulo: "Táxi", categoria: .ALIMENTACAO, dia: try diaLocal(ctx))
        ctx.insert(gastoNovo)
        try ctx.save()

        #expect(await sync() == 1)
        #expect(api.chamadas == [.postGasto])

        var leitura = ModelContext(container)
        var gasto = try #require(gastosLocais(leitura).first { $0.titulo == "Táxi" })
        #expect(gasto.syncStatus == .failed)
        #expect(gasto.syncError != SyncActor.erroApagadoEmOutroAparelho)
        #expect(gasto.tentativas == 1)
        #expect(gasto.proximaTentativaEm != nil)

        api.pararDeFalhar(.postGasto)
        #expect(await sync() == 0)

        leitura = ModelContext(container)
        gasto = try #require(gastosLocais(leitura).first { $0.titulo == "Táxi" })
        #expect(gasto.syncStatus == .synced)
        #expect(gasto.backendId == api.gastos.last?.id)
    }
}
