//
//  ComprovanteCrypto.swift
//  SoftexVamo
//

import Foundation
import CryptoKit
import Security
import os

nonisolated enum ComprovanteCryptoError: Error, LocalizedError, Equatable {
    /// O Keychain não entregou a chave agora (ex.: iPhone trancado). A chave
    /// existe e volta depois: nada pode ser apagado nem recriado.
    case keyNotAvailable
    case encryptionFailed
    case decryptionFailed
    case invalidKeySize

    var errorDescription: String? {
        switch self {
        case .keyNotAvailable: return "Nota fiscal indisponível no momento (iPhone bloqueado?)"
        case .encryptionFailed: return "Falha ao proteger a nota fiscal"
        case .decryptionFailed: return "Falha ao abrir a nota fiscal"
        case .invalidKeySize: return "Chave da nota fiscal inválida"
        }
    }
}

/// Resultado da busca da chave no armazém.
nonisolated enum ResultadoBuscaChave: Equatable, Sendable {
    case achou(Data)
    /// O armazém respondeu que a chave não existe (`errSecItemNotFound`).
    case naoExiste
    /// Qualquer outro status: a chave pode existir, mas não está acessível agora.
    case indisponivel(OSStatus)
}

/// Erro do armazém com o status do Keychain (`errSecDuplicateItem` = outra
/// chamada criou a chave antes).
nonisolated struct ErroDoArmazemDeChave: Error, Equatable {
    let status: OSStatus
}

/// Onde a chave das notas fica guardada. Em produção o Keychain
/// (`ArmazemDeChaveKeychain`); nos testes, um armazém em memória.
nonisolated protocol ArmazemDeChave: Sendable {
    func buscar() -> ResultadoBuscaChave
    /// Só adiciona, nunca substitui. Chave já existente lança
    /// `ErroDoArmazemDeChave(status: errSecDuplicateItem)`.
    func adicionar(_ chave: Data) throws
}

nonisolated struct ArmazemDeChaveKeychain: ArmazemDeChave {
    private let keyTag = "br.com.softspend.comprovantekey".data(using: .utf8)!

    func buscar() -> ResultadoBuscaChave {
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
            guard let data = result as? Data else { return .indisponivel(status) }
            return .achou(data)
        case errSecItemNotFound:
            return .naoExiste
        default:
            return .indisponivel(status)
        }
    }

    func adicionar(_ chave: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecValueData as String: chave,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrKeyClass as String: kSecAttrKeyClassSymmetric,
            kSecAttrKeySizeInBits as String: 256
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ErroDoArmazemDeChave(status: status)
        }
    }
}

/// Cifra as notas fiscais guardadas no aparelho (AES-GCM, chave de 256 bits).
///
/// A chave só é criada quando o armazém responde que ela não existe. Qualquer
/// outra falha de leitura (ex.: `errSecInteractionNotAllowed` com o iPhone
/// trancado) lança `keyNotAvailable`: criar outra chave deixaria todas as notas
/// já guardadas ilegíveis para sempre. Nunca há `SecItemDelete`.
nonisolated struct ComprovanteCrypto: Sendable {
    static let shared = ComprovanteCrypto(armazem: ArmazemDeChaveKeychain())

    private let armazem: any ArmazemDeChave
    private static let logger = Logger(subsystem: "br.com.softspend", category: "ComprovanteCrypto")
    private static let tamanhoDaChave = 32

    init(armazem: any ArmazemDeChave) {
        self.armazem = armazem
    }

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
        switch armazem.buscar() {
        case .achou(let data):
            return try chave(de: data)
        case .indisponivel(let status):
            Self.logger.error("ComprovanteCrypto: chave indisponível no Keychain (status \(status, privacy: .public))")
            throw ComprovanteCryptoError.keyNotAvailable
        case .naoExiste:
            return try criarChave()
        }
    }

    private func criarChave() throws -> SymmetricKey {
        let novaChave = SymmetricKey(size: .bits256)
        let data = novaChave.withUnsafeBytes { Data($0) }
        do {
            try armazem.adicionar(data)
            return novaChave
        } catch let erro as ErroDoArmazemDeChave where erro.status == errSecDuplicateItem {
            // Outra chamada criou a chave entre a busca e o add: vale a que está lá.
            if case .achou(let existente) = armazem.buscar() {
                return try chave(de: existente)
            }
            Self.logger.error("ComprovanteCrypto: chave duplicada, mas a releitura falhou")
            throw ComprovanteCryptoError.keyNotAvailable
        } catch {
            Self.logger.error("ComprovanteCrypto: falha ao gravar a chave nova: \(String(describing: error), privacy: .public)")
            throw ComprovanteCryptoError.keyNotAvailable
        }
    }

    private func chave(de data: Data) throws -> SymmetricKey {
        guard data.count == Self.tamanhoDaChave else {
            Self.logger.error("ComprovanteCrypto: chave com \(data.count, privacy: .public) bytes no Keychain")
            throw ComprovanteCryptoError.invalidKeySize
        }
        return SymmetricKey(data: data)
    }
}
