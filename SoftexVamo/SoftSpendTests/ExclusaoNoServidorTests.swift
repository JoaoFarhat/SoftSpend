import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T5 de `docs/revisao-sync-offline-ios.md` (R5): o que foi apagado em outro
/// aparelho some deste quando a lista do servidor vem completa. Nunca sai item
/// com alteração local (`pending`/`failed`/`deletadoEm`) nem com lista incompleta.
@MainActor
struct ExclusaoNoServidorTests {
    let container: ModelContainer
    let ctx: ModelContext
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

    func ciclo(_ backendId: Int?, status: SyncStatus = .synced) -> CicloSoftex {
        let c = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Viagem \(backendId ?? 0)", dias: []
        )
        c.backendId = backendId
        c.syncStatus = status
        ctx.insert(c)
        return c
    }

    func dia(_ backendId: Int, em c: CicloSoftex, offset: Int = 0) -> DiaSoftex {
        let data = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now))!
        let d = DiaSoftex(data: data, saldo: 100)
        d.backendId = backendId
        d.syncStatus = .synced
        ctx.insert(d)
        d.ciclo = c
        return d
    }

    @discardableResult
    func gasto(_ backendId: Int?, em d: DiaSoftex, status: SyncStatus = .synced) -> GastosDia {
        let g = GastosDia(valor: 10, titulo: "Gasto \(backendId ?? 0)", categoria: .ALIMENTACAO, dia: d)
        g.backendId = backendId
        g.syncStatus = status
        ctx.insert(g)
        return g
    }

    func respostaGasto(_ id: Int, dia: Int) -> GastosDiaResponse {
        GastosDiaResponse(
            id: id, clientId: nil, dia_id: dia, valor: 10, titulo: "Gasto \(id)",
            categoria: .ALIMENTACAO, comprovante_url: nil,
            openFinanceStatus: nil, openFinanceMatch: nil
        )
    }

    /// O dia do servidor, no formato da resposta de `GET /dias`.
    func diaDoServidor(_ d: DiaSoftex, gastos: [Int] = []) -> DiaSoftex {
        DiaSoftex(from: DiaSoftexResponse(
            id: d.backendId, clientId: d.clientId, data: d.data, saldo: d.saldo,
            gastos: gastos.map { respostaGasto($0, dia: d.backendId ?? 0) }
        ))
    }

    /// Um ciclo como vem de `fetchCicloResumo`.
    func cicloDoServidor(_ backendId: Int) -> CicloSoftex {
        let c = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Viagem \(backendId)", dias: []
        )
        c.backendId = backendId
        c.syncStatus = .synced
        return c
    }

    func viewModel(aberto c: CicloSoftex) -> CiclosViewModel {
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.allCiclos = [c]
        vm.atualCiclo = c
        return vm
    }

    func idsDeGastos() throws -> Set<UUID> { Set(try ctx.fetch(FetchDescriptor<GastosDia>()).map(\.id)) }
    func idsDeDias() throws -> Set<UUID> { Set(try ctx.fetch(FetchDescriptor<DiaSoftex>()).map(\.id)) }
    func idsDeCiclos() throws -> Set<UUID> { Set(try ctx.fetch(FetchDescriptor<CicloSoftex>()).map(\.id)) }

    // MARK: Gastos

    /// Gasto sincronizado que não veio na lista completa do dia foi apagado em
    /// outro aparelho: sai daqui. O que veio fica.
    @Test func gastoApagadoNoServidorSome() async throws {
        let c = ciclo(7)
        let d = dia(50, em: c)
        let apagado = gasto(5, em: d).id
        let mantido = gasto(6, em: d).id
        try ctx.save()

        let vm = viewModel(aberto: c)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(d, gastos: [6])] }

        let ids = try idsDeGastos()
        #expect(!ids.contains(apagado))
        #expect(ids.contains(mantido))
        #expect(try idsDeDias().contains(d.id))
    }

    /// Gasto com edição pendente, com falha ou com exclusão pendente nunca sai,
    /// mesmo ausente da lista do servidor; nem o gasto ainda sem `backendId`.
    @Test func gastoComAlteracaoLocalEhPreservado() async throws {
        let c = ciclo(7)
        let d = dia(50, em: c)
        let pendente = gasto(5, em: d, status: .pending).id
        let falhou = gasto(6, em: d, status: .failed).id
        let apagandoGasto = gasto(8, em: d)
        apagandoGasto.deletadoEm = .now
        let apagando = apagandoGasto.id
        let nuncaEnviado = gasto(nil, em: d, status: .pending).id
        try ctx.save()

        let vm = viewModel(aberto: c)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(d)] }

        #expect(try idsDeGastos() == [pendente, falhou, apagando, nuncaEnviado])
    }

    /// Lista de dias incompleta (teto de páginas): nenhum gasto sai.
    @Test func listaDeDiasIncompletaNaoApagaGasto() async throws {
        let c = ciclo(7)
        let d = dia(50, em: c)
        let g = gasto(5, em: d).id
        try ctx.save()

        let vm = viewModel(aberto: c)
        // Servidor que ignora o `skip`: sempre a mesma página cheia, sem o dia 50.
        await vm.carregarDiasDoServidor(cicloId: 7) { _, limit in
            (0..<limit).map { i in
                let dia = DiaSoftex(data: .now, saldo: 100)
                dia.backendId = 1 + i
                return dia
            }
        }

        #expect(try idsDeGastos().contains(g))
        #expect(try idsDeDias().contains(d.id))
    }

    /// Falha de rede no meio da busca: nada sai.
    @Test func falhaNaBuscaNaoApagaGasto() async throws {
        let c = ciclo(7)
        let d = dia(50, em: c)
        let g = gasto(5, em: d).id
        try ctx.save()

        let vm = viewModel(aberto: c)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in throw URLError(.notConnectedToInternet) }

        #expect(try idsDeGastos().contains(g))
    }

    /// Gasto movido para outro dia no outro aparelho não é tratado como apagado.
    @Test func gastoMovidoParaOutroDiaFica() async throws {
        let c = ciclo(7)
        let d1 = dia(50, em: c)
        let d2 = dia(51, em: c, offset: 1)
        let g = gasto(5, em: d1)
        try ctx.save()

        let vm = viewModel(aberto: c)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in
            [self.diaDoServidor(d1), self.diaDoServidor(d2, gastos: [5])]
        }

        #expect(try idsDeGastos() == [g.id])
        #expect(g.dia?.id == d2.id)
    }

    /// Dia apagado no servidor (com os gastos, em cascata lá): sai com os gastos
    /// sincronizados. O dia que tem gasto pendente fica, com o gasto.
    @Test func diaApagadoNoServidorSaiComOsGastos() async throws {
        let c = ciclo(7)
        let apagado = dia(50, em: c)
        let gastoApagado = gasto(5, em: apagado).id
        let comPendente = dia(51, em: c, offset: 1)
        let gastoPendente = gasto(nil, em: comPendente, status: .pending).id
        try ctx.save()
        let idApagado = apagado.id

        let vm = viewModel(aberto: c)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [] }

        let dias = try idsDeDias()
        let gastos = try idsDeGastos()
        #expect(dias == [comPendente.id])
        #expect(!dias.contains(idApagado))
        #expect(gastos == [gastoPendente])
        #expect(!gastos.contains(gastoApagado))
    }

    // MARK: Ciclos

    /// Com a lista de ciclos lida até o fim, o ciclo sincronizado que não veio
    /// nela sai, com os dias e gastos dele.
    @Test func cicloApagadoNoServidorSome() throws {
        let apagado = ciclo(1)
        let d = dia(50, em: apagado)
        gasto(5, em: d)
        let mantido = ciclo(2)
        try ctx.save()
        let idApagado = apagado.id

        let vm = viewModel(aberto: mantido)
        vm.iniciarLeituraDeCiclos()
        let removidos = vm.registrarPaginaDeCiclos([cicloDoServidor(2)], skip: 0, limit: 5)

        #expect(removidos == [idApagado])
        #expect(try idsDeCiclos() == [mantido.id])
        #expect(try idsDeDias().isEmpty)
        #expect(try idsDeGastos().isEmpty)
        #expect(vm.leituraDeCiclos == nil)
    }

    /// Ciclo pendente, com falha, com exclusão pendente ou com dia/gasto alterado
    /// no aparelho nunca sai.
    @Test func cicloComAlteracaoLocalEhPreservado() throws {
        let pendente = ciclo(1, status: .pending)
        let falhou = ciclo(2, status: .failed)
        let apagando = ciclo(3)
        apagando.deletadoEm = .now
        let comGastoPendente = ciclo(4)
        gasto(nil, em: dia(50, em: comGastoPendente), status: .pending)
        let comDiaPendente = ciclo(5)
        dia(51, em: comDiaPendente).syncStatus = .pending
        try ctx.save()
        let todos = try idsDeCiclos()

        let vm = viewModel(aberto: pendente)
        vm.iniciarLeituraDeCiclos()
        let removidos = vm.registrarPaginaDeCiclos([], skip: 0, limit: 5)

        #expect(removidos.isEmpty)
        #expect(try idsDeCiclos() == todos)
    }

    /// Página cheia (há mais páginas) não apaga nada; nem uma última página que
    /// chega com `skip` fora de sequência (outra página ficou sem ler).
    @Test func listaDeCiclosIncompletaNaoApaga() throws {
        let antigo = ciclo(1)
        try ctx.save()

        let vm = viewModel(aberto: antigo)
        vm.iniciarLeituraDeCiclos()
        let primeira = vm.registrarPaginaDeCiclos((10..<15).map(cicloDoServidor), skip: 0, limit: 5)
        #expect(primeira.isEmpty)
        #expect(try idsDeCiclos().contains(antigo.id))

        // Pulou a página de skip 5 (falha ou offline): a de skip 10 não serve.
        let ultima = vm.registrarPaginaDeCiclos([cicloDoServidor(20)], skip: 10, limit: 5)
        #expect(ultima.isEmpty)
        #expect(try idsDeCiclos().contains(antigo.id))
        #expect(vm.leituraDeCiclos == nil)
    }

    /// Sem leitura iniciada da primeira página, nenhuma página apaga nada.
    @Test func paginaSemLeituraIniciadaNaoApaga() throws {
        let antigo = ciclo(1)
        try ctx.save()

        let vm = viewModel(aberto: antigo)
        let removidos = vm.registrarPaginaDeCiclos([], skip: 0, limit: 5)

        #expect(removidos.isEmpty)
        #expect(try idsDeCiclos().contains(antigo.id))
    }

    /// Lida em várias páginas seguidas até a última: o ciclo ausente de todas sai.
    @Test func cicloApagadoSomeDepoisDeVariasPaginas() throws {
        let apagado = ciclo(1)
        let naSegundaPagina = ciclo(15)
        try ctx.save()
        let idApagado = apagado.id

        let vm = viewModel(aberto: naSegundaPagina)
        vm.iniciarLeituraDeCiclos()
        #expect(vm.registrarPaginaDeCiclos((10..<15).map(cicloDoServidor), skip: 0, limit: 5).isEmpty)
        let removidos = vm.registrarPaginaDeCiclos([cicloDoServidor(15)], skip: 5, limit: 5)

        #expect(removidos == [idApagado])
        let ids = try idsDeCiclos()
        #expect(!ids.contains(idApagado))
        #expect(ids.contains(naSegundaPagina.id))
        #expect(ids.count == 6)
    }

    /// Ciclo que o sync enviou DURANTE a leitura não era candidato e fica.
    @Test func cicloSincronizadoDuranteALeituraFica() throws {
        let novo = ciclo(nil, status: .pending)
        try ctx.save()

        let vm = viewModel(aberto: novo)
        vm.iniciarLeituraDeCiclos()
        novo.backendId = 99
        novo.syncStatus = .synced
        let removidos = vm.registrarPaginaDeCiclos([], skip: 0, limit: 5)

        #expect(removidos.isEmpty)
        #expect(try idsDeCiclos().contains(novo.id))
    }
}
