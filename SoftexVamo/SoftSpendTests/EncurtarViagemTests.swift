import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Aviso de "Encurtar a viagem?" (NewCicloView): a contagem é o que o
/// `editCiclo` apagaria — gastos vivos de dias vivos fora das novas datas.
@MainActor
struct EncurtarViagemTests {
    let container: ModelContainer
    let ctx: ModelContext
    let cal = Calendar.current

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    private func data(_ dia: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: dia, hour: 12))!
    }

    private func dia(_ d: Int) -> DiaSoftex {
        let dia = DiaSoftex(data: data(d), saldo: 100)
        ctx.insert(dia)
        return dia
    }

    private func gasto(em dia: DiaSoftex) -> GastosDia {
        let g = GastosDia(valor: 10, titulo: "Gasto", categoria: .OUTROS, dia: dia)
        ctx.insert(g)
        return g
    }

    @Test func semGastosNaoConta() {
        let dentro = dia(2)
        let fora = dia(6)
        _ = dentro
        _ = fora

        #expect(EncurtarViagem.gastosForaDoPeriodo(
            dias: [dentro, fora], ida: data(1), volta: data(4)) == 0)
    }

    @Test func gastoDentroDoPeriodoNaoConta() {
        let dentro = dia(3)
        _ = gasto(em: dentro)
        _ = gasto(em: dentro)

        #expect(EncurtarViagem.gastosForaDoPeriodo(
            dias: [dentro], ida: data(1), volta: data(4)) == 0)
    }

    @Test func gastoForaDoPeriodoConta() {
        let dentro = dia(2)
        let fora = dia(6)
        _ = gasto(em: dentro)
        _ = gasto(em: fora)
        _ = gasto(em: fora)

        #expect(EncurtarViagem.gastosForaDoPeriodo(
            dias: [dentro, fora], ida: data(1), volta: data(4)) == 2)
    }

    @Test func gastoJaApagadoNaoConta() {
        let fora = dia(6)
        _ = gasto(em: fora)
        let apagado = gasto(em: fora)
        apagado.deletadoEm = .now

        #expect(EncurtarViagem.gastosForaDoPeriodo(
            dias: [fora], ida: data(1), volta: data(4)) == 1)
    }

    @Test func diaJaApagadoNaoContaGastosDele() {
        let fora = dia(6)
        _ = gasto(em: fora)
        fora.deletadoEm = .now

        #expect(EncurtarViagem.gastosForaDoPeriodo(
            dias: [fora], ida: data(1), volta: data(4)) == 0)
    }

    @Test func diaDaVoltaEDiaDaIdaContamComoDentro() {
        let primeiro = dia(1)
        let ultimo = dia(4)
        _ = gasto(em: primeiro)
        _ = gasto(em: ultimo)

        #expect(EncurtarViagem.gastosForaDoPeriodo(
            dias: [primeiro, ultimo], ida: data(1), volta: data(4)) == 0)
    }
}
