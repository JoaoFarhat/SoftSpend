//
//  RedefinicaoSenhaAPI.swift
//  SoftSpend
//

import Foundation

/// Rotas do "Esqueci minha senha", usadas pelo `RedefinirSenhaViewModel`.
/// Protocolo para os testes usarem uma API falsa
/// (`SoftSpendTests/FakeRedefinicaoSenhaAPI.swift`); em produção é o `NetworkManager`.
nonisolated protocol RedefinicaoSenhaAPI: Sendable {
    /// `POST /auth/senha/esqueci`: `202` igual com ou sem conta; `503 email_unavailable`
    /// quando o servidor ainda não envia e-mail.
    func pedirCodigoRedefinicao(email: String) async throws -> EsqueciSenhaResponse

    /// `POST /auth/senha/redefinir`: `204`; `400 invalid_reset_code` para código
    /// errado, expirado, já usado ou sem pedido.
    func redefinirSenha(email: String, codigo: String, novaSenha: String) async throws
}

nonisolated extension NetworkManager: RedefinicaoSenhaAPI {}
