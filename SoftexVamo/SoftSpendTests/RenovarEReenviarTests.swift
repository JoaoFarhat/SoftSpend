import Testing
import Foundation
@testable import SoftSpend

/// O `deslogar` do `renovandoEReenviando` é síncrono: guarda as contagens
/// atrás de um `NSLock` para os `@Sendable` poderem registrar.
private final class Registro: @unchecked Sendable {
    private let lock = NSLock()
    private var _deslogadas = 0
    private var _tokenRecebido: String?

    var deslogadas: Int { lock.withLock { _deslogadas } }
    var tokenRecebido: String? { lock.withLock { _tokenRecebido } }

    func deslogar() {
        lock.withLock { _deslogadas += 1 }
    }

    func recebeu(token: String) {
        lock.withLock { _tokenRecebido = token }
    }
}

private func erroServidor(_ status: Int) -> APIError {
    .serverError(message: "x", requestId: "-", statusCode: status)
}

private func ehErroServidor(_ erro: Error, _ status: Int) -> Bool {
    guard case APIError.serverError(_, _, let s) = erro else { return false }
    return s == status
}

/// O reenvio com o token novo roda FORA do `catch` do refresh: falhar depois
/// de renovar não derruba a sessão (o login renovado continua válido) e o
/// erro sobe intacto.
struct RenovarEReenviarTests {

    @Test func reenvioComTimeoutSobeIntactoSemDeslogar() async {
        let r = Registro()
        await #expect {
            _ = try await renovandoEReenviando(
                renovar: { "token-novo" },
                reenviar: { _ -> Int in throw URLError(.timedOut) },
                deslogar: { r.deslogar() }
            )
        } throws: { erro in
            return (erro as? URLError)?.code == .timedOut
        }
        #expect(r.deslogadas == 0)
    }

    @Test(arguments: [404, 500])
    func reenvioComErroDeServidorSobeIntactoSemDeslogar(status: Int) async {
        let r = Registro()
        await #expect {
            _ = try await renovandoEReenviando(
                renovar: { "token-novo" },
                reenviar: { _ -> Int in throw erroServidor(status) },
                deslogar: { r.deslogar() }
            )
        } throws: { erro in
            return ehErroServidor(erro, status)
        }
        #expect(r.deslogadas == 0)
    }

    @Test func refreshCom401DeslogaEUmErroDeAutenticacao() async {
        let r = Registro()
        await #expect {
            _ = try await renovandoEReenviando(
                renovar: { throw erroServidor(401) },
                reenviar: { _ -> Int in 42 },
                deslogar: { r.deslogar() }
            )
        } throws: { erro in
            guard case APIError.authentication = erro else { return false }
            return true
        }
        #expect(r.deslogadas == 1)
    }

    @Test func refreshCom429NaoDeslogaESobeO429() async {
        let r = Registro()
        await #expect {
            _ = try await renovandoEReenviando(
                renovar: { throw erroServidor(429) },
                reenviar: { _ -> Int in 42 },
                deslogar: { r.deslogar() }
            )
        } throws: { erro in
            return ehErroServidor(erro, 429)
        }
        #expect(r.deslogadas == 0)
    }

    @Test func tudoOkDevolveOValorEOReenvioRecebeuOToken() async throws {
        let r = Registro()
        let valor = try await renovandoEReenviando(
            renovar: { "token-novo" },
            reenviar: { token in
                r.recebeu(token: token)
                return "resposta"
            },
            deslogar: { r.deslogar() }
        )
        #expect(valor == "resposta")
        #expect(r.tokenRecebido == "token-novo")
        #expect(r.deslogadas == 0)
    }

    @Test func cancelamentoNaoDeslogaNemRepete() {
        #expect(!deveDeslogarAposFalhaDeRefresh(URLError(.cancelled)))
        #expect(!deveDeslogarAposFalhaDeRefresh(CancellationError()))
        #expect(!ehFalhaTransitoriaDeRefresh(URLError(.cancelled)))
        #expect(ehFalhaTransitoriaDeRefresh(URLError(.timedOut)))
    }
}
