//
//  RegraSenha.swift
//  SoftSpend
//

import Foundation

/// Requisitos de senha do cadastro e da senha nova do "Esqueci minha senha" —
/// os mesmos do servidor (`_validar_senha_forte` em `Python/dtos/auth.py`).
nonisolated struct RegraSenha: Equatable, Sendable {
    let senha: String

    static let especiais = "!@#$%^&*()_+-=[]{}|;:',.<>?/~`"

    var temMinimo: Bool { senha.count >= 8 }
    var cabeNoMaximo: Bool { senha.count <= 128 }
    var temMaiuscula: Bool { senha.contains(where: { $0.isUppercase }) }
    var temMinuscula: Bool { senha.contains(where: { $0.isLowercase }) }
    var temNumero: Bool { senha.contains(where: { $0.isNumber }) }
    var temEspecial: Bool { senha.contains(where: { Self.especiais.contains($0) }) }

    var valida: Bool {
        temMinimo && cabeNoMaximo && temMaiuscula && temMinuscula && temNumero && temEspecial
    }
}
