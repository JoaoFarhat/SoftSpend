import Testing
import AppIntents
@testable import SoftSpend

/// §1.9 de docs/cartao-sem-open-finance.md: fumaça — a ação existe e o
/// container compartilhado não é criado duas vezes.
@MainActor
struct ApplePayFumacaTests {

    @Test func acaoExisteERodaSemAbrirOApp() {
        let intent = RegistrarGastoIntent(valor: "R$ 12,34", estabelecimento: "PADARIA")
        #expect(intent.valor == "R$ 12,34")
        #expect(RegistrarGastoIntent.openAppWhenRun == false)
        #expect(!SoftSpendAtalhos.appShortcuts.isEmpty)
    }

    @Test func containerCompartilhadoEhUnico() {
        // `static let`: quem acessar primeiro (app ou ação) cria; o resto reusa.
        #expect(BancoLocal.container === BancoLocal.container)
        #expect(BancoLocal.container.mainContext === BancoLocal.container.mainContext)
    }
}
