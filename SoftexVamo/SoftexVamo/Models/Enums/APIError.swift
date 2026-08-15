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
}
