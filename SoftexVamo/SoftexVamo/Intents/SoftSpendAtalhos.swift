import AppIntents

/// App Shortcuts (§1.3): faz "Registrar gasto" aparecer no Atalhos e na Siri
/// sem o usuário montar nada. Toda frase precisa conter `\(.applicationName)`
/// — a Apple exige o nome do app em cada uma.
struct SoftSpendAtalhos: AppShortcutsProvider {
    @AppShortcutsBuilder
    nonisolated static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RegistrarGastoIntent(),
            phrases: [
                "Registrar gasto no \(.applicationName)",
                "Registrar gasto pelo \(.applicationName)",
                "Anotar compra no \(.applicationName)"
            ],
            shortTitle: "Registrar gasto",
            systemImageName: "creditcard"
        )
    }
}
