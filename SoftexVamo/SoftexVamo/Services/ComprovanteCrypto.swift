//
//  ComprovanteCrypto.swift
//  SoftexVamo
//

import Foundation
import CryptoKit
import Security
import os

enum ComprovanteCryptoError: Error {
    case keyNotAvailable
    case encryptionFailed
    case decryptionFailed
    case invalidKeySize
}

/// Cifra e decifra a nota do comprovante.
///
/// Existe para o `SyncActor` receber a cifra injetada (como o `SyncAPI`):
/// em produção é o `ComprovanteCrypto.shared`; nos testes, uma implementação
/// em memória (`FakeCifrador`) lança `ComprovanteCryptoError.keyNotAvailable`
/// e simula o Keychain inacessível com o aparelho bloqueado.
nonisolated protocol CifradorComprovante: Sendable {
    func criptografar(_ dados: Data) throws -> Data
    func descriptografar(_ dados: Data) throws -> Data
}

nonisolated struct ComprovanteCrypto {
    static let shared = ComprovanteCrypto()
    private let keyTag = "br.com.softspend.comprovantekey".data(using: .utf8)!
    private let logger = Logger(subsystem: "br.com.softspend", category: "ComprovanteCrypto")

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
        switch buscarChaveNoKeychain() {
        case .encontrada(let data):
            return SymmetricKey(data: data)
        case .inacessivel(let status):
            logger.debug("ComprovanteCrypto: chave inacessível no Keychain (status \(status, privacy: .public))")
            throw ComprovanteCryptoError.keyNotAvailable
        case .naoExiste:
            break
        }

        let novaChave = SymmetricKey(size: .bits256)
        let data = novaChave.withUnsafeBytes { Data($0) }
        try salvarChaveNoKeychain(data)
        return novaChave
    }

    /// O `errSecItemNotFound` ("não existe", pode criar) fica separado dos
    /// demais erros. Com o aparelho bloqueado o Keychain responde
    /// `errSecInteractionNotAllowed` — a chave é `WhenUnlockedThisDeviceOnly`
    /// — e tratar isso como "não existe" faria o `SecItemDelete` apagar a
    /// chave boa na tentativa de criar outra (o `SecItemAdd` falharia do
    /// mesmo jeito): uma leitura com o iPhone trancado destruiria a chave e
    /// todas as notas guardadas.
    private enum BuscaChave {
        case encontrada(Data)
        case naoExiste
        case inacessivel(OSStatus)
    }

    private func buscarChaveNoKeychain() -> BuscaChave {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let data = result as? Data { return .encontrada(data) }
            return .inacessivel(status)
        case errSecItemNotFound:
            return .naoExiste
        default:
            return .inacessivel(status)
        }
    }
    
    private func salvarChaveNoKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrKeyClass as String: kSecAttrKeyClassSymmetric,
            kSecAttrKeySizeInBits as String: 256
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            logger.warning("ComprovanteCrypto: SecItemDelete retornou status inesperado \(deleteStatus, privacy: .public)")
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ComprovanteCryptoError.keyNotAvailable
        }
    }
}

nonisolated extension ComprovanteCrypto: CifradorComprovante {}
