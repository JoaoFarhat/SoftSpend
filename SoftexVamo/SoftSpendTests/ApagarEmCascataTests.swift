import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// O servidor apaga os filhos junto com o pai (`dia_service.remover_dia` leva
/// os gastos do dia; o `DELETE` do ciclo leva tudo): item apagado debaixo de
/// pai apagado não manda `DELETE` próprio — conclui junto (`marcarSucesso`)
/// quando o delete do pai termina, em sucesso ou 404 da API. Se o pai falha,
/// os filhos ficam como estão e saem junto na próxima. Antes disso, encurtar
/// uma viagem com muitos gastos nos dias removidos fazia um `DELETE` por gasto
/// e esbarrava no limite por minuto (429), atrasando o sync inteiro.
@MainActor
struct ApagarEmCascataTests {
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

    /// Viagem com `qtdDias` dias e `gastosPorDia` gastos em cada um, já
    /// sincronizada com o servidor falso. O log de chamadas é zerado ao final.
    func subirViagem(qtdDias: Int, gastosPorDia: Int) async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 100 * Decimal(qtdDias), gasto_total: 0,
            periodo: "01/09 - 0\(qtdDias)/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let inicio = Calendar.current.startOfDay(for: .now)
        for i in 0..<qtdDias {
            let dia = DiaSoftex(data: inicio.addingTimeInterval(TimeInterval(86400 * i)), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = ciclo
            for j in 0..<gastosPorDia {
                ctx.insert(GastosDia(
                    valor: Decimal(10 * (j + 1)), titulo: "Gasto \(i)-\(j)",
                    categoria: .ALIMENTACAO, dia: dia
                ))
            }
        }
        try ctx.save()

        #expect(await sync() == 0)
        try #require(api.dias.count == qtdDias)
        try #require(api.gastos.count == qtdDias * gastosPorDia)
        api.limparChamadas()
    }

    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    func cicloLocal(_ ctx: ModelContext) throws -> CicloSoftex {
        try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
    }

    func diasLocais() throws -> [DiaSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<DiaSoftex>())
    }

    func gastosLocais() throws -> [GastosDia] {
        try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
    }

    /// Como o `editCiclo` faz ao tirar uma data da viagem: o dia e os gastos
    /// dele ganham `deletadoEm` e ficam `pending`, e os valores saem do total.
    func apagarDia(_ dia: DiaSoftex, doCiclo ciclo: CicloSoftex) {
        dia.deletadoEm = .now
        dia.syncStatus = .pending
        for gasto in dia.gastos where gasto.deletadoEm == nil {
            gasto.deletadoEm = .now
            gasto.syncStatus = .pending
            ciclo.gasto_total -= gasto.valor
        }
    }

    // MARK: Testes

    /// (a) Apagar um dia (encurtar a viagem): só sai o `DELETE` do dia — um
    /// pedido em vez de um por gasto — e dia e gastos marcados concluem juntos.
    @Test func diaApagadoNaoMandaDeleteDosGastos() async throws {
        try await subirViagem(qtdDias: 2, gastosPorDia: 3)

        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let diaApagado = try #require(ciclo.dias?.max { $0.data < $1.data })
        apagarDia(diaApagado, doCiclo: ciclo)
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.deleteDia])
        #expect(api.gastos.count == 3)  // os do dia que ficou

        // Contexto novo: enxerga o que o SyncActor gravou.
        let dias = try diasLocais()
        let gastos = try gastosLocais()
        #expect(dias.first { $0.deletadoEm != nil }?.syncStatus == .synced)
        #expect(gastos.count == 6)
        #expect(gastos.allSatisfy { $0.syncStatus == .synced })
        #expect(gastos.filter { $0.deletadoEm != nil }.count == 3)
    }

    /// (b) Se o `DELETE` do dia falha, os gastos apagados dele não viram
    /// `.synced`; sem a falha, concluem junto no sync seguinte.
    @Test func falhaNoDeleteDoDiaSeguraOsGastosAteConcluir() async throws {
        try await subirViagem(qtdDias: 2, gastosPorDia: 3)

        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let diaApagado = try #require(ciclo.dias?.max { $0.data < $1.data })
        apagarDia(diaApagado, doCiclo: ciclo)
        try ctx.save()

        api.falhar(.deleteDia)
        #expect(await sync() == 0)

        // O DELETE foi tentado e recusado; nenhum DELETE de gasto saiu e os
        // gastos apagados continuam como estavam (`pending`, sem `.synced`).
        #expect(api.chamadas == [.deleteDia])
        #expect(api.gastos.count == 6)
        let marcados = try gastosLocais().filter { $0.deletadoEm != nil }
        #expect(marcados.count == 3)
        #expect(marcados.allSatisfy { $0.syncStatus == .pending })
        #expect(try diasLocais().first { $0.deletadoEm != nil }?.syncStatus == .failed)

        api.pararDeFalhar(.deleteDia)
        api.limparChamadas()
        #expect(await sync() == 0)

        // Sem a falha, o mesmo DELETE do dia conclui e leva os gastos junto.
        #expect(api.chamadas == [.deleteDia])
        #expect(api.gastos.count == 3)
        #expect(try diasLocais().first { $0.deletadoEm != nil }?.syncStatus == .synced)
        #expect(try gastosLocais().allSatisfy { $0.syncStatus == .synced })
    }

    /// (c) Gasto apagado sozinho, com o dia vivo: o `DELETE` próprio continua
    /// saindo — a cascata só vale quando o pai também está apagado.
    @Test func gastoApagadoComDiaVivoMandaDeleteProprio() async throws {
        try await subirViagem(qtdDias: 2, gastosPorDia: 3)

        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let dia = try #require(ciclo.dias?.first)
        let gasto = try #require(dia.gastos.first)
        // Como o `deleteGasto` faz: tira do total, marca `deletadoEm` + pending.
        ciclo.gasto_total -= gasto.valor
        gasto.deletadoEm = .now
        gasto.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.deleteGasto])
        #expect(api.gastos.count == 5)
        #expect(api.dias.count == 2)
        #expect(try gastosLocais().first { $0.deletadoEm != nil }?.syncStatus == .synced)
    }

    /// (d) Viagem apagada com um dia e os gastos dele já marcados: só sai o
    /// `DELETE` da viagem e todo mundo apagado conclui junto.
    @Test func viagemApagadaMandaSoODeleteDaViagem() async throws {
        try await subirViagem(qtdDias: 2, gastosPorDia: 3)

        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        // Um dia já estava marcado (como o `editCiclo` deixa) quando a viagem
        // toda foi apagada — o `deleteCiclo` marca só a viagem.
        let diaApagado = try #require(ciclo.dias?.max { $0.data < $1.data })
        apagarDia(diaApagado, doCiclo: ciclo)
        ciclo.deletadoEm = .now
        ciclo.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.deleteCiclo])
        #expect(api.ciclos.isEmpty)
        #expect(api.dias.isEmpty)
        #expect(api.gastos.isEmpty)

        let leitura = ModelContext(container)
        #expect(try cicloLocal(leitura).syncStatus == .synced)
        let apagadosDias = try diasLocais().filter { $0.deletadoEm != nil }
        #expect(apagadosDias.allSatisfy { $0.syncStatus == .synced })
        let apagadosGastos = try gastosLocais().filter { $0.deletadoEm != nil }
        #expect(apagadosGastos.count == 3)
        #expect(apagadosGastos.allSatisfy { $0.syncStatus == .synced })
    }
}
