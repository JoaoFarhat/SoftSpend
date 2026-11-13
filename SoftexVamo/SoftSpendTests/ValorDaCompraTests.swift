import Testing
import Foundation
@testable import SoftSpend

/// Parser do valor que a automação do Atalhos entrega (§1.4 de
/// docs/cartao-sem-open-finance.md).
struct ValorDaCompraTests {

    private func d(_ texto: String) -> Decimal { Decimal(string: texto)! }

    @Test func formatosAceitos() {
        #expect(ValorDaCompra.interpretar("R$ 12,34") == d("12.34"))
        #expect(ValorDaCompra.interpretar("12,34") == d("12.34"))
        #expect(ValorDaCompra.interpretar("12.34") == d("12.34"))
        #expect(ValorDaCompra.interpretar("1.234,56") == d("1234.56"))
        #expect(ValorDaCompra.interpretar("1.234") == d("1234"))
        #expect(ValorDaCompra.interpretar("12,5") == d("12.5"))
        #expect(ValorDaCompra.interpretar("1234,56") == d("1234.56"))
    }

    @Test func sinalNegativoViraPositivo() {
        #expect(ValorDaCompra.interpretar("-12,34") == d("12.34"))
        #expect(ValorDaCompra.interpretar("-R$ 5,00") == d("5"))
    }

    @Test func espacosEMoeda() {
        // Espaço sem quebra, como o "R$ 12,34" do iOS pode trazer.
        #expect(ValorDaCompra.interpretar("R$\u{00A0}9,90") == d("9.9"))
        #expect(ValorDaCompra.interpretar("R$ 8,00") == d("8"))
        #expect(ValorDaCompra.interpretar("BRL 8,00") == d("8"))
    }

    @Test func recusas() {
        #expect(ValorDaCompra.interpretar("0") == nil)
        #expect(ValorDaCompra.interpretar("0,00") == nil)
        #expect(ValorDaCompra.interpretar("abc") == nil)
        #expect(ValorDaCompra.interpretar("") == nil)
        #expect(ValorDaCompra.interpretar("R$") == nil)
        #expect(ValorDaCompra.interpretar("US$ 10,00") == nil)
        #expect(ValorDaCompra.interpretar("€ 5") == nil)
    }

    @Test func teto() {
        // Acima de R$ 100.000 é provável erro de leitura; no teto passa.
        #expect(ValorDaCompra.interpretar("R$ 100.000,00") == d("100000"))
        #expect(ValorDaCompra.interpretar("R$ 100.001,00") == nil)
        #expect(ValorDaCompra.interpretar("999999,99") == nil)
    }

    @Test func moedaEstrangeira() {
        #expect(ValorDaCompra.temMoedaEstrangeira("US$ 10,00"))
        #expect(ValorDaCompra.temMoedaEstrangeira("$ 10,00"))
        #expect(ValorDaCompra.temMoedaEstrangeira("€ 5"))
        #expect(ValorDaCompra.temMoedaEstrangeira("£ 5"))
        #expect(ValorDaCompra.temMoedaEstrangeira("USD 10"))
        #expect(ValorDaCompra.temMoedaEstrangeira("EUR 10"))
        #expect(!ValorDaCompra.temMoedaEstrangeira("R$ 10,00"))
        #expect(!ValorDaCompra.temMoedaEstrangeira("BRL 10,00"))
        #expect(!ValorDaCompra.temMoedaEstrangeira("10,00"))
    }
}
