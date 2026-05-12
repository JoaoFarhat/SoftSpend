import SwiftUI

extension Color {
    /// Roxo principal — botões, ícones, destaques (#9333EA)
    static let appPurple = Color("purplePrimary")
    
    /// Roxo escuro — cor final de gradientes (#6D28D9)
    static let appPurpleDark = Color("roxoFinal")
}

extension LinearGradient {
    /// Gradiente padrão roxo do app (topLeading → bottomTrailing)
    static let appPurple = LinearGradient(
        colors: [.appPurple, .appPurpleDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
