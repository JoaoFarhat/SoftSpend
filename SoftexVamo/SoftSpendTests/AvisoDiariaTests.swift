import Testing
import Foundation
@testable import SoftSpend

@MainActor
struct AvisoDiariaTests {
    private let cal = Calendar(identifier: .gregorian)
    private var hoje: Date { cal.date(from: DateComponents(year: 2025, month: 7, day: 21, hour: 19, minute: 20))! }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test func oitentaPorCentoAvisaQuantoFalta() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("360"), diaria: dec("450"), jaAvisados: [], hoje: hoje)
        #expect(avisos == [.oitentaPorCento(livre: dec("90"), data: hoje)])
    }

    @Test func abaixoDeOitentaNaoAvisa() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("359.99"), diaria: dec("450"), jaAvisados: [], hoje: hoje)
        #expect(avisos.isEmpty)
    }

    @Test func oitentaJaAvisadoNoDiaNaoRepete() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("360"), diaria: dec("450"),
                                         jaAvisados: ["80-2025-07-21"], hoje: hoje)
        #expect(avisos.isEmpty)
    }

    @Test func chaveDeOutroDiaNaoBloqueia() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("360"), diaria: dec("450"),
                                         jaAvisados: ["80-2025-07-20"], hoje: hoje)
        #expect(avisos.count == 1)
    }

    @Test func passouAvisaOValorEOsOitentaAindaNaoAvisados() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("488"), diaria: dec("450"), jaAvisados: [], hoje: hoje)
        #expect(avisos == [.oitentaPorCento(livre: 0, data: hoje), .passou(valor: dec("38"), data: hoje)])
    }

    @Test func passouComOitentaJaAvisado() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("488"), diaria: dec("450"),
                                         jaAvisados: ["80-2025-07-21"], hoje: hoje)
        #expect(avisos == [.passou(valor: dec("38"), data: hoje)])
    }

    @Test func passouJaAvisadoNaoRepete() {
        let avisos = AvisoDiaria.avaliar(gastoHoje: dec("500"), diaria: dec("450"),
                                         jaAvisados: ["80-2025-07-21", "passou-2025-07-21"], hoje: hoje)
        #expect(avisos.isEmpty)
    }

    @Test func diariaZeroNaoAvisa() {
        #expect(AvisoDiaria.avaliar(gastoHoje: dec("100"), diaria: 0, jaAvisados: [], hoje: hoje).isEmpty)
        #expect(AvisoDiaria.avaliar(gastoHoje: 0, diaria: 0, jaAvisados: [], hoje: hoje).isEmpty)
    }

    @Test func chaves() {
        #expect(AvisoDiaria.oitentaPorCento(livre: 90, data: hoje).chave == "80-2025-07-21")
        #expect(AvisoDiaria.passou(valor: 38, data: hoje).chave == "passou-2025-07-21")
    }

    @Test func textosDaTela13() {
        let oitenta = AvisoDiaria.oitentaPorCento(livre: dec("90"), data: hoje).conteudo(cidade: "Cuiabá", diaria: 450)
        #expect(oitenta.titulo == "Você usou 80% da diária de hoje")
        #expect(oitenta.corpo == "Ainda dá para gastar R$ 90,00 em Cuiabá.")

        let passou = AvisoDiaria.passou(valor: dec("38"), data: hoje).conteudo(cidade: "Cuiabá", diaria: 450)
        #expect(passou.titulo == "Passou R$ 38,00 da diária")
        #expect(passou.corpo == "Segunda, 21/07. Os próximos dias continuam com R$ 450.")
    }

    @Test func preferenciaLigadaPorPadraoEChavesGuardadas() {
        let nome = "AvisoDiariaTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: nome)!
        defer { defaults.removePersistentDomain(forName: nome) }

        #expect(AvisoDiaria.ativos(em: defaults))
        defaults.set(false, forKey: AvisoDiaria.chaveAtivos)
        #expect(!AvisoDiaria.ativos(em: defaults))

        #expect(AvisoDiaria.avisados(em: defaults).isEmpty)
        AvisoDiaria.registrar(["80-2025-07-21"], em: defaults)
        AvisoDiaria.registrar(["passou-2025-07-21"], em: defaults)
        #expect(AvisoDiaria.avisados(em: defaults) == ["80-2025-07-21", "passou-2025-07-21"])
    }

    @Test func diaDaSemanaEmPortugues() {
        let domingo = cal.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 12))!
        let quinta = cal.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 12))!
        #expect(diaDaSemana(domingo) == "Domingo")
        #expect(diaDaSemana(quinta) == "Quinta")
    }
}

/// Seções da tela 12 sobre a viagem de exemplo (Cuiabá, 20 a 25/07/2026).
@MainActor
struct TodosGastosTests {
    private let dados = DadosExemplo.compartilhado
    private func dia(_ secao: SecaoGastosDia) -> Int { Calendar.current.component(.day, from: secao.data) }

    @Test func secoesDoMaisRecenteComTotalDoDiaInteiro() {
        let secoes = secoesTodosGastos(dados.ciclo, filtro: .todos, busca: "")
        #expect(secoes.map(dia) == [23, 22, 21, 20])
        #expect(secoes.first?.gastos.map(\.titulo) == ["Spoleto", "Táxi aeroporto"])
        let dia21 = secoes.first { dia($0) == 21 }
        #expect(dia21?.total == Decimal(string: "488")!)
        #expect(dia21?.estourou == true)
        #expect(dia21?.passou == Decimal(string: "38")!)
    }

    @Test func semComprovanteMantemTotalDoDia() {
        let secoes = secoesTodosGastos(dados.ciclo, filtro: .semComprovante, busca: "")
        #expect(secoes.flatMap(\.gastos).map(\.titulo) == ["Táxi aeroporto", "Farmácia"])
        #expect(secoes.last?.total == Decimal(string: "412")!)
        #expect(contagemSemComprovante(dados.ciclo) == 2)
    }

    @Test func categoriaEBusca() {
        let transporte = secoesTodosGastos(dados.ciclo, filtro: .categoria(.TRANSPORTE), busca: "")
        #expect(transporte.flatMap(\.gastos).count == 3)
        let busca = secoesTodosGastos(dados.ciclo, filtro: .todos, busca: "almoco")
        #expect(busca.count == 3)
        #expect(busca.flatMap(\.gastos).allSatisfy { $0.titulo == "Almoço" })
        #expect(secoesTodosGastos(nil, filtro: .todos, busca: "").isEmpty)
    }
}
