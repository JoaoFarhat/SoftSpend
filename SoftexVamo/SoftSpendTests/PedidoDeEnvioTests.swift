import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// O `pedirEnvio` de teste: conta os pedidos sem tocar no
/// `SyncManager.shared` — que iria para o banco do app hospedeiro com o
/// usuário do simulador.
final class ContadorEnvios {
    private(set) var chamadas = 0

    func registrar() { chamadas += 1 }

    /// Espera o `Task { await pedirEnvio() }` disparado pela operação rodar
    /// no MainActor quando o teste cede. Limitado: se o pedido não vier, o
    /// teste falha na contagem em vez de ficar travado.
    func aguardarUm() async {
        for _ in 0..<300 where chamadas == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Toda alteração local (criar, editar ou apagar viagem, gasto ou
/// comprovante) pede o envio uma vez: sem o `Task { await pedirEnvio() }`
/// no fim da operação, um gasto feito com internet só subiria na próxima
/// abertura da tela — e antes do `pedirEnvio` injetável nenhum teste notava
/// a chamada apagada.
@MainActor
struct PedidoDeEnvioTests {
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

    /// ViewModel de teste: offline e com o `pedirEnvio` que só conta.
    func viewModel(envios: ContadorEnvios) -> CiclosViewModel {
        let vm = CiclosViewModel(estaConectado: { false })
        vm.modelContext = ctx
        vm.pedirEnvio = { envios.registrar() }
        return vm
    }

    func hoje(mais dias: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: dias, to: Calendar.current.startOfDay(for: .now))!
    }

    /// Viagem já sincronizada (backendId 7) com um dia sincronizado (50).
    func viagemComDia() -> (CicloSoftex, DiaSoftex) {
        let ciclo = CicloSoftex(
            valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ciclo.backendId = 7
        ciclo.syncStatus = .synced
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: hoje(), saldo: 100)
        dia.backendId = 50
        dia.syncStatus = .synced
        ctx.insert(dia)
        dia.ciclo = ciclo
        return (ciclo, dia)
    }

    @discardableResult
    func gasto(em dia: DiaSoftex) -> GastosDia {
        let g = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(g)
        return g
    }

    // MARK: Viagem

    @Test func criarViagemPedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)

        try await vm.createNewCiclo(startDate: hoje(), endDate: hoje(mais: 2), totalValue: 300, titulo: "Cuiabá, MT")

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    @Test func editarViagemPedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (ciclo, _) = viagemComDia()
        vm.allCiclos = [ciclo]
        vm.atualCiclo = ciclo
        let edicao = CicloSoftex(valor_total: 300, gasto_total: 0, periodo: "01/09 - 03/09",
                                 diaria: 100, titulo: "Recife, PE", dias: nil)

        await vm.editCiclo(cicloId: 7, ciclo: edicao)

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    @Test func apagarViagemPedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (ciclo, _) = viagemComDia()
        vm.allCiclos = [ciclo]
        vm.atualCiclo = ciclo

        try await vm.deleteCiclo(ciclo: ciclo)

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    // MARK: Gasto

    @Test func criarGastoPedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (ciclo, dia) = viagemComDia()
        vm.atualCiclo = ciclo

        try await vm.createNewGasto(title: "Almoço", value: 25, dia: dia, categoria: .ALIMENTACAO)

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    @Test func editarGastoPedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (ciclo, dia) = viagemComDia()
        let gasto = gasto(em: dia)
        try ctx.save()
        vm.atualCiclo = ciclo

        try await vm.editGasto(gastoId: gasto.id, novoDia: dia, titulo: "Jantar",
                               value: 40, categoria: .ALIMENTACAO)

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    @Test func apagarGastoPedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (ciclo, dia) = viagemComDia()
        let gasto = gasto(em: dia)
        try ctx.save()
        vm.atualCiclo = ciclo

        try await vm.deleteGasto(gastoID: gasto.id)

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    // MARK: Comprovante

    @Test func anexarComprovantePedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (_, dia) = viagemComDia()
        let gasto = gasto(em: dia)
        try ctx.save()

        try await vm.anexarComprovante(gastoId: gasto.id, imageData: Data([1, 2, 3]))

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }

    @Test func removerComprovantePedeEnvioUmaVez() async throws {
        let envios = ContadorEnvios()
        let vm = viewModel(envios: envios)
        let (_, dia) = viagemComDia()
        let gasto = gasto(em: dia)
        gasto.comprovanteDataCriptografado = Data([1, 2, 3])
        try ctx.save()

        try await vm.removerComprovante(gastoId: gasto.id)

        await envios.aguardarUm()
        #expect(envios.chamadas == 1)
    }
}
