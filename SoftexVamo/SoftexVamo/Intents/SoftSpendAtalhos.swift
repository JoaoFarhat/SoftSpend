//
//  SoftSpendAtalhos.swift
//  SoftexVamo
//
//  App Shortcuts do SoftSpend (§1.3 de docs/cartao-sem-open-finance.md).
//

import AppIntents

/// Faz a ação "Registrar gasto" aparecer no app Atalhos e na Siri sem o
/// usuário montar nada. A Apple exige o nome do app (`\(.applicationName)`)
/// em toda frase.
nonisolated struct SoftSpendAtalhos: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RegistrarGastoIntent(),
            phrases: [
                "Registrar gasto no \(.applicationName)",
                "Lançar gasto no \(.applicationName)",
                "Anotar compra no \(.applicationName)",
            ],
            shortTitle: "Registrar gasto",
            systemImageName: "creditcard"
        )
    }
}
