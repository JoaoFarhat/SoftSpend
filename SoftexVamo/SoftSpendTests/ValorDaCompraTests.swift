import Testing
import Foundation
@testable import SoftSpend

/// §1.4: o parser do valor que a automação do Atalhos entrega como texto
/// ("R$ 12,34" ou só "12,34", no idioma do aparelho).
struct ValorDaCompraTests {
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test func aceitaOsFormatosDoAtalhos() {
        #expect(ValorDaCompra.interpretar("R$ 12,34") == dec("12.34"))
        #expect(ValorDaCompra.interpretar("12.34") == dec("12.34"))
        #expect(ValorDaCompra.interpretar("1.234,56") == dec("1234.56"))
        #expect(ValorDaCompra.interpretar("1.234") == dec("1234"))
        #expect(ValorDaCompra.interpretar("12,5") == dec("12.5"))
        #expect(ValorDaCompra.interpretar("1234,56") == dec("1234.56"))
        #expect(ValorDaCompra.interpretar("-12,34") == dec("12.34"))
        // Espaço sem quebra, que o texto do Atalhos pode trazer.
        #expect(ValorDaCompra.interpretar("R$\u{00A0}12,34") == dec("12.34"))
        // No teto, passa; acima, é provável erro de leitura.
        #expect(ValorDaCompra.interpretar("R$ 100.000,00") == dec("100000"))
    }

    @Test func recusaSemNumeroZeroEAcimaDoTeto() {
        #expect(ValorDaCompra.interpretar("0") == nil)
        #expect(ValorDaCompra.interpretar("0,00") == nil)
        #expect(ValorDaCompra.interpretar("abc") == nil)
        #expect(ValorDaCompra.interpretar("") == nil)
        #expect(ValorDaCompra.interpretar("R$") == nil)
        #expect(ValorDaCompra.interpretar("R$ 150.000,00") == nil)
        #expect(ValorDaCompra.interpretar("R$ 100.000,01") == nil)
    }

    @Test func moedaEstrangeira() {
        #expect(ValorDaCompra.temMoedaEstrangeira("US$ 10,00"))
        #expect(ValorDaCompra.temMoedaEstrangeira("$ 10"))
        #expect(ValorDaCompra.temMoedaEstrangeira("€ 5"))
        #expect(ValorDaCompra.temMoedaEstrangeira("£ 5"))
        #expect(ValorDaCompra.temMoedaEstrangeira("USD 10,00"))
        #expect(ValorDaCompra.temMoedaEstrangeira("EUR 10,00"))
        #expect(!ValorDaCompra.temMoedaEstrangeira("R$ 10,00"))
        #expect(!ValorDaCompra.temMoedaEstrangeira("BRL 10,00"))
        #expect(!ValorDaCompra.temMoedaEstrangeira("12,34"))
    }
}
