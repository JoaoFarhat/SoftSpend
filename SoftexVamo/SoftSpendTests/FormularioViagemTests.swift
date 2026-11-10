import Testing
import Foundation
import SwiftData
@testable import SoftSpend

@MainActor
struct FormularioViagemTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }()

    func d(_ dia: Int, _ mes: Int = 7) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mes, day: dia, hour: 10))!
    }
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    func formulario(ida: Int = 20, volta: Int = 25) -> FormularioViagem {
        FormularioViagem(ida: d(ida), volta: d(volta), calendario: cal)
    }

    // MARK: Dias

    @Test func contaIdaEVolta() {
        #expect(formulario().dias == 6)
        #expect(formulario(ida: 20, volta: 20).dias == 1)
        #expect(FormularioViagem(ida: d(25), volta: d(20), calendario: cal).dias == 0)
    }

    // MARK: Campos ligados

    @Test func diaria450EmSeisDiasDaTotal2700() {
        var f = formulario()
        f.editarDiaria("450")
        #expect(f.total == 2700)
        #expect(f.totalTexto == "2.700,00")
        #expect(f.diariaTexto == "450")
        #expect(f.ultimoEditado == .diaria)
    }

    @Test func totalCalculaDiaria() {
        var f = formulario()
        f.editarTotal("2.700,00")
        #expect(f.diariaTexto == "450,00")
        #expect(f.totalTexto == "2.700,00")
        #expect(f.ultimoEditado == .total)
    }

    @Test func totalQueNaoDivideArredondaSoADiaria() {
        var f = formulario(ida: 20, volta: 22)
        f.editarTotal("1000")
        #expect(f.diariaTexto == "333,33")
        #expect(f.total == 1000)
    }

    @Test func limparUmCampoLimpaOOutro() {
        var f = formulario()
        f.editarTotal("2700")
        f.editarTotal("")
        #expect(f.diariaTexto == "")
        #expect(f.total == nil)
    }

    /// Diária digitada (diária fixa): mudar as datas mantém a diária e recalcula o total.
    @Test func mudarDatasComDiariaDigitadaMantemADiaria() {
        var f = formulario()
        f.editarDiaria("450")
        f.mudarVolta(d(28)) // 9 dias
        #expect(f.diaria == 450)
        #expect(f.totalTexto == "4.050,00")
        f.mudarIda(d(26)) // 26 a 28 = 3 dias
        #expect(f.diaria == 450)
        #expect(f.totalTexto == "1.350,00")
    }

    /// Total digitado (valor cheio da viagem): mudar as datas mantém o total e recalcula a diária.
    @Test func mudarDatasComTotalDigitadoMantemOTotal() {
        var f = formulario()
        f.editarTotal("2700")
        f.mudarVolta(d(28)) // 9 dias
        #expect(f.total == 2700)
        #expect(f.diariaTexto == "300,00")
        f.mudarIda(d(26)) // 26 a 28 = 3 dias
        #expect(f.diariaTexto == "900,00")
    }

    /// Viagem antiga aberta para editar (nada digitado ainda): vale o total, como antes.
    @Test func mudarDatasSemCampoDigitadoMantemOTotal() {
        var f = FormularioViagem(ida: d(20), volta: d(25), total: 2700, calendario: cal)
        f.mudarVolta(d(28))
        #expect(f.total == 2700)
        #expect(f.diariaTexto == "300,00")
    }

    /// A última edição é a que vale: digitou a diária e depois o total, o total fica.
    @Test func ultimaEdicaoDecideQualCampoFica() {
        var f = formulario()
        f.editarDiaria("450")
        f.editarTotal("2700")
        f.mudarVolta(d(28))
        #expect(f.total == 2700)
        #expect(f.diariaTexto == "300,00")
    }

    @Test func idaDepoisDaVoltaEmpurraAVolta() {
        var f = formulario()
        f.mudarIda(d(27))
        #expect(cal.isDate(f.volta, inSameDayAs: d(27)))
        #expect(f.dias == 1)
    }

    @Test func formatarCamposNormalizaOTexto() {
        var f = formulario()
        f.editarDiaria("450")
        f.formatarCampos()
        #expect(f.diariaTexto == "450,00")
        #expect(f.totalTexto == "2.700,00")
    }

    @Test func edicaoComecaPeloTotal() {
        let f = FormularioViagem(ida: d(20), volta: d(25), total: 2700, destino: "Cuiabá, MT", calendario: cal)
        #expect(f.totalTexto == "2.700,00")
        #expect(f.diariaTexto == "450,00")
        #expect(f.ultimoEditado == nil)
    }

    // MARK: Validação

    @Test func validacao() {
        var f = formulario()
        #expect(f.erro == "Informe o destino")
        f.destino = "   "
        #expect(f.erro == "Informe o destino")
        f.destino = "Cuiabá, MT"
        #expect(f.erro == "Informe o total ou a diária")
        f.editarTotal("0")
        #expect(f.erro == "Informe o total ou a diária")
        f.editarDiaria("450")
        #expect(f.erro == nil)

        var invertido = FormularioViagem(ida: d(25), volta: d(20), calendario: cal)
        invertido.destino = "Recife"
        invertido.editarTotal("100")
        #expect(invertido.erro == "A volta precisa ser no dia da ida ou depois")
    }

    // MARK: Leitura em pt-BR

    @Test func leValoresEmPtBR() {
        #expect(lerValorDigitado("2.700,00") == 2700)
        #expect(lerValorDigitado("450") == 450)
        #expect(lerValorDigitado("147,70") == dec("147.70"))
        #expect(lerValorDigitado("R$ 1.183,00") == 1183)
        #expect(lerValorDigitado("1.234.567") == 1234567)
        #expect(lerValorDigitado("2.700") == 2700)
        #expect(lerValorDigitado("450,") == 450)
        // Teclado decimal de aparelho em inglês usa ponto.
        #expect(lerValorDigitado("450.50") == dec("450.50"))
        #expect(lerValorDigitado("10,555") == dec("10.56"))
        #expect(lerValorDigitado("") == nil)
        #expect(lerValorDigitado("abc") == nil)
        #expect(lerValorDigitado("1,2,3") == nil)
    }

    // MARK: Salvar

    @Test func criarViagemDeSeisDiasDigitandoSoADiariaSalvaTotal2700() async throws {
        let container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let vm = CiclosViewModel()
        vm.modelContext = ModelContext(container)

        var f = FormularioViagem(ida: d(20), volta: d(25), calendario: cal)
        f.destino = "Cuiabá, MT"
        f.editarDiaria("450")
        #expect(f.erro == nil)
        let total = try #require(f.total)

        try await vm.createNewCiclo(startDate: f.ida, endDate: f.volta, totalValue: total, titulo: f.destino)

        let ciclo = try #require(vm.allCiclos.first)
        #expect(ciclo.valor_total == 2700)
        #expect(ciclo.diaria == 450)
        #expect((ciclo.dias ?? []).count == 6)
    }
}

@MainActor
struct ViagensTests {
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

    func d(_ dia: Int, _ mes: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mes, day: dia, hour: 10))!
    }

    func ciclo(_ titulo: String, _ mes: Int, _ ini: Int, _ fim: Int) -> CicloSoftex {
        let c = CicloSoftex(valor_total: 1000, gasto_total: 0, periodo: "", diaria: 100, titulo: titulo, dias: [])
        ctx.insert(c)
        for n in ini...fim {
            let dia = DiaSoftex(data: d(n, mes), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = c
        }
        return c
    }

    @Test func separaAgoraProximasEAnteriores() {
        let recife = ciclo("Recife, PE", 4, 14, 19)
        let cuiaba = ciclo("Cuiabá, MT", 7, 20, 25)
        let poa = ciclo("Porto Alegre, RS", 6, 2, 6)
        let rio = ciclo("Rio de Janeiro, RJ", 9, 1, 3)
        let bh = ciclo("Belo Horizonte, MG", 8, 10, 12)
        let todos = [recife, cuiaba, poa, rio, bh]
        let hoje = d(23, 7)

        let agora = cicloDoInicio(todos, hoje: hoje, calendario: cal)
        #expect(agora?.id == cuiaba.id)
        let g = gruposViagens(todos, agora: agora, hoje: hoje, calendario: cal)
        #expect(g.proximas.map(\.titulo) == ["Belo Horizonte, MG", "Rio de Janeiro, RJ"])
        #expect(g.anteriores.map(\.titulo) == ["Porto Alegre, RS", "Recife, PE"])
    }

    @Test func intervaloSemDiasUsaOPeriodo() {
        let c = CicloSoftex(valor_total: 1000, gasto_total: 0, periodo: "28/12 - 02/01", diaria: 100, titulo: "Natal, RN")
        c.criadoEm = d(1, 12)
        ctx.insert(c)
        let intervalo = intervaloViagem(c, calendario: cal)
        #expect(intervalo.map { cal.component(.day, from: $0.ini) } == 28)
        #expect(intervalo.map { cal.component(.year, from: $0.fim) } == 2027)
    }
}
