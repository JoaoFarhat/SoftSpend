//
//  APIError.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import Foundation

nonisolated enum APIError: LocalizedError, Sendable {
    case serverError(message: String, requestId: String, statusCode: Int)
    case authentication
    case unknown

    var errorDescription: String? {
        switch self {
        case .serverError(let message, _, let statusCode):
            if statusCode == 422 && message == Self.codigoTotalViagemAcimaDoLimite {
                return "O total da viagem passaria de R$ 99.999.999,99. Diminua o valor ou apague outro gasto."
            }
            return message
        case .authentication:
            return "Sessão expirada. Faça login novamente."
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

    /// Código que o servidor manda no corpo do 429 quando acaba a cota
    /// diária de leituras por IA (`{"error": "daily_ai_limit"}`,
    /// `services/limite_ia.py`). O outro 429 (por minuto, slowapi) chega
    /// com a mensagem do rate limit e segue no aviso de "espere um minuto".
    static let codigoLimiteDiarioIA = "daily_ai_limit"

    /// O servidor recusou porque a cota diária de leituras por IA do usuário
    /// acabou: `429` com o código `daily_ai_limit` — só libera no dia
    /// seguinte. Outro 429 (o por minuto) não conta.
    var limiteDiarioIA: Bool {
        if case .serverError(let message, _, let statusCode) = self {
            return statusCode == 429 && message == Self.codigoLimiteDiarioIA
        }
        return false
    }

    /// Código que o servidor manda no corpo do 422 quando um gasto levaria o
    /// total da viagem além de R$ 99.999.999,99. O `errorDescription` troca
    /// esse código por uma frase em português — sem isso o `syncError`
    /// mostrava o código cru na tela.
    static let codigoTotalViagemAcimaDoLimite = "total_da_viagem_acima_do_limite"
}
