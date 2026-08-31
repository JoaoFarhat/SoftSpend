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

    private static let accessTokenKey = "com.joao.softspend.access_token"
    private static let refreshTokenKey = "com.joao.softspend.refresh_token"
    private static let logger = Logger(subsystem: "br.com.softspend", category: "KeychainManager")

    // MARK: - Access Token

    nonisolated static func saveAccessToken(_ token: String) {
        save(token, forKey: accessTokenKey)
    }

    nonisolated static func getAccessToken() -> String? {
        return read(forKey: accessTokenKey)
    }

    // MARK: - Refresh Token

    nonisolated static func saveRefreshToken(_ token: String) {
        save(token, forKey: refreshTokenKey)
    }

    nonisolated static func getRefreshToken() -> String? {
        return read(forKey: refreshTokenKey)
    }

    // MARK: - Clear

    nonisolated static func deleteAllTokens() {
        delete(forKey: accessTokenKey)
        delete(forKey: refreshTokenKey)
    }

    // MARK: - Helpers

    private nonisolated static func save(_ token: String, forKey key: String) {
        guard let data = token.data(using: .utf8) else {
            logger.error("Falha ao converter token para Data")
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Falha ao salvar token no Keychain: status \(status, privacy: .public)")
        }
    }

    private nonisolated static func read(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Só reescreve o item quando a acessibilidade realmente diverge do
        // esperado (tokens salvos por versões antigas do app). Sem essa
        // checagem, toda leitura — e há uma por requisição HTTP — dispararia um
        // SecItemUpdate desnecessário.
        let acessibilidadeAtual = item[kSecAttrAccessible as String] as? String
        let acessibilidadeEsperada = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        if acessibilidadeAtual != acessibilidadeEsperada {
            migrateAccessibility(forKey: key)
        }

        return token
    }

    private nonisolated static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    private nonisolated static func migrateAccessibility(forKey key: String) {
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributesToUpdate: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("Falha ao migrar acessibilidade do token: status \(status, privacy: .public)")
        }
    }
}
