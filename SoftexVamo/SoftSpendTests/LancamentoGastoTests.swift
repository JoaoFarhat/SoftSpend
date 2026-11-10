import Testing
import Foundation
@testable import SoftSpend

@MainActor
struct LancamentoGastoTests {
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    func valor(_ texto: String) -> Decimal {
        let r = RascunhoGasto(dia: nil)
        r.valorTexto = texto
        return r.valor
    }

    /// O teclado decimal digita "." em aparelhos em inglês e "," em pt-BR.
    @Test func valorAceitaPontoEVirgula() {
        #expect(valor("43.10") == dec("43.10"))
        #expect(valor("43,10") == dec("43.10"))
        #expect(valor("43.1") == dec("43.1"))
        #expect(valor("1.234,56") == dec("1234.56"))
    }

    @Test func valorArredondaEInvalidoVale0() {
        #expect(valor("12,345") == dec("12.35"))
        #expect(valor("") == 0)
        #expect(valor("abc") == 0)
    }
}
