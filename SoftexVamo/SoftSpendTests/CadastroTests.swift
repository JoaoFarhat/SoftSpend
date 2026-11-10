import Testing
import CryptoKit
import Foundation
@testable import SoftSpend

/// `username` enviado ao servidor no cadastro: sai do e-mail (o campo "Nome de
/// usuário" saiu da tela). O servidor exige 3 a 50 caracteres e username único,
/// então vai a parte antes do "@" + "_" + 6 hex do SHA-256 do e-mail inteiro.
struct CadastroTests {
    /// Os 6 primeiros hex do SHA-256 do e-mail (sem espaços em volta, minúsculo).
    private func sufixo(_ email: String) -> String {
        let normal = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = SHA256.hash(data: Data(normal.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(6))
    }

    @Test func usaParteAntesDaArrobaMaisSufixo() {
        #expect(usernameDoEmail("joao@empresa.com") == "joao_\(sufixo("joao@empresa.com"))")
    }

    @Test func mesmaParteLocalEmDominiosDiferentesNaoColide() {
        let a = usernameDoEmail("joao@empresa.com")
        let b = usernameDoEmail("joao@gmail.com")
        #expect(a != b)
        #expect(a.hasPrefix("joao_"))
        #expect(b.hasPrefix("joao_"))
    }

    @Test func mesmoEmailDaSempreOMesmoUsername() {
        #expect(usernameDoEmail("joao@empresa.com") == usernameDoEmail("joao@empresa.com"))
        // Maiúsculas e espaços em volta não mudam o e-mail.
        #expect(usernameDoEmail("  Joao@Empresa.com ") == usernameDoEmail("joao@empresa.com"))
    }

    @Test func sufixoTem6Hex() {
        let u = usernameDoEmail("joao@empresa.com")
        let fim = u.split(separator: "_").last.map(String.init) ?? ""
        #expect(fim.count == 6)
        #expect(fim.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func mantemPontoESublinhado() {
        #expect(usernameDoEmail("joao.victor_farhat@empresa.com").hasPrefix("joao.victor_farhat_"))
    }

    @Test func tiraOutrosCaracteres() {
        #expect(usernameDoEmail("joao+viagens-2026@empresa.com").hasPrefix("joaoviagens2026_"))
    }

    @Test func tiraAcentoSemPerderALetra() {
        #expect(usernameDoEmail("joão@empresa.com") == "joao_\(sufixo("joão@empresa.com"))")
    }

    @Test func semArrobaUsaOTextoTodo() {
        #expect(usernameDoEmail("joao").hasPrefix("joao_"))
    }

    @Test func limitaA50Caracteres() {
        let longo = String(repeating: "a", count: 70) + "@empresa.com"
        let u = usernameDoEmail(longo)
        #expect(u.count == 50)
        #expect(u == String(repeating: "a", count: 43) + "_" + sufixo(longo))
    }

    @Test func nuncaFicaForaDe3a50() {
        for email in ["a@b", "@", "", "çã@x.com", "jo@empresa.com",
                      String(repeating: "x", count: 200) + "@y.com"] {
            let u = usernameDoEmail(email)
            #expect(u.count >= 3 && u.count <= 50, "\(email) → \(u)")
        }
    }
}
