import SwiftUI

/// Largura de leitura no iPad (v1, decisão de 15/11): o conteúdo das telas
/// para em 700 pontos em vez de esticar por mais de mil no iPad 13".
nonisolated enum LarguraLegivel {
    static let maxima: CGFloat = 700
}

extension View {
    /// Limita a largura a `LarguraLegivel.maxima` e centraliza na largura
    /// disponível. No iPhone, mais estreito que 700, nada muda. Aplicar no
    /// conteúdo dentro do `ScrollView` — fundo e barra de navegação
    /// continuam de ponta a ponta.
    func larguraLegivel() -> some View {
        frame(maxWidth: LarguraLegivel.maxima)
            .frame(maxWidth: .infinity)
    }
}
