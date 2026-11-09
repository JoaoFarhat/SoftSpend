import Testing
@testable import SoftSpend

/// `username` enviado ao servidor no cadastro: sai da parte do e-mail antes do
/// "@" (o campo "Nome de usuário" saiu da tela). O servidor exige 3 a 50 caracteres.
struct CadastroTests {
    @Test func usaParteAntesDaArroba() {
        #expect(usernameDoEmail("joao@empresa.com") == "joao")
    }

    @Test func mantemPontoESublinhado() {
        #expect(usernameDoEmail("joao.victor_farhat@empresa.com") == "joao.victor_farhat")
    }

    @Test func ficaEmMinusculas() {
        #expect(usernameDoEmail("Joao.Farhat@Empresa.com") == "joao.farhat")
    }

    @Test func tiraOutrosCaracteres() {
        #expect(usernameDoEmail("joao+viagens-2026@empresa.com") == "joaoviagens2026")
    }

    @Test func tiraAcentoSemPerderALetra() {
        #expect(usernameDoEmail("joão@empresa.com") == "joao")
    }

    @Test func ignoraEspacosEmVolta() {
        #expect(usernameDoEmail("  joao@empresa.com ") == "joao")
    }

    @Test func semArrobaUsaOTextoTodo() {
        #expect(usernameDoEmail("joao") == "joao")
    }

    @Test func limitaA50Caracteres() {
        let longo = String(repeating: "a", count: 70) + "@empresa.com"
        #expect(usernameDoEmail(longo) == String(repeating: "a", count: 50))
    }

    @Test func curtoDemaisCompletaComODominio() {
        // O servidor recusa menos de 3 caracteres.
        #expect(usernameDoEmail("jo@empresa.com") == "jo.empresa")
    }

    @Test func nuncaFicaComMenosDe3() {
        #expect(usernameDoEmail("a@b").count >= 3)
        #expect(usernameDoEmail("@").count >= 3)
    }
}
