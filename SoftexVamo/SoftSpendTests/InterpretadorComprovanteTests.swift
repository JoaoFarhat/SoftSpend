import Testing
import Foundation
@testable import SoftSpend

/// Leitura do comprovante sem IA (`ComprovanteOCRLocal` e o atalho do Apple
/// Pay): a categoria casa por palavra inteira (ou sequência de palavras) e o
/// valor não pode ser um pedaço de um número maior, como o CNPJ.
struct InterpretadorComprovanteTests {

    private func d(_ texto: String) -> Decimal { Decimal(string: texto)! }

    // MARK: Categoria — palavra inteira

    @Test func impostoNaoCasaPosto() {
        // "impostos" não é "posto": a nota de farmácia ficava em Transporte.
        let categoria = InterpretadorComprovante.inferirCategoria(de: [
            "DROGASIL", "Valor aprox. impostos R$ 1,20"
        ])
        #expect(categoria == .COMPRAS)
    }

    @Test func mercadoLivreEhCompras() {
        // A expressão "mercado livre" vale antes do "mercado" de Alimentação.
        #expect(InterpretadorComprovante.inferirCategoria(de: ["Mercado Livre"]) == .COMPRAS)
        // Junto ou com separador também casa ("mercadolivre").
        #expect(InterpretadorComprovante.inferirCategoria(de: ["MERCADOLIVRE*LOJA"]) == .COMPRAS)
    }

    @Test func uberlandiaNaoCasaUber() {
        #expect(InterpretadorComprovante.inferirCategoria(de: ["Farmácia Uberlândia"]) == .COMPRAS)
    }

    @Test func transporteCasaPalavraInteira() {
        #expect(InterpretadorComprovante.inferirCategoria(de: ["UBER *TRIP"]) == .TRANSPORTE)
        #expect(InterpretadorComprovante.inferirCategoria(de: ["Posto Ipiranga"]) == .TRANSPORTE)
    }

    @Test func pluralComSEhAceito() {
        #expect(InterpretadorComprovante.inferirCategoria(de: ["Pizzas da Vila"]) == .ALIMENTACAO)
        #expect(InterpretadorComprovante.inferirCategoria(de: ["Cafeteria Central"]) == .ALIMENTACAO)
    }

    @Test func showroomNaoCasaShow() {
        #expect(InterpretadorComprovante.inferirCategoria(de: ["Showroom Móveis"]) == nil)
    }

    // MARK: Valor — não é pedaço de número maior

    @Test func cnpjSozinhoNaoDaValor() {
        #expect(InterpretadorComprovante.encontrarValor(em: ["CNPJ 12.345.678/0001-90"]) == nil)
    }

    @Test func cnpjNaoGanhaDoValorReal() {
        // Sem rótulo de "total", o fallback pega o maior valor da nota — e os
        // pedaços "12,34"/"5,67" do CNPJ não podem entrar nessa disputa.
        let valor = InterpretadorComprovante.encontrarValor(em: [
            "CNPJ 12.345.678/0001-90", "Pagamento 8,50"
        ])
        #expect(valor == d("8.50"))
    }

    @Test func milharComRotuloTotal() {
        let valor = InterpretadorComprovante.encontrarValor(em: ["Total R$ 1.234,56"])
        #expect(valor == d("1234.56"))
    }

    @Test func pontoFinalDeFraseEhAceito() {
        #expect(InterpretadorComprovante.encontrarValor(em: ["R$ 12,50."]) == d("12.50"))
    }
}
