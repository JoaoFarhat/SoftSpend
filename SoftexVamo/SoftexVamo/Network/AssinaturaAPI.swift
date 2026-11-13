//
//  AssinaturaAPI.swift
//  SoftSpend
//

import Foundation

/// Rotas da assinatura (docs/assinatura.md §2.3), usadas pelo
/// `AssinaturaViewModel`. Protocolo para os testes usarem uma API falsa
/// (`SoftSpendTests/FakeAssinaturaAPI.swift`); em produção é o `NetworkManager`.
nonisolated protocol AssinaturaAPI: Sendable {
    /// `GET /api/assinatura`: estado, `tem_acesso` e o `app_account_token`.
    func obterAssinatura() async throws -> AssinaturaResponse

    /// `POST /api/assinatura/transacoes` com o JWS da compra. Responde o mesmo
    /// corpo do `GET`. `409` = a compra é de outra conta do SoftSpend.
    func enviarTransacaoAssinatura(jws: String) async throws -> AssinaturaResponse
}

nonisolated extension NetworkManager: AssinaturaAPI {}
