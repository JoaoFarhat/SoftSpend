//
//  APIEnvironmentEnum.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//
import Foundation

nonisolated enum APIEnvironment: String, CaseIterable, Sendable {
    case local
    case production
    
    var baseURL: String {
        switch self {
        case .local:
            // No simulador o loopback do host (Mac) é o único endereço confiável.
            // Endereços IPv4 literais (192.168.x.x) costumam falhar com NAT64.
            #if targetEnvironment(simulator)
            return "http://localhost:8000"
            #else
            return Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL_LOCAL") as? String
                ?? "http://localhost:8000"
            #endif
        case .production:
            return "https://softspend.com.br"
        }
    }
    
    var displayName: String {
        switch self {
        case .local: return "Local"
        case .production: return "Produção"
        }
    }
}
