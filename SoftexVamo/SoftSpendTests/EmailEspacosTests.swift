import Testing
import Foundation
@testable import SoftSpend

/// Espaços e quebras de linha em volta do e-mail — a sugestão de e-mail do
/// teclado do iPhone deixa um espaço no fim — são aparados no `init` dos
/// DTOs de auth, antes de ir para o servidor (que também apara).
struct EmailEspacosTests {

    @Test func loginAparaEspacosEmVoltaDoEmail() {
        let req = LoginRequest(email: "  joao@exemplo.com  ", senha: "Senha123!")
        #expect(req.email == "joao@exemplo.com")
        #expect(req.senha == "Senha123!")
    }

    @Test func loginAparaTabEQuebraDeLinha() {
        let req = LoginRequest(email: "\tjoao@exemplo.com\n", senha: "x")
        #expect(req.email == "joao@exemplo.com")
    }

    @Test func cadastroAparaEspacosEmVoltaDoEmail() {
        let req = RegisterRequest(
            nome: "João", username: "joao_abc123",
            email: " joao@exemplo.com \n", senha: "Senha123!"
        )
        #expect(req.email == "joao@exemplo.com")
        #expect(req.nome == "João")
        #expect(req.username == "joao_abc123")
    }

    @Test func emailSemEspacosNaoMuda() {
        #expect(LoginRequest(email: "joao@exemplo.com", senha: "x").email == "joao@exemplo.com")
    }
}
