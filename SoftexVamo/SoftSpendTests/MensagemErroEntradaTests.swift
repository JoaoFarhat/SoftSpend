import Testing
import Foundation
@testable import SoftSpend

/// Login sem internet não pode dizer "Email ou senha invalidos": o `URLError`
/// de falta de rede caía no mesmo fallback do erro de senha
/// (`AuthService.login`), e a pessoa podia trocar a senha à toa.
/// `AuthService.mensagemDeErroDeEntrada` separa os três casos — `APIError`
/// (frase do servidor), `URLError` de rede ("sem conexão") e o resto
/// (genérica) — e é usada por `login` e `register`.
struct MensagemErroEntradaTests {

    /// `URLError` de falta de rede: a frase de conexão, não a de senha errada.
    @Test func erroDeRedeViraFraseDeConexao() {
        #expect(AuthService.mensagemDeErroDeEntrada(URLError(.notConnectedToInternet)) ==
            "Sem conexão com o servidor. Confira a internet e tente de novo.")
        #expect(AuthService.mensagemDeErroDeEntrada(URLError(.timedOut)) ==
            "Sem conexão com o servidor. Confira a internet e tente de novo.")
    }

    /// Os outros `URLError.Code` da lista (conexão perdida, host não
    /// encontrado, host inalcançável, dados celulares bloqueados) dão a
    /// mesma frase de conexão.
    @Test func outrosCodigosDeRedeViramFraseDeConexao() {
        for code in [URLError.Code.networkConnectionLost, .cannotFindHost,
                     .cannotConnectToHost, .dataNotAllowed] {
            #expect(AuthService.mensagemDeErroDeEntrada(URLError(code)) ==
                "Sem conexão com o servidor. Confira a internet e tente de novo.")
        }
    }

    /// `APIError` devolve o `localizedDescription` dele — a frase do
    /// servidor, como o "E-mail ou senha incorretos." do 401.
    @Test func apiErrorDevolveAMensagemDele() {
        let erro = APIError.serverError(
            message: "E-mail ou senha incorretos.", requestId: "x", statusCode: 401)
        #expect(AuthService.mensagemDeErroDeEntrada(erro) ==
            "E-mail ou senha incorretos.")
    }

    /// Um erro qualquer (nem `APIError` nem `URLError` de rede) cai na
    /// frase genérica — inclusive um `URLError` fora da lista, como
    /// `.cancelled`.
    @Test func erroQualquerViraFraseGenerica() {
        #expect(AuthService.mensagemDeErroDeEntrada(CocoaError(.fileReadUnknown)) ==
            "Não foi possível entrar agora. Tente de novo.")
        #expect(AuthService.mensagemDeErroDeEntrada(URLError(.cancelled)) ==
            "Não foi possível entrar agora. Tente de novo.")
    }
}
