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
}
