import Testing
import Foundation
import SwiftData
@testable import SoftSpend

@MainActor
struct ResumoViagemTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }()
    let container: ModelContainer
    let ctx: ModelContext

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    func d(_ s: String, _ hora: Int = 10, _ min: Int = 0) -> Date {
        let p = s.split(separator: "/").map { Int($0)! }
        return cal.date(from: DateComponents(year: 2026, month: p[1], day: p[0], hour: hora, minute: min))!
    }
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    /// Ciclo com um dia por data entre `ini` e `fim` (dias do mês `mes`).
    func ciclo(titulo: String = "Cuiabá, MT", de ini: Int, ate fim: Int, mes: Int = 7,
               total: Decimal = 2700, diaria: Decimal = 450) -> CicloSoftex {
        let c = CicloSoftex(valor_total: total, gasto_total: 0, periodo: "", diaria: diaria, titulo: titulo, dias: [])
        ctx.insert(c)
        for n in ini...fim {
            let dia = DiaSoftex(data: d("\(n)/\(mes)"), saldo: diaria)
            ctx.insert(dia)
            dia.ciclo = c
        }
        return c
    }
    func dia(_ c: CicloSoftex, _ n: Int) -> DiaSoftex {
        c.dias!.first { cal.component(.day, from: $0.data) == n }!
    }
    @discardableResult
    func gasto(_ valor: String, em dia: DiaSoftex, comprovante: Bool = false, deletado: Bool = false) -> GastosDia {
        let g = GastosDia(valor: dec(valor), titulo: "x", categoria: .ALIMENTACAO, dia: dia,
                          comprovanteUrl: comprovante ? "https://x/y.jpg" : nil)
        ctx.insert(g)
        if deletado { g.deletadoEm = d("23/07") }
        return g
    }
    func cuiaba() -> CicloSoftex {
        let c = ciclo(de: 20, ate: 25)
        gasto("488.00", em: dia(c, 21), comprovante: true)
        gasto("412.00", em: dia(c, 22), comprovante: true)
        gasto("43.10", em: dia(c, 23), comprovante: true)
        gasto("104.60", em: dia(c, 23))
        return c
    }
    func resumo(_ c: CicloSoftex?, _ hoje: String) -> ResumoViagem {
        ResumoViagem(ciclo: c, hoje: d(hoje), calendario: cal)
    }

    @Test func livreHoje() {
        let r = resumo(cuiaba(), "23/07")
        #expect(r.livreHoje == dec("302.30")); #expect(r.gastoHoje == dec("147.70"))
    }
    @Test func estadoDurante() { #expect(resumo(cuiaba(), "23/07").estado == .durante(dia: 4, de: 6)) }
    @Test func barras() {
        let r = resumo(cuiaba(), "23/07")
        #expect(r.dias.count == 6)
        #expect(r.dias[1].estourou && r.dias[1].passou == 38)
        #expect(r.dias[3].ehHoje)
        #expect(r.dias[4].futuro && r.dias[5].futuro)
        #expect(!r.dias[3].futuro && !r.dias[0].ehHoje)
        #expect(r.diasEstourados == 1)
        #expect(r.gastoTotal == dec("1047.70")); #expect(r.total == 2700); #expect(r.diaria == 450)
    }
    @Test func proporcaoLimitada() {
        let c = ciclo(de: 20, ate: 21)
        gasto("900", em: dia(c, 21))
        let r = resumo(c, "23/07")
        #expect(r.dias[0].proporcao == 0)
        #expect(r.dias[1].proporcao == 1.25)
        let c2 = ciclo(de: 20, ate: 21)
        gasto("225", em: dia(c2, 20))
        #expect(resumo(c2, "23/07").dias[0].proporcao == 0.5)
    }
    @Test func pendencias() { #expect(resumo(cuiaba(), "23/07").semComprovante.count == 1) }
    @Test func deletadoNaoContaEmNada() {
        let c = cuiaba()
        gasto("999", em: dia(c, 23), deletado: true)
        let r = resumo(c, "23/07")
        #expect(r.gastoHoje == dec("147.70")); #expect(r.semComprovante.count == 1)
    }
    @Test func antes() { #expect(resumo(cuiaba(), "17/07").estado == .antes(diasFaltando: 3)) }
    @Test func encerrada() { #expect(resumo(cuiaba(), "26/07").estado == .encerrada) }
    @Test func semViagem() {
        #expect(resumo(nil, "23/07").estado == .semViagem)
        #expect(resumo(.vazio, "23/07").estado == .semViagem)
    }
    @Test func diariaZero() {
        let c = ciclo(de: 23, ate: 23, total: 0, diaria: 0)
        gasto("10", em: dia(c, 23))
        let r0 = resumo(c, "23/07")
        #expect(r0.dias[0].proporcao == 0); #expect(r0.livreHoje == -10)
        // Sem diária não há dia "estourado" (como em Todos os gastos).
        #expect(!r0.dias[0].estourou); #expect(r0.diasEstourados == 0)
    }
    @Test func remocaoPendenteDoComprovanteContaComoSemComprovante() {
        let c = ciclo(de: 23, ate: 23)
        let g = gasto("10", em: dia(c, 23), comprovante: true)
        g.comprovanteParaRemover = true
        #expect(resumo(c, "23/07").semComprovante.count == 1)
    }
    /// Instalação nova: as viagens chegam sem dias locais; o início escolhe
    /// pelo `periodo`, não pela primeira da lista.
    @Test func cicloDoInicioUsaOPeriodoQuandoNaoHaDias() {
        let antigo = ciclo(titulo: "Antigo", de: 1, ate: 5, mes: 6)
        let semDias = CicloSoftex(valor_total: 600, gasto_total: 0, periodo: "20/07 - 25/07",
                                  diaria: 100, titulo: "Cuiabá, MT", dias: [])
        semDias.criadoEm = d("01/07")
        ctx.insert(semDias)
        let futuroSemDias = CicloSoftex(valor_total: 600, gasto_total: 0, periodo: "10/08 - 12/08",
                                        diaria: 100, titulo: "Belém, PA", dias: [])
        futuroSemDias.criadoEm = d("01/07")
        ctx.insert(futuroSemDias)
        #expect(cicloDoInicio([antigo, futuroSemDias, semDias], hoje: d("23/07"), calendario: cal) === semDias)
        #expect(cicloDoInicio([antigo, futuroSemDias], hoje: d("23/07"), calendario: cal) === futuroSemDias)
    }
    @Test func diaFaltandoNoCicloViraDiaVazio() {
        let c = ciclo(de: 20, ate: 25)
        ctx.delete(dia(c, 22))
        let r = resumo(c, "23/07")
        #expect(r.dias.count == 6); #expect(r.dias[2].gasto == 0)
    }
    @Test func gastoAs2350ContaNoDia() {
        let c = ciclo(de: 20, ate: 25)
        let tarde = dia(c, 22)
        tarde.data = d("22/07", 23, 50)
        gasto("50", em: tarde)
        let r = resumo(c, "23/07")
        #expect(r.dias[2].gasto == 50); #expect(r.dias[3].gasto == 0); #expect(r.gastoHoje == 0)
        #expect(resumo(c, "22/07").dias[2].ehHoje)
        #expect(resumo(c, "22/07").estado == .durante(dia: 3, de: 6))
    }
    @Test func cicloDoInicioEscolheOQueContemHoje() {
        let cui = cuiaba()
        let antigo = ciclo(titulo: "Antigo", de: 1, ate: 5, mes: 6)
        let futuro = ciclo(titulo: "Futuro", de: 10, ate: 12, mes: 8)
        let hoje = d("23/07")
        #expect(cicloDoInicio([antigo, cui, futuro], hoje: hoje, calendario: cal) === cui)
        #expect(cicloDoInicio([antigo, futuro], hoje: hoje, calendario: cal) === futuro)
        #expect(cicloDoInicio([antigo], hoje: hoje, calendario: cal) === antigo)
        #expect(cicloDoInicio([], hoje: hoje, calendario: cal) == nil)
    }
    @Test func cicloDoInicioSobreposicaoPegaOMaisRecente() {
        let a = ciclo(titulo: "A", de: 20, ate: 25)
        let b = ciclo(titulo: "B", de: 22, ate: 28)
        #expect(cicloDoInicio([a, b], hoje: d("23/07"), calendario: cal) === b)
    }
    @Test func valores() {
        #expect(ValoresViagem.diaria(total: 2700, dias: 6) == 450)
        #expect(ValoresViagem.total(diaria: 450, dias: 6) == 2700)
        #expect(ValoresViagem.diaria(total: 1000, dias: 3) == dec("333.33"))
        #expect(ValoresViagem.diaria(total: 100, dias: 0) == 0)
    }
    @Test func codigos() {
        #expect(codigoCidade("Cuiabá, MT") == "CUI"); #expect(codigoCidade("São Paulo") == "SAO")
        #expect(codigoCidade("") == "---")
    }
}
