import Foundation

/// `userId` sem token (§1.3 de docs/cartao-sem-open-finance.md).
///
/// O token fica no Keychain com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// (`KeychainManager`), ilegível com o iPhone trancado — e é com o aparelho
/// trancado que a compra do Apple Watch acorda a ação de Atalhos. Por isso a
/// ação não usa `AuthService`: lê o mesmo `user_data` do `UserDefaults` que o
/// login grava (o `UserDTO`), só para saber de quem é o gasto. Gravar no
/// SwiftData não exige token.
nonisolated enum UsuarioSalvo {
    /// Mesma chave que o `AuthService` usa para o `user_data`.
    static let chave = "user_data"

    /// O `id` do usuário salvo, ou `nil` se nunca logou ou saiu da conta.
    static func id(em defaults: UserDefaults = .standard) -> String? {
        guard let dados = defaults.data(forKey: chave),
              let dto = try? JSONDecoder().decode(UserDTO.self, from: dados),
              !dto.id.isEmpty else { return nil }
        return dto.id
    }
}
