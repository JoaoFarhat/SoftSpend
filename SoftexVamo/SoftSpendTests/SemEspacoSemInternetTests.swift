import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// iPhone sem espaço (`BancoLocal.semEspacoNoDisco`, banco aberto só em
/// memória) **e** sem internet: o lançamento à mão gravava num banco que
/// some ao fechar o app e a tela mostrava o item como salvo. O atalho do
/// Apple Pay e o "Lançar" da fila já recusam nesse caso (ver
/// `FaltaDeEspacoBancoTests`); agora `createNewGasto`, `editGasto` e
/// `createNewCiclo` também recusam com `ErroSemEspaco`, antes de mexer no
/// `modelContext`. Com internet (o envio sobe o item) ou com espaço (o
/// banco grava de verdade), tudo segue como antes. `semEspaco` e
/// `estaConectado` entram pelo `init`, como no `PedidoDeEnvioTests`.
@MainActor
struct SemEspacoSemInternetTests {
    let container: ModelContainer
    let ctx: ModelContext

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    // MARK: Apoio

    /// ViewModel de teste com `semEspaco` e `estaConectado` injetados; o
    /// `pedirEnvio` neutro não dispara o `SyncManager.shared` (que iria
    /// para o banco do app hospedeiro com o usuário do simulador).
    func viewModel(semEspaco: Bool, conectado: Bool) -> CiclosViewModel {
        let vm = CiclosViewModel(estaConectado: { conectado }, semEspaco: { semEspaco })
        vm.modelContext = ctx
        vm.pedirEnvio = {}
        return vm
    }

    func hoje(mais dias: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: dias, to: Calendar.current.startOfDay(for: .now))!
    }

    /// Viagem com um dia no contexto e aberta no ViewModel, como a tela de
    /// lançamento deixa (`garantirAtual` + `atualCiclo`).
    @discardableResult
    func viagemAberta(no vm: CiclosViewModel) throws -> (CicloSoftex, DiaSoftex) {
        let ciclo = CicloSoftex(valor_total: 300, gasto_total: 0,
                                periodo: "01/09 - 03/09", diaria: 100,
                                titulo: "Cuiabá, MT", dias: nil)
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: hoje(), saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()
        vm.allCiclos = [ciclo]
        vm.atualCiclo = ciclo
        return (ciclo, dia)
    }

    /// Gasto já lançado no dia, para o `editGasto` ter o que editar.
    func gasto(em dia: DiaSoftex, no ciclo: CicloSoftex) throws -> GastosDia {
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        ciclo.gasto_total = 25
        try ctx.save()
        return gasto
    }

    // MARK: Sem espaço e sem internet: recusa antes de mexer no contexto

    @Test func criarGastoSemEspacoSemInternetRecusa() async throws {
        let vm = viewModel(semEspaco: true, conectado: false)
        let (ciclo, dia) = try viagemAberta(no: vm)

        await #expect(throws: ErroSemEspaco.self) {
            try await vm.createNewGasto(title: "Almoço", value: 25, dia: dia, categoria: .ALIMENTACAO)
        }
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
        #expect(ciclo.gasto_total == 0)
    }

    @Test func editarGastoSemEspacoSemInternetRecusa() async throws {
        let vm = viewModel(semEspaco: true, conectado: false)
        let (ciclo, dia) = try viagemAberta(no: vm)
        let gasto = try gasto(em: dia, no: ciclo)

        await #expect(throws: ErroSemEspaco.self) {
            try await vm.editGasto(gastoId: gasto.id, novoDia: dia, titulo: "Jantar",
                                   value: 40, categoria: .ALIMENTACAO)
        }
        #expect(gasto.titulo == "Almoço")
        #expect(gasto.valor == 25)
        #expect(dia.saldo == 100)
        #expect(ciclo.gasto_total == 25)
    }

    @Test func criarViagemSemEspacoSemInternetRecusa() async throws {
        let vm = viewModel(semEspaco: true, conectado: false)

        await #expect(throws: ErroSemEspaco.self) {
            try await vm.createNewCiclo(startDate: hoje(), endDate: hoje(mais: 2),
                                        totalValue: 300, titulo: "Cuiabá, MT")
        }
        #expect(try ctx.fetch(FetchDescriptor<CicloSoftex>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<DiaSoftex>()).isEmpty)
        #expect(vm.allCiclos.isEmpty)
    }

    // MARK: Sem espaço com internet: o envio garante, grava como sempre

    @Test func criarGastoSemEspacoComInternetGrava() async throws {
        let vm = viewModel(semEspaco: true, conectado: true)
        let (ciclo, dia) = try viagemAberta(no: vm)

        try await vm.createNewGasto(title: "Almoço", value: 25, dia: dia, categoria: .ALIMENTACAO)

        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        #expect(gastos[0].valor == 25)
        #expect(ciclo.gasto_total == 25)
    }

    @Test func editarGastoSemEspacoComInternetGrava() async throws {
        let vm = viewModel(semEspaco: true, conectado: true)
        let (ciclo, dia) = try viagemAberta(no: vm)
        let gasto = try gasto(em: dia, no: ciclo)

        try await vm.editGasto(gastoId: gasto.id, novoDia: dia, titulo: "Jantar",
                               value: 40, categoria: .ALIMENTACAO)

        #expect(gasto.titulo == "Jantar")
        #expect(gasto.valor == 40)
        #expect(ciclo.gasto_total == 40)
    }

    @Test func criarViagemSemEspacoComInternetGrava() async throws {
        let vm = viewModel(semEspaco: true, conectado: true)

        try await vm.createNewCiclo(startDate: hoje(), endDate: hoje(mais: 2),
                                    totalValue: 300, titulo: "Cuiabá, MT")

        let ciclos = try ctx.fetch(FetchDescriptor<CicloSoftex>())
        try #require(ciclos.count == 1)
        #expect(ciclos[0].titulo == "Cuiabá, MT")
        #expect(try ctx.fetch(FetchDescriptor<DiaSoftex>()).count == 3)
    }

    // MARK: Com espaço e sem internet: o banco grava de verdade, como sempre

    @Test func criarGastoComEspacoSemInternetGrava() async throws {
        let vm = viewModel(semEspaco: false, conectado: false)
        let (ciclo, dia) = try viagemAberta(no: vm)

        try await vm.createNewGasto(title: "Almoço", value: 25, dia: dia, categoria: .ALIMENTACAO)

        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        #expect(gastos[0].valor == 25)
        #expect(ciclo.gasto_total == 25)
    }

    @Test func editarGastoComEspacoSemInternetGrava() async throws {
        let vm = viewModel(semEspaco: false, conectado: false)
        let (ciclo, dia) = try viagemAberta(no: vm)
        let gasto = try gasto(em: dia, no: ciclo)

        try await vm.editGasto(gastoId: gasto.id, novoDia: dia, titulo: "Jantar",
                               value: 40, categoria: .ALIMENTACAO)

        #expect(gasto.titulo == "Jantar")
        #expect(gasto.valor == 40)
        #expect(ciclo.gasto_total == 40)
    }

    @Test func criarViagemComEspacoSemInternetGrava() async throws {
        let vm = viewModel(semEspaco: false, conectado: false)

        try await vm.createNewCiclo(startDate: hoje(), endDate: hoje(mais: 2),
                                    totalValue: 300, titulo: "Cuiabá, MT")

        let ciclos = try ctx.fetch(FetchDescriptor<CicloSoftex>())
        try #require(ciclos.count == 1)
        #expect(ciclos[0].titulo == "Cuiabá, MT")
        #expect(try ctx.fetch(FetchDescriptor<DiaSoftex>()).count == 3)
    }

    // MARK: Aviso na tela

    /// O formulário mostra o `localizedDescription` (`aviso` do rascunho,
    /// `erroSalvar` da nova viagem): a frase precisa dizer o que fazer.
    @Test func textoDoErro() {
        #expect(ErroSemEspaco().localizedDescription
            == "Sem espaço no iPhone e sem internet: o gasto se perderia ao fechar o app. Libere espaço ou conecte à internet.")
    }
}
