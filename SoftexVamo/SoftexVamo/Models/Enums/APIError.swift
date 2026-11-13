//
//  APIError.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import Foundation

nonisolated enum APIError: LocalizedError, Sendable {
    case serverError(message: String, requestId: String, statusCode: Int)
    case badURL
    case authentication
    case unknown

    var errorDescription: String? {
        switch self {
        case .serverError(let message, _, _):
            return message
        case .badURL:
            return "URL invalida"
        case .authentication:
            return "Sessao expirada. Faca login novamente."
        case .unknown:
            return "Erro inesperado"
        }
    }

    var requestId: String? {
        switch self {
        case .serverError(_, let requestId, _):
            return requestId
        default:
            return nil
        }
    }

    /// Código que o servidor manda no corpo do 403 quando a ação exige
    /// assinatura (`{"error": "subscription_required", ...}`, `docs/assinatura.md` §3.1).
    static let codigoAssinaturaNecessaria = "subscription_required"

    /// O servidor recusou porque a conta não tem assinatura ativa: `403` com o
    /// código `subscription_required`. Outro 403 (outra mensagem) não conta.
    /// Esse 403 nunca renova token nem desloga (`deveRenovarToken`).
    var assinaturaNecessaria: Bool {
        if case .serverError(let message, _, let statusCode) = self {
            return statusCode == 403 && message == Self.codigoAssinaturaNecessaria
        }
        return false
    }
}
