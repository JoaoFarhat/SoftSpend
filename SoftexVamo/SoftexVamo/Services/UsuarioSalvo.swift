import Foundation

/// O `userId` do usuário logado **sem passar pelo Keychain** (§1.3 de
/// `docs/cartao-sem-open-finance.md`).
///
/// O token fica no Keychain com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// (`KeychainManager`), ou seja, ilegível com o iPhone trancado — e é aí que a
/// compra do Apple Watch acorda o app em segundo plano. O `user_data` do
/// `UserDefaults` é o mesmo JSON `UserDTO` que o `AuthService` grava no login e
/// basta para gravar no aparelho, que não exige token.
nonisolated enum UsuarioSalvo {
    /// Mesma chave `userKey` do `AuthService`.
    static let chave = "user_data"

    /// O id do usuário logado, ou `nil` se nunca logou ou saiu da conta.
    /// Tudo no app filtra por `userId`, então a compra nunca cai na conta errada.
    static func id(em defaults: UserDefaults = .standard) -> String? {
        guard let data = defaults.data(forKey: chave),
              let dto = try? JSONDecoder().decode(UserDTO.self, from: data),
              !dto.id.isEmpty else { return nil }
        return dto.id
    }
}
