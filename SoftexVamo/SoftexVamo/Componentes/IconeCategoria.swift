import SwiftUI

/// Quadrado arredondado na cor da categoria com o SF Symbol em branco.
struct IconeCategoria: View {
    let categoria: Categoria
    let tamanho: CGFloat

    init(_ categoria: Categoria, tamanho: CGFloat = 30) {
        self.categoria = categoria
        self.tamanho = tamanho
    }

    /// "Outros" usa as reticências soltas: o círculo cheio branco pesaria demais.
    private var simbolo: String {
        categoria == .OUTROS ? "ellipsis" : categoria.systemImageName
    }

    var body: some View {
        RoundedRectangle(cornerRadius: tamanho * 0.27, style: .continuous)
            .fill(categoria.cor)
            .frame(width: tamanho, height: tamanho)
            .overlay {
                Image(systemName: simbolo)
                    .font(.system(size: tamanho * 0.46, weight: .semibold))
                    .foregroundStyle(Tema.sobreCor)
            }
            .accessibilityHidden(true)
    }
}

private struct IconesExemplo: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Categoria.allCases) { IconeCategoria($0, tamanho: 36) }
        }
        .padding()
        .background(Tema.fundo)
    }
}

#Preview("Claro") { IconesExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { IconesExemplo().preferredColorScheme(.dark) }
