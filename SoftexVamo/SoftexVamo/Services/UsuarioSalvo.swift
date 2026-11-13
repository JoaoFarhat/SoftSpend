//
//  UsuarioSalvo.swift
//  SoftexVamo
//
//  Identifica o usuário logado sem depender do token (Apple Pay, §1.3).
//

import Foundation

/// `userId` do usuário logado, lido do `user_data` do `UserDefaults` — o mesmo
/// JSON `UserDTO` que o `AuthService` grava no login.
///
/// A ação "Registrar gasto" (Apple Pay) pode rodar com o iPhone trancado: o
/// token fica no Keychain com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
/// ilegível nessa hora, então `AuthService`/`checkAuthentication` não servem.
/// Gravar só no aparelho não exige token; sem `user_data` (nunca logou ou saiu
/// da conta) a ação recusa e não grava nada.
nonisolated enum UsuarioSalvo {
    /// Mesma chave `userKey` do `AuthService` (privada lá; duplicada de propósito
    /// para esta leitura não depender do serviço).
    static let chave = "user_data"

    static func id(defaults: UserDefaults = .standard) -> String? {
        guard let dados = defaults.data(forKey: chave),
              let dto = try? JSONDecoder().decode(UserDTO.self, from: dados),
              !dto.id.isEmpty else { return nil }
        return dto.id
    }
}
