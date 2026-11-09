import Testing
import Foundation
@testable import SoftSpend

struct FormatacaoTests {
    @Test func brlComCentavos() { #expect(formatarBRL(1183) == "R$ 1.183,00") }
    @Test func brlSemCentavos() { #expect(formatarBRL(Decimal(string: "1517.4")!, centavos: false) == "R$ 1.517") }
    @Test func brlNegativo() { #expect(formatarBRL(-38) == "-R$ 38,00") }
    @Test func brlIgnoraIdiomaDoAparelho() {
        // Locale.current não pode ser trocado no teste; a implementação fixa pt_BR.
        #expect(formatarBRL(Decimal(string: "302.3")!) == "R$ 302,30")
    }
}
