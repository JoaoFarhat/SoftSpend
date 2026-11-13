import Testing
import Foundation
import SwiftData
import AppIntents
@testable import SoftSpend

// Em série com as outras suítes do usuário global: ver `UsuarioGlobalTests`.
// (Apaga os tokens do Keychain do host de teste para simular o iPhone trancado.)
extension UsuarioGlobalTests {

/// §1.3: o `userId` da ação de Atalhos vem do `user_data` do `UserDefaults`,
/// sem token — funciona com o iPhone trancado, quando o Keychain não abre.
/// Os testes usam um `UserDefaults` de suíte própria, nunca o `.standard`.
@MainActor
struct UsuarioSalvoTests {
    let suite: String
    let defaults: UserDefaults
    let container: ModelContainer
    let ctx: ModelContext
    let fila: ComprasAguardandoViagem

    init() throws {
        suite = "UsuarioSalvoTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        fila = ComprasAguardandoViagem(diretorio: FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-\(UUID().uuidString)", isDirectory: true))
    }

    /// O mesmo JSON `UserDTO` que o `AuthService` grava no login.
    func gravarUsuario(id: String) {
        let dto = UserDTO(id: id, nome: "João", username: "joao", email: "j@x.com")
        defaults.set(try? JSONEncoder().encode(dto), forKey: UsuarioSalvo.chave)
    }

    @discardableResult
    func viagemAberta(userId: String) -> CicloSoftex {
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 700, gasto_total: 0,
            periodo: "", diaria: 100, titulo: "Cuiabá", dias: []
        )
        ctx.insert(ciclo)
        for delta in -1...1 {
            let dia = DiaSoftex(data: Date.now.addingTimeInterval(TimeInterval(delta * 86400)), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = ciclo
        }
        try? ctx.save()
        return ciclo
    }

    @Test func comUserDataSemTokenDevolveOId() {
        // Sem nenhum token no Keychain — como com o iPhone trancado.
        KeychainManager.deleteAllTokens()
        gravarUsuario(id: "u-123")
        #expect(UsuarioSalvo.id(em: defaults) == "u-123")
    }

    @Test func comIdSalvoORegistroGravaOGasto() throws {
        KeychainManager.deleteAllTokens()
        gravarUsuario(id: "u-123")
        _ = viagemAberta(userId: "u-123")

        let r = RegistroApplePay.registrar(
            valorTexto: "12,34", estabelecimento: "Padaria",
            userId: UsuarioSalvo.id(em: defaults),
            em: ctx, fila: fila, agora: .now, calendario: .current)
        guard case .gravado = r else {
            Issue.record("esperava .gravado, veio \(r)")
            return
        }
        let gasto = try #require(ctx.fetch(FetchDescriptor<GastosDia>()).first)
        // Tudo filtra por `userId`: a compra cai na conta certa.
        #expect(gasto.dia?.ciclo?.userId == "u-123")
    }

    @Test func semUserDataRecusaENaoGravaNada() throws {
        KeychainManager.deleteAllTokens()
        #expect(UsuarioSalvo.id(em: defaults) == nil)
        _ = viagemAberta(userId: "u-123")

        let r = RegistroApplePay.registrar(
            valorTexto: "12,34", estabelecimento: "Padaria",
            userId: UsuarioSalvo.id(em: defaults),
            em: ctx, fila: fila, agora: .now, calendario: .current)
        #expect(r == .recusado(.semUsuario))
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
        #expect(fila.ler(userId: "u-123").isEmpty)
    }
}

/// Fumaça da parte A (§1.9): a ação existe, não abre o app e o `BancoLocal`
/// é um container só, compartilhado entre o app e a ação.
@MainActor
struct AtalhoApplePayFumacaTests {
    @Test func acaoExisteENaoAbreOApp() {
        #expect(RegistrarGastoIntent.openAppWhenRun == false)
        #expect(SoftSpendAtalhos.appShortcuts.count == 1)
    }

    @Test func containerCompartilhadoEhUmSo() {
        #expect(BancoLocal.container === BancoLocal.container)
    }
}

}  // extension UsuarioGlobalTests
