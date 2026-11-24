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

    /// Num iPhone em inglês o Atalhos manda "1,234.56": o separador mais à
    /// direita é o decimal e o outro é milhar (antes toda vírgula era
    /// decimal e "R$1,234.56" virava R$ 1,23).
    @Test func formatoInglesComVirgulaEPonto() {
        #expect(ValorDaCompra.interpretar("R$1,234.56") == d("1234.56"))
        #expect(ValorDaCompra.interpretar("1,234.56") == d("1234.56"))
        #expect(ValorDaCompra.interpretar("R$ 12,345.00") == d("12345"))
        #expect(ValorDaCompra.interpretar("R$ 1.234,56") == d("1234.56"))
        #expect(ValorDaCompra.interpretar("-1,234.56") == d("1234.56"))
    }

    /// Duas vírgulas ou mais sem ponto são milhar ("1,234,567" em inglês).
    /// O valor passa do teto e é recusado — não vira "1,23" como antes.
    @Test func virgulasRepetidasSaoMilhar() {
        #expect(ValorDaCompra.interpretar("1,234,567") == nil)
        #expect(ValorDaCompra.interpretar("R$ 0,99") == d("0.99"))
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

    /// `Decimal(string:)` aceita o começo e ignora o resto: "1.234.5" (dois
    /// pontos sem formar milhar) viraria R$ 1,23 em vez de ser recusado. O
    /// texto final tem que ser só dígitos com no máximo um ponto.
    @Test func pontosQueNaoFormamMilhar() {
        #expect(ValorDaCompra.interpretar("1.234.5") == nil)
        #expect(ValorDaCompra.interpretar("12.3.4") == nil)
        #expect(ValorDaCompra.interpretar("1,2,3.4.5") == nil)
        #expect(ValorDaCompra.interpretar("12.") == nil)

        // Formatos válidos seguem iguais.
        #expect(ValorDaCompra.interpretar("R$ 12,34") == d("12.34"))
        #expect(ValorDaCompra.interpretar("1.234") == d("1234"))
        #expect(ValorDaCompra.interpretar("99.999") == d("99999"))
        #expect(ValorDaCompra.interpretar("1.234,56") == d("1234.56"))
        #expect(ValorDaCompra.interpretar("R$1,234.56") == d("1234.56"))
        #expect(ValorDaCompra.interpretar("12.34") == d("12.34"))
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
