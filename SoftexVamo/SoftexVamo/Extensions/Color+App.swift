import SwiftUI

extension Color {
    /// Roxo principal — botões, ícones, destaques (#9333EA)
    static let appPurple = Color("purplePrimary")
    
    /// Roxo escuro — cor final de gradientes (#6D28D9)
    static let appPurpleDark = Color("roxoFinal")

    /// Cria uma cor que se adapta automaticamente ao color scheme.
    static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

extension LinearGradient {
    /// Gradiente padrão roxo do app (topLeading → bottomTrailing)
    static let appPurple = LinearGradient(
        colors: [.appPurple, .appPurpleDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Gradiente do card principal — diagonal, roxo no topo-direita → preto no canto inferior-esquerdo
    static let cardMain = LinearGradient(
        stops: [
            .init(color: .dynamic(light: 0xA855F7, dark: 0x6D28D9), location: 0.0),
            .init(color: .dynamic(light: 0x7C3AED, dark: 0x4C1D95), location: 0.4),
            .init(color: .dynamic(light: 0x4C1D95, dark: 0x1E0A3C), location: 0.75),
            .init(color: .dynamic(light: 0x2E1065, dark: 0x050008), location: 1.0),
        ],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    
    
    
    
}
