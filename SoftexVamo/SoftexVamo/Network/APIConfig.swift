//
//  APIConfig.swift
//  SoftexVamo
//

import Foundation

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
