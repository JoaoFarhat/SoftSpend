//
//  KeychainManager.swift
//  SoftSpend
//
//  Created by Joao Victor on 11/05/26.
//

import Security
import Foundation
import os

nonisolated struct KeychainManager {

    private static let tokenKey = "com.joao.softspend.jwt_token"
    private static let logger = Logger(subsystem: "br.com.softspend", category: "KeychainManager")

    nonisolated static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else {
            logger.error("Falha ao converter token para Data")
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Falha ao salvar token no Keychain: status \(status, privacy: .public)")
        }
    }
    
    nonisolated static func getToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Migra tokens antigos (salvos sem acessibilidade explícita ou com
        // configuração mais fraca) para kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
        migrateAccessibilityIfNeeded()
        
        return token
    }
    
    nonisolated private static func migrateAccessibilityIfNeeded() {
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey
        ]
        let attributesToUpdate: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("Falha ao migrar acessibilidade do token: status \(status, privacy: .public)")
        }
    }
    
    nonisolated static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
