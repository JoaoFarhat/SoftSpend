//
//  ComprovanteCrypto.swift
//  SoftexVamo
//
//  A chave das notas fiscais só pode ser CRIADA quando o Keychain responde
//  que ela não existe (`errSecItemNotFound`). Qualquer outro status —
//  `errSecInteractionNotAllowed` com o iPhone travado (sync em segundo
//  plano, atalho do Apple Pay), erro transitório — é "indisponível agora",
//  não "não existe": `obterOuCriarChave` lança `keyNotAvailable` sem criar
//  nada. A versão anterior tratava qualquer status como "não existe" e ainda
//  apagava a chave antiga antes de gravar a nova: uma leitura com o
//  aparelho travado tornava ilegíveis para sempre todas as notas guardadas
//  — e o sync oferecia "Descartar nota" para notas boas.
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

/// O mínimo do Keychain que o `ComprovanteCrypto` usa: buscar a chave
/// (devolve o status do `SecItemCopyMatching` e os dados, se houver) e
/// adicionar (devolve o status do `SecItemAdd`).
///
/// Existe para os testes simularem os status — `errSecInteractionNotAllowed`
/// do aparelho travado, `errSecDuplicateItem` de duas threads criando a
/// chave ao mesmo tempo — sem tocar no Keychain de verdade
/// (`SoftSpendTests/ChaveComprovanteTests.swift`). `nonisolated` como o
/// `SyncAPI`: o `SyncActor` acessa de background (ver "Isolamento de actor"
/// no `AGENTS.md`).
nonisolated protocol ComprovanteKeychain: Sendable {
    func buscar() -> (status: OSStatus, dados: Data?)
    func adicionar(_ dados: Data) -> OSStatus
}

/// O Keychain do aparelho (`SecItem*`): a implementação usada em produção.
nonisolated struct KeychainComprovante: ComprovanteKeychain {
    private let keyTag = "br.com.softspend.comprovantekey".data(using: .utf8)!

    func buscar() -> (status: OSStatus, dados: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func adicionar(_ dados: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecValueData as String: dados,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrKeyClass as String: kSecAttrKeyClassSymmetric,
            kSecAttrKeySizeInBits as String: 256
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }
}

nonisolated struct ComprovanteCrypto {
    static let shared = ComprovanteCrypto()
    private let keychain: any ComprovanteKeychain
    private let logger = Logger(subsystem: "br.com.softspend", category: "ComprovanteCrypto")

    /// Produção usa o `KeychainComprovante` (padrão); os testes passam um falso.
    init(keychain: any ComprovanteKeychain = KeychainComprovante()) {
        self.keychain = keychain
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

    /// `errSecSuccess` usa a chave; só `errSecItemNotFound` cria e grava.
    /// Qualquer outro status lança `keyNotAvailable` sem criar nada — ver o
    /// comentário no topo do arquivo.
    private func obterOuCriarChave() throws -> SymmetricKey {
        let (status, dados) = keychain.buscar()
        switch status {
        case errSecSuccess:
            guard let dados else {
                logger.error("ComprovanteCrypto: busca com sucesso mas sem dados")
                throw ComprovanteCryptoError.keyNotAvailable
            }
            return SymmetricKey(data: dados)
        case errSecItemNotFound:
            let novaChave = SymmetricKey(size: .bits256)
            let dadosNovos = novaChave.withUnsafeBytes { Data($0) }
            return try salvarChaveNoKeychain(dadosNovos)
        default:
            logger.warning("ComprovanteCrypto: Keychain indisponível (status \(status, privacy: .public)), chave não criada")
            throw ComprovanteCryptoError.keyNotAvailable
        }
    }

    /// Sem `SecItemDelete` antes do `SecItemAdd` — apagar a chave antiga
    /// tornava as notas guardadas ilegíveis para sempre. Com
    /// `errSecDuplicateItem` (outra thread criou a chave ao mesmo tempo),
    /// relê e usa a que já está lá.
    private func salvarChaveNoKeychain(_ dados: Data) throws -> SymmetricKey {
        switch keychain.adicionar(dados) {
        case errSecSuccess:
            return SymmetricKey(data: dados)
        case errSecDuplicateItem:
            let (status, existente) = keychain.buscar()
            guard status == errSecSuccess, let existente else {
                throw ComprovanteCryptoError.keyNotAvailable
            }
            return SymmetricKey(data: existente)
        default:
            throw ComprovanteCryptoError.keyNotAvailable
        }
    }
}
