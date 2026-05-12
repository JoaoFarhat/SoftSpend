//
//  APIConfig.swift
//  SoftexVamo
//

import Foundation

enum APIEnvironment: String, CaseIterable {
    case local
    case production
    
    var baseURL: String {
        switch self {
        case .local:
            return Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL_LOCAL") as? String
                ?? "http://localhost:8000"
        case .production:
            return "https://softspend-production.up.railway.app"
        }
    }
    
    var displayName: String {
        switch self {
        case .local: return "Local"
        case .production: return "Produção"
        }
    }
}

final class APIConfig {
    static let shared = APIConfig()
    
    private let key = "api_environment"
    
    private init() {}
    
    var current: APIEnvironment {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let env = APIEnvironment(rawValue: raw) {
                return env
            }
            #if DEBUG
            return .local
            #else
            return .production
            #endif
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
    
    var baseURL: String {
        current.baseURL
    }
}
