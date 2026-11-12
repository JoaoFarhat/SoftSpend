import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T4 de `docs/revisao-sync-offline-ios.md` (R4): 404 no POST/PUT de gasto ou
/// no POST de dia é falha final — o pai (dia ou viagem) ou o próprio item foi
/// apagado em outro aparelho. O item fica `.failed` com o texto fixo
/// `SyncActor.erroApagadoEmOutroAparelho`, sem mexer em `tentativas`/
/// `proximaTentativaEm`: continua no aparelho, sai do `contarPendentes` e não
/// é reenviado. Erro 500 segue o backoff normal.
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

    /// `forcar: true` de propósito: nem o sync forçado pode reenviar um item
    /// com falha final por 404.
    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    /// Sync em background, para mexer no item com a requisição parada no `Portao`.
    func iniciarSync() -> Task<Int, Never> {
        let syncActor = SyncActor(modelContainer: container, api: api)
        let usuario = userId
        return Task { await syncActor.sync(agora: .now, userId: usuario, forcar: true) }
    }

    func cicloLocal(_ ctx: ModelContext) throws -> CicloSoftex {
        try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
    }

    func diaLocal(_ ctx: ModelContext) throws -> DiaSoftex {
        try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
    }

    func gastosLocais(_ ctx: ModelContext) throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    /// As quatro garantias da falha final por 404.
    func esperarFalhaFinal(_ item: any Syncavel) {
        #expect(item.syncStatus == .failed)
        #expect(item.syncError == SyncActor.erroApagadoEmOutroAparelho)
        #expect(item.tentativas == 0)
        #expect(item.proximaTentativaEm == nil)
    }

    // MARK: Testes

    /// POST de gasto cujo dia foi apagado em outro aparelho: o servidor
    /// responde 404 e o gasto vira falha final — fica no aparelho, fora da
    /// contagem e nunca mais é enviado.
    @Test func postGasto404ViraFalhaFinal() async throws {
        try await subirViagem()

        // Outro aparelho apagou o dia (leva o gasto "Almoço" junto, em cascata).
        let diaRemoto = try #require(api.dias.first)
        try await api.deleteDia(diaId: diaRemoto.id)
        api.limparChamadas()

        // Gasto novo, pendente, no dia local que ainda tem backendId.
        let ctx = ModelContext(container)
        let gastoNovo = GastosDia(valor: 30, titulo: "Táxi", categoria: .ALIMENTACAO, dia: try diaLocal(ctx))
        ctx.insert(gastoNovo)
        try ctx.save()

        // 404 → falha final: não conta como pendente.
        #expect(await sync() == 0)
        #expect(api.chamadas == [.postGasto])

        // Segundo sync (forçado): nenhuma requisição nova.
        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        // Continua no aparelho, com o estado de falha final.
        let leitura = ModelContext(container)
        let gastos = try gastosLocais(leitura)
        #expect(gastos.count == 2)
        esperarFalhaFinal(try #require(gastos.first { $0.titulo == "Táxi" }))
    }

    /// PUT de gasto que já não existe no servidor (apagado em outro
    /// aparelho): mesmo tratamento do POST — falha final, sem reenvio.
    @Test func putGasto404ViraFalhaFinal() async throws {
        try await subirViagem()

        // Outro aparelho apagou o gasto; aqui o usuário o edita offline.
        let gastoRemoto = try #require(api.gastos.first)
        try await api.deleteGasto(gastoId: gastoRemoto.id)
        api.limparChamadas()

        // Como o editGasto faz: volta para pending com o valor novo.
        let ctx = ModelContext(container)
        let gasto = try #require(gastosLocais(ctx).first)
        gasto.titulo = "Almoço caro"
        gasto.valor = 50
        gasto.syncStatus = .pending
        gasto.syncError = nil
        try ctx.save()

        #expect(await sync() == 0)
        #expect(api.chamadas == [.putGasto])

        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        let leitura = ModelContext(container)
        let gastos = try gastosLocais(leitura)
        #expect(gastos.count == 1)
        esperarFalhaFinal(try #require(gastos.first))
    }

    /// Editar o gasto com o PUT em voo e o PUT responder 404 (o gasto foi
    /// apagado em outro aparelho): a edição durante o envio não evita a falha
    /// final — o valor novo fica no aparelho, o `gasto_total` (que a própria
    /// edição já ajustou) não muda de novo e nada é reenviado.
    @Test func editarDuranteOEnvio404ViraFalhaFinal() async throws {
        try await subirViagem()

        // Outro aparelho apagou o gasto; aqui o usuário o edita e ele volta
        // para pending, como o editGasto faz (valor e total já novos).
        let gastoRemoto = try #require(api.gastos.first)
        try await api.deleteGasto(gastoId: gastoRemoto.id)
        api.limparChamadas()

        let put = api.segurar(.putGasto)
        let ctx = ModelContext(container)
        let gasto = try #require(gastosLocais(ctx).first)
        gasto.valor = 40
        gasto.syncStatus = .pending
        try cicloLocal(ctx).gasto_total = 40
        try ctx.save()

        let tarefa = iniciarSync()
        await put.aguardarChegada()

        // Outra edição com o PUT em voo (também ajusta o total local uma vez).
        let durante = ModelContext(container)
        let emVoo = try #require(gastosLocais(durante).first)
        emVoo.titulo = "Almoço caro"
        emVoo.valor = 50
        try cicloLocal(durante).gasto_total += 10
        try durante.save()

        await put.liberar()
        #expect(await tarefa.value == 0)
        #expect(api.chamadas == [.putGasto])

        // Falha final com a última edição preservada: o valor novo conta uma
        // vez só no total e o item não é reenviado.
        let leitura = ModelContext(container)
        let gastos = try gastosLocais(leitura)
        #expect(gastos.count == 1)
        let atual = try #require(gastos.first)
        esperarFalhaFinal(atual)
        #expect(atual.valor == 50)
        #expect(try cicloLocal(leitura).gasto_total == 50)

        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)
    }

    /// POST de dia cuja viagem foi apagada em outro aparelho: falha final.
    @Test func postDia404ViraFalhaFinal() async throws {
        try await subirViagem()

        // Outro aparelho apagou a viagem inteira.
        let cicloRemoto = try #require(api.ciclos.first)
        try await api.deleteCiclo(cicloId: cicloRemoto.id)
        api.limparChamadas()

        // Dia novo, pendente, no ciclo local que ainda tem backendId.
        let ctx = ModelContext(container)
        let diaNovo = DiaSoftex(data: .now.addingTimeInterval(86400), saldo: 100)
        ctx.insert(diaNovo)
        diaNovo.ciclo = try cicloLocal(ctx)
        try ctx.save()

        #expect(await sync() == 0)
        #expect(api.chamadas == [.postDiasLote])

        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)

        let leitura = ModelContext(container)
        let dias = try leitura.fetch(FetchDescriptor<DiaSoftex>())
        #expect(dias.count == 2)
        esperarFalhaFinal(try #require(dias.first { $0.backendId == nil }))
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
