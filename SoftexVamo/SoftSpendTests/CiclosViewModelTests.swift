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
}
