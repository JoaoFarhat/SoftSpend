import Testing
import Foundation
import SwiftData
@testable import SoftSpend

@MainActor
struct CiclosViewModelTests {
    let container: ModelContainer
    let ctx: ModelContext

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test func editarGastoPodePassarDaDiaria() async throws {
        let ciclo = CicloSoftex(valor_total: 2700, gasto_total: dec("43.10"), periodo: "", diaria: 450, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: dec("406.90"))
        ctx.insert(dia)
        dia.ciclo = ciclo
        let gasto = GastosDia(valor: dec("43.10"), titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)

        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.atualCiclo = ciclo

        try await vm.editGasto(gastoId: gasto.id, novoDia: dia, titulo: "Almoço", value: dec("600.00"), categoria: .ALIMENTACAO)

        #expect(gasto.valor == dec("600.00"))
        #expect(dia.saldo == dec("-150.00"))
    }

    // MARK: Carregamento dos dias da viagem

    func viagem(periodo: String = "20/07 - 25/07", backendId: Int?) -> CicloSoftex {
        let c = CicloSoftex(valor_total: 600, gasto_total: 0, periodo: periodo, diaria: 100, titulo: "Cuiabá, MT", dias: [])
        c.backendId = backendId
        ctx.insert(c)
        return c
    }

    func diasNoBanco() throws -> [DiaSoftex] {
        try ctx.fetch(FetchDescriptor<DiaSoftex>())
    }

    /// Viagem já sincronizada sem dias locais: os dias vêm do servidor, nunca
    /// recriados com clientIds novos (que subiriam como duplicatas).
    @Test func abrirViagemSincronizadaSemDiasNaoRecriaDias() throws {
        let c = viagem(backendId: 42)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.allCiclos = [c]

        vm.abrirViagem(c)
        vm.reset()

        #expect(try diasNoBanco().isEmpty)
    }

    /// Viagem criada offline (nunca sincronizada) continua sendo recuperada
    /// pelo `periodo` para dar para lançar gastos.
    @Test func abrirViagemNuncaSincronizadaRecriaDiasPeloPeriodo() throws {
        let c = viagem(backendId: nil)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.allCiclos = [c]

        vm.abrirViagem(c)

        #expect(try diasNoBanco().count == 6)
        #expect(vm.atualCiclo.dias?.count == 6)
    }

    /// Viagem com mais de 20 dias: todas as páginas do servidor são buscadas.
    @Test func carregaTodasAsPaginasDeDias() async throws {
        let c = viagem(periodo: "01/07 - 14/08", backendId: 7)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.allCiclos = [c]
        vm.atualCiclo = c
        let inicio = Calendar.current.startOfDay(for: .now)
        var pedidos: [Int] = []

        await vm.carregarDiasDoServidor(cicloId: 7) { skip, limit in
            pedidos.append(skip)
            return (skip..<min(skip + limit, 45)).map { i in
                let dia = DiaSoftex(data: Calendar.current.date(byAdding: .day, value: i, to: inicio)!, saldo: 100)
                dia.backendId = 1000 + i
                dia.syncStatus = .synced
                return dia
            }
        }

        #expect(pedidos == [0, 20, 40])
        #expect(try diasNoBanco().count == 45)
        #expect(vm.atualCiclo.dias?.count == 45)
    }

    /// Um dia sincronizado que sumiu do servidor deixa de aparecer; um dia
    /// ainda não enviado fica.
    @Test func diaQueSumiuDoServidorSaiEDiaPendenteFica() async throws {
        let c = viagem(backendId: 7)
        let antigo = DiaSoftex(data: .now, saldo: 100)
        antigo.backendId = 999
        antigo.syncStatus = .synced
        ctx.insert(antigo)
        antigo.ciclo = c
        let pendente = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(pendente)
        pendente.ciclo = c
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.atualCiclo = c

        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in
            let dia = DiaSoftex(data: .now, saldo: 100)
            dia.backendId = 1
            return [dia]
        }

        let ids = Set(try diasNoBanco().map(\.id))
        #expect(!ids.contains(antigo.id))
        #expect(ids.contains(pendente.id))
        #expect(ids.count == 2)
    }

    func diaSincronizado(_ backendId: Int, em c: CicloSoftex) -> DiaSoftex {
        let dia = DiaSoftex(data: .now, saldo: 100)
        dia.backendId = backendId
        dia.syncStatus = .synced
        ctx.insert(dia)
        dia.ciclo = c
        return dia
    }

    /// Dia com gastos nunca é apagado pela limpeza: o delete em cascata
    /// levaria os gastos junto.
    @Test func diaComGastosQueSumiuDoServidorFica() async throws {
        let c = viagem(backendId: 7)
        let dia = diaSincronizado(999, em: c)
        let gasto = GastosDia(valor: 10, titulo: "Café", categoria: .ALIMENTACAO, dia: dia)
        gasto.syncStatus = .synced
        ctx.insert(gasto)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.atualCiclo = c

        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [] }

        #expect(try diasNoBanco().map(\.id).contains(dia.id))
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).count == 1)
    }

    /// Se o teto de páginas for atingido, a lista do servidor está incompleta
    /// e nada é apagado.
    @Test func tetoDePaginasNaoApagaDias() async throws {
        let c = viagem(backendId: 7)
        let antigo = diaSincronizado(999, em: c)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.atualCiclo = c

        // Servidor que ignora o `skip`: sempre a mesma página cheia.
        await vm.carregarDiasDoServidor(cicloId: 7) { _, limit in
            (0..<limit).map { i in
                let dia = DiaSoftex(data: .now, saldo: 100)
                dia.backendId = 1 + i
                return dia
            }
        }

        #expect(try diasNoBanco().map(\.id).contains(antigo.id))
    }

    /// Um dia enviado pelo sync DURANTE a busca não estava sincronizado no
    /// começo dela: não é candidato e fica.
    @Test func diaSincronizadoDuranteABuscaFica() async throws {
        let c = viagem(backendId: 7)
        let novo = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(novo)
        novo.ciclo = c
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.atualCiclo = c

        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in
            // O SyncActor sobe o dia enquanto a resposta (sem ele) chega.
            novo.backendId = 555
            novo.syncStatus = .synced
            return []
        }

        #expect(try diasNoBanco().map(\.id).contains(novo.id))
    }

    /// Busca pedida para outra viagem que não a aberta não grava nem apaga nada.
    @Test func buscaDeOutraViagemNaoMexeNaAberta() async throws {
        let c = viagem(backendId: 7)
        let antigo = diaSincronizado(999, em: c)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.atualCiclo = c
        var chamadas = 0

        await vm.carregarDiasDoServidor(cicloId: 8) { _, _ in
            chamadas += 1
            return []
        }

        #expect(chamadas == 0)
        #expect(try diasNoBanco().map(\.id) == [antigo.id])
    }
}
