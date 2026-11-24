import Testing
import Foundation
import SwiftData
@testable import SoftSpend

// Em série com as outras suítes do usuário global: ver `UsuarioGlobalTests`.
extension UsuarioGlobalTests {

/// O `gasto_total` da viagem não pode perder o que ainda não subiu. A leitura da
/// lista de viagens (`salvarOuAtualizarCicloLocal`) e a resposta do `PUT` da viagem
/// (`sincronizarEdicaoCiclo`) só copiam o total do servidor quando nenhum dia ou
/// gasto da viagem tem alteração local pendente (`CicloSoftex.temAlteracaoNaViagem`).
@MainActor
struct TotalDaViagemTests {
    let container: ModelContainer
    let ctx: ModelContext
    let api = FakeSyncAPI()
    /// O mesmo usuário que o `CiclosViewModel` usa para casar os ciclos.
    let userId: String

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        userId = AuthService.shared.currentUser?.id ?? ""
    }

    // MARK: Apoio

    /// Viagem já no servidor (`backendId` 7, `.synced`) com um dia sincronizado.
    func viagem(gastoTotal: Decimal) -> (CicloSoftex, DiaSoftex) {
        let c = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: gastoTotal,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        c.backendId = 7
        c.syncStatus = .synced
        ctx.insert(c)
        let d = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        d.backendId = 50
        d.syncStatus = .synced
        ctx.insert(d)
        d.ciclo = c
        return (c, d)
    }

    @discardableResult
    func gasto(_ valor: Decimal, em d: DiaSoftex, backendId: Int?, status: SyncStatus) -> GastosDia {
        let g = GastosDia(valor: valor, titulo: "Gasto \(valor)", categoria: .ALIMENTACAO, dia: d)
        g.backendId = backendId
        g.syncStatus = status
        ctx.insert(g)
        return g
    }

    /// A viagem como vem da lista do servidor, com o total que ele conhece.
    func cicloDoServidor(_ c: CicloSoftex, gastoTotal: Decimal) -> CicloSoftex {
        CicloSoftex(from: CicloResponse(
            id: c.backendId, clientId: c.clientId, valor_total: c.valor_total, gasto_total: gastoTotal,
            periodo: c.periodo, diaria: c.diaria, titulo: c.titulo, dias: nil
        ))
    }

    func lerViagem(_ c: CicloSoftex) {
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.salvarOuAtualizarCicloLocal(cicloDoServidor(c, gastoTotal: 100))
    }

    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    // MARK: Leitura da lista de viagens

    /// Gasto feito sem internet (50) ainda não subiu: o servidor diz 100, mas o
    /// total local (150) já o conta e fica.
    @Test func gastoPendenteMantemOTotalLocal() throws {
        let (c, d) = viagem(gastoTotal: 150)
        gasto(100, em: d, backendId: 5, status: .synced)
        gasto(50, em: d, backendId: nil, status: .pending)
        try ctx.save()

        lerViagem(c)

        #expect(c.gasto_total == 150)
        #expect(c.syncStatus == .synced)
    }

    /// Sem nada pendente, o total do servidor (mudado em outro aparelho) entra.
    @Test func semPendenciaOTotalDoServidorEntra() throws {
        let (c, d) = viagem(gastoTotal: 150)
        gasto(100, em: d, backendId: 5, status: .synced)
        try ctx.save()

        lerViagem(c)

        #expect(c.gasto_total == 100)
    }

    /// Gasto apagado no aparelho cujo `DELETE` ainda não subiu: o total local já
    /// o tirou (100); o servidor ainda o conta (100 + 50) e não pode trazê-lo de volta.
    @Test func gastoApagadoSemDeleteEnviadoMantemOTotalLocal() throws {
        let (c, d) = viagem(gastoTotal: 100)
        gasto(100, em: d, backendId: 5, status: .synced)
        let apagado = gasto(50, em: d, backendId: 6, status: .pending)
        apagado.deletadoEm = .now
        try ctx.save()

        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.salvarOuAtualizarCicloLocal(cicloDoServidor(c, gastoTotal: 150))

        #expect(c.gasto_total == 100)
    }

    /// Dia apagado no aparelho (com seu gasto) cujo `DELETE` ainda não subiu: idem.
    @Test func diaApagadoSemDeleteEnviadoMantemOTotalLocal() throws {
        let (c, _) = viagem(gastoTotal: 0)
        let outro = DiaSoftex(data: Calendar.current.startOfDay(for: .now).addingTimeInterval(86400), saldo: 100)
        outro.backendId = 51
        outro.syncStatus = .pending
        outro.deletadoEm = .now
        ctx.insert(outro)
        outro.ciclo = c
        let g = gasto(40, em: outro, backendId: 8, status: .pending)
        g.deletadoEm = .now
        try ctx.save()

        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.salvarOuAtualizarCicloLocal(cicloDoServidor(c, gastoTotal: 40))

        #expect(c.gasto_total == 0)
    }

    // MARK: Resposta do PUT da viagem

    /// Edição da viagem e gasto novo no mesmo `sync`: o `PUT` sobe antes do gasto
    /// e devolve o total sem ele. No fim, o total local é a soma dos gastos vivos.
    @Test func edicaoEGastoNovoNoMesmoSyncSomamOsGastosVivos() async throws {
        // Viagem com um gasto de 40, já toda no servidor falso.
        let montagem = ModelContext(container)
        let c = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 40,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        montagem.insert(c)
        let d = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        montagem.insert(d)
        d.ciclo = c
        montagem.insert(GastosDia(valor: 40, titulo: "Almoço", categoria: .ALIMENTACAO, dia: d))
        try montagem.save()
        #expect(await sync() == 0)
        try #require(api.gastos.count == 1)
        api.limparChamadas()

        // Como a tela faz: edita o título e lança um gasto de 60 sem internet.
        let tela = ModelContext(container)
        let ciclo = try #require(try tela.fetch(FetchDescriptor<CicloSoftex>()).first)
        let dia = try #require(ciclo.dias?.first)
        ciclo.titulo = "Goiânia, GO"
        ciclo.syncStatus = .pending
        tela.insert(GastosDia(valor: 60, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia))
        ciclo.gasto_total += 60
        try tela.save()

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.putCiclo))
        #expect(api.chamadas.contains(.postGasto))
        #expect(api.ciclos.first?.titulo == "Goiânia, GO")

        let leitura = ModelContext(container)
        let depois = try #require(try leitura.fetch(FetchDescriptor<CicloSoftex>()).first)
        let vivos = (depois.dias ?? []).flatMap(\.gastos).filter { $0.deletadoEm == nil }
        #expect(vivos.count == 2)
        #expect(depois.gasto_total == vivos.reduce(Decimal(0)) { $0 + $1.valor })
        #expect(depois.gasto_total == 100)
        #expect(depois.syncStatus == .synced)
    }
}

}
