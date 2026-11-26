//
//  KeychainManager.swift
//  SoftSpend
//
//  Created by Joao Victor on 11/05/26.
//

import Security
import Foundation
import os

/// Resultado de ler um token do Keychain — o mesmo contrato do
/// `ResultadoBuscaChave` do `ArmazemDeChave`:
///
/// - `.achou`: o token.
/// - `.naoExiste`: não há token guardado (`errSecItemNotFound`, ou bytes que
///   não viram texto). Sem login: o fluxo antigo segue (401 → logout).
/// - `.indisponivel(status)`: o token pode estar lá, mas o Keychain não o
///   entrega agora (ex.: `errSecInteractionNotAllowed` com o iPhone trancado —
///   os tokens são `WhenUnlockedThisDeviceOnly`). Nunca vira logout.
/// - `.ilegivel(status)`: o Keychain recusou a leitura de um jeito que o
///   desbloqueio não resolve (§2 de docs/keychain-login.md). O pedido não
///   sai e a pessoa entra de novo.
nonisolated enum ResultadoLeituraToken: Equatable, Sendable {
    case achou(String)
    case naoExiste
    case indisponivel(OSStatus)
    case ilegivel(OSStatus)

    /// O token, só quando `.achou`.
    var token: String? {
        if case .achou(let token) = self { return token }
        return nil
    }

    /// `.achou` com o token, `.naoExiste` sem ele. Usado pelo padrão do
    /// `CofreDeTokens.buscarAccessToken()` para cofres que só sabem `String?`.
    init(_ token: String?) {
        self = token.map(ResultadoLeituraToken.achou) ?? .naoExiste
    }
}

/// O `status` da leitura pede esperar o desbloqueio (`.indisponivel`)? Só
/// dois: `errSecInteractionNotAllowed` (-25308, iPhone trancado) e
/// `errSecNotAvailable` (-25291, ainda não houve o primeiro desbloqueio
/// depois de ligar). Qualquer outro é `.ilegivel` — ficar em "Desbloqueie
/// o iPhone" num erro que o desbloqueio não resolve prenderia a pessoa
/// para sempre (§2.1 de docs/keychain-login.md).
nonisolated func statusEsperaDesbloqueio(_ status: OSStatus) -> Bool {
    status == errSecInteractionNotAllowed || status == errSecNotAvailable
}

/// `.indisponivel` com o iPhone claramente destrancado (app ativo e dados
/// protegidos disponíveis) não é espera de desbloqueio: vira `.ilegivel` —
/// sem isso o app ficaria em "Desbloqueie o iPhone" com o aparelho aberto
/// na mão (§2.1). Qualquer outro resultado passa sem mudança.
nonisolated func ajustarLeituraAoEstadoDoIPhone(
    _ resultado: ResultadoLeituraToken,
    iPhoneProvavelmenteTrancado: Bool
) -> ResultadoLeituraToken {
    if case .indisponivel(let status) = resultado, !iPhoneProvavelmenteTrancado {
        return .ilegivel(status)
    }
    return resultado
}

/// Resultado de gravar um token no Keychain (§1 de docs/keychain-login.md):
/// `.gravou` ou `.recusou(OSStatus)`. A recusa numa renovação manda o par
/// novo para a memória; na entrada (login/cadastro) fecha o acesso.
nonisolated enum ResultadoGravacaoToken: Equatable, Sendable {
    case gravou
    case recusou(OSStatus)
}

nonisolated struct KeychainManager {

    private static let accessTokenKey = "br.com.softspend.app.access_token"
    private static let refreshTokenKey = "br.com.softspend.app.refresh_token"
    private static let logger = Logger(subsystem: "br.com.softspend", category: "KeychainManager")

    // MARK: - Access Token

    nonisolated static func saveAccessToken(_ token: String) -> ResultadoGravacaoToken {
        save(token, forKey: accessTokenKey)
    }

    /// `nil` tanto sem token quanto com o Keychain trancado. Quem precisa
    /// separar os dois (o `NetworkManager`) usa `lerAccessToken()`.
    nonisolated static func getAccessToken() -> String? {
        lerAccessToken().token
    }

    nonisolated static func lerAccessToken() -> ResultadoLeituraToken {
        read(forKey: accessTokenKey)
    }

    // MARK: - Refresh Token

    nonisolated static func saveRefreshToken(_ token: String) -> ResultadoGravacaoToken {
        save(token, forKey: refreshTokenKey)
    }

    nonisolated static func getRefreshToken() -> String? {
        lerRefreshToken().token
    }

    nonisolated static func lerRefreshToken() -> ResultadoLeituraToken {
        read(forKey: refreshTokenKey)
    }

    // MARK: - Clear

    nonisolated static func deleteAllTokens() {
        delete(forKey: accessTokenKey)
        delete(forKey: refreshTokenKey)
    }

    // MARK: - Helpers

    /// Grava por cima com `SecItemUpdate` e só cria (`SecItemAdd`) quando o
    /// update diz que o item não existe. Nunca apaga antes de gravar: com o
    /// iPhone trancado o add pode falhar, e o delete anterior deixava a pessoa
    /// sem token nenhum (logout na próxima requisição). O resultado diz quem
    /// chamou se o par novo precisa viver em memória (§1 de
    /// docs/keychain-login.md).
    private nonisolated static func save(_ token: String, forKey key: String) -> ResultadoGravacaoToken {
        guard let data = token.data(using: .utf8) else {
            logger.error("Falha ao converter token para Data")
            return .recusou(errSecParam)
        }

        let busca: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let atributos: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let statusUpdate = SecItemUpdate(busca as CFDictionary, atributos as CFDictionary)
        if statusUpdate == errSecSuccess { return .gravou }
        guard statusUpdate == errSecItemNotFound else {
            logger.error("Falha ao atualizar token no Keychain: status \(statusUpdate, privacy: .public)")
            return .recusou(statusUpdate)
        }

        var novo = busca
        novo.merge(atributos) { _, valor in valor }
        let statusAdd = SecItemAdd(novo as CFDictionary, nil)
        if statusAdd != errSecSuccess {
            logger.error("Falha ao salvar token no Keychain: status \(statusAdd, privacy: .public)")
            return .recusou(statusAdd)
        }
        return .gravou
    }

    private nonisolated static func read(forKey key: String) -> ResultadoLeituraToken {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return .naoExiste }
        guard status == errSecSuccess else {
            if statusEsperaDesbloqueio(status) {
                logger.warning("Token ilegível agora no Keychain: status \(status, privacy: .public)")
                return .indisponivel(status)
            }
            // O desbloqueio não resolve: a sessão deste aparelho acabou.
            logger.error("Token ilegível de vez no Keychain: status \(status, privacy: .public)")
            return .ilegivel(status)
        }
        // Bytes que não viram texto não voltam sozinhos: tratar como
        // "indisponível" prenderia a pessoa em "Desbloqueie o iPhone" para sempre.
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return .naoExiste
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

        return .achou(token)
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
