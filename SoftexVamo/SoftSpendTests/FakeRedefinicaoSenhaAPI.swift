import Foundation
@testable import SoftSpend

/// `RedefinicaoSenhaAPI` em memória: guarda as chamadas e responde o que o teste mandar.
final class FakeRedefinicaoSenhaAPI: RedefinicaoSenhaAPI, @unchecked Sendable {
    enum Chamada: Equatable {
        case pedir(email: String)
        case redefinir(email: String, codigo: String, novaSenha: String)
    }

    private let trava = NSLock()
    private var _chamadas: [Chamada] = []
    var chamadas: [Chamada] { trava.withLock { _chamadas } }

    var resposta = EsqueciSenhaResponse(expiresInSeconds: 900, resendAfterSeconds: 60)
    var erroAoPedir: Error?
    var erroAoRedefinir: Error?

    func pedirCodigoRedefinicao(email: String) async throws -> EsqueciSenhaResponse {
        trava.withLock { _chamadas.append(.pedir(email: email)) }
        if let erroAoPedir { throw erroAoPedir }
        return resposta
    }

    func redefinirSenha(email: String, codigo: String, novaSenha: String) async throws {
        trava.withLock { _chamadas.append(.redefinir(email: email, codigo: codigo, novaSenha: novaSenha)) }
        if let erroAoRedefinir { throw erroAoRedefinir }
    }
}
