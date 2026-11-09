import Testing
import Foundation
@testable import SoftSpend

@MainActor
struct ComponentesTests {
    let fuso = TimeZone(identifier: "America/Sao_Paulo")!

    func d(_ dia: Int, _ mes: Int = 7, _ hora: Int = 12, _ min: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = fuso
        return cal.date(from: DateComponents(year: 2026, month: mes, day: dia, hour: hora, minute: min))!
    }

    @Test func brlCurto() {
        #expect(formatarBRLCurto(450) == "R$ 450")
        #expect(formatarBRLCurto(Decimal(string: "147.7")!) == "R$ 147,70")
    }

    @Test func valorSemSimbolo() {
        #expect(formatarValorSemSimbolo(Decimal(string: "104.6")!) == "104,60")
    }

    @Test func horaComDoisDigitos() {
        #expect(horaCurta(d(23, 7, 8, 5), fuso: fuso) == "08:05")
        #expect(horaCurta(d(23, 7, 13, 42), fuso: fuso) == "13:42")
    }

    @Test func gastosSemFoto() {
        #expect(textoGastosSemFoto(1) == "1 gasto sem foto")
        #expect(textoGastosSemFoto(2) == "2 gastos sem foto")
    }

    @Test func acessibilidadeDaBarra() {
        let estourado = DiaResumo(id: d(21), data: d(21), gasto: 488, diaria: 450, ehHoje: false, futuro: false)
        #expect(textoAcessivelBarra(estourado, fuso: fuso) == "21 de julho, passou R$ 38")
        let futuro = DiaResumo(id: d(24), data: d(24), gasto: 0, diaria: 450, ehHoje: false, futuro: true)
        #expect(textoAcessivelBarra(futuro, fuso: fuso) == "24 de julho, ainda não chegou")
        let hoje = DiaResumo(id: d(23), data: d(23), gasto: Decimal(string: "147.7")!, diaria: 450, ehHoje: true, futuro: false)
        #expect(textoAcessivelBarra(hoje, fuso: fuso) == "Hoje, 23 de julho, gastou R$ 147,70")
    }

    @Test func periodo() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = fuso
        #expect(periodoPorExtenso(de: d(20), ate: d(25), calendario: cal) == "20 a 25 de julho")
        #expect(periodoPorExtenso(de: d(28), ate: d(2, 8), calendario: cal) == "28 de julho a 2 de agosto")
        #expect(periodoPorExtenso(de: d(20), ate: d(20), calendario: cal) == "20 de julho")
    }

    @Test func cidade() {
        #expect(nomeCidade("Cuiabá, MT") == "Cuiabá")
    }
}
