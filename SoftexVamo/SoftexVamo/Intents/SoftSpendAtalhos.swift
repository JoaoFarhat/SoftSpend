import AppIntents

/// Atalhos prontos do SoftSpend (§1.3 de `docs/cartao-sem-open-finance.md`):
/// faz "Registrar gasto" aparecer no app Atalhos — para a automação
/// "Transação" do Apple Pay — e na Siri sem o usuário montar nada. A Apple
/// exige o nome do app (`\(.applicationName)`) em toda frase.
nonisolated struct SoftSpendAtalhos: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .lightBlue }

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RegistrarGastoIntent(),
            phrases: [
                "Registrar gasto no \(.applicationName)",
                "Registrar compra no \(.applicationName)",
                "Anotar gasto do cartão no \(.applicationName)",
            ],
            shortTitle: "Registrar gasto",
            systemImageName: "creditcard.fill"
        )
    }
}
