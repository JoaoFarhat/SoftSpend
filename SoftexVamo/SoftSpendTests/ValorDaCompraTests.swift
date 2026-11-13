import Testing
import Foundation
@testable import SoftSpend

/// §1.4 e §1.9 de docs/cartao-sem-open-finance.md: leitura do texto que a
/// automação do Apple Pay entrega ("R$ 12,34" ou só "12,34").
struct ValorDaCompraTests {

    @Test("Textos aceitos viram Decimal", arguments: [
        ("R$ 12,34", "12.34"),
        ("12.34", "12.34"),
        ("1.234,56", "1234.56"),
        ("1.234", "1234"),
        ("12,5", "12.5"),
        ("-12,34", "12.34"),
        ("1234,56", "1234.56"),
        ("R$\u{00A0}1.234,56", "1234.56"),
        ("BRL 42,00", "42.00"),
        ("99,999", "100.00"),
    ])
    func aceitos(_ texto: String, _ esperado: String) {
        #expect(ValorDaCompra.interpretar(texto) == Decimal(string: esperado))
    }

    @Test("Sem número, zero, acima do teto ou moeda de fora devolvem nil", arguments: [
        "0", "0,00", "abc", "", "R$",
        "1.234.567", "100.001", "R$ 100.000,01",
        "US$ 10,00", "$ 10,00", "€ 5", "£ 5", "USD 10", "EUR 1,00",
    ])
    func recusados(_ texto: String) {
        #expect(ValorDaCompra.interpretar(texto) == nil)
    }

    /// O teto é "acima de R$ 100.000": exatos cem mil passam.
    @Test func tetoAceita() {
        #expect(ValorDaCompra.interpretar("R$ 100.000,00") == Decimal(100_000))
    }

    @Test("Símbolo ou código de outra moeda", arguments: [
        ("US$ 10,00", true), ("$ 10,00", true), ("€ 5", true), ("£ 5", true),
        ("USD 10", true), ("EUR 10", true),
        ("R$ 10,00", false), ("BRL 10,00", false), ("10,00", false),
        ("R$ 1.234,56", false),
    ])
    func moedaEstrangeira(_ texto: String, _ esperado: Bool) {
        #expect(ValorDaCompra.moedaEstrangeira(texto) == esperado)
    }
}
