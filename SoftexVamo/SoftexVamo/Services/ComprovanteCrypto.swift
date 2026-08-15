//
//  ComprovanteCrypto.swift
//  SoftexVamo
//

import Foundation
import CryptoKit
import Security

enum ComprovanteCryptoError: Error {
    case keyNotAvailable
    case encryptionFailed
    case decryptionFailed
    case invalidKeySize
}

struct ComprovanteCrypto {
    static let shared = ComprovanteCrypto()
    private let keyTag = "br.com.softspend.comprovantekey".data(using: .utf8)!
    
    private init() {}
    
    func criptografar(_ data: Data) throws -> Data {
        let key = try obterOuCriarChave()
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        guard let combined = sealedBox.combined else {
            throw ComprovanteCryptoError.encryptionFailed
        }
        return combined
    }
    
    func descriptografar(_ combined: Data) throws -> Data {
        let key = try obterOuCriarChave()
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    private func obterOuCriarChave() throws -> SymmetricKey {
        if let data = buscarChaveNoKeychain() {
            return SymmetricKey(data: data)
        }
        
        let novaChave = SymmetricKey(size: .bits256)
        let data = novaChave.withUnsafeBytes { Data($0) }
        try salvarChaveNoKeychain(data)
        return novaChave
    }
    
    private func buscarChaveNoKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
    
    private func salvarChaveNoKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ComprovanteCryptoError.keyNotAvailable
        }
    }
}
