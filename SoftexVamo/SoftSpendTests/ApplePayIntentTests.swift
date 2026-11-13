import Testing
import Foundation
import AppIntents
@testable import SoftSpend

/// Fumaça (§1.9): a ação existe, não abre o app, e o container compartilhado
/// entre o app e a ação é único (não é criado duas vezes).
struct ApplePayIntentTests {
    @Test func containerCompartilhadoEhUnico() {
        #expect(BancoLocal.container === BancoLocal.container)
    }

    @Test func acaoExisteENaoAbreOApp() {
        let intent = RegistrarGastoIntent(valor: "R$ 1,00", estabelecimento: "Padaria")
        #expect(RegistrarGastoIntent.openAppWhenRun == false)
        #expect(intent.valor == "R$ 1,00")
        #expect(intent.estabelecimento == "Padaria")
        #expect(intent.cartao == nil)
    }

    @Test func atalhosTemAFraseComNomeDoApp() {
        #expect(SoftSpendAtalhos.appShortcuts.count == 1)
    }
}
