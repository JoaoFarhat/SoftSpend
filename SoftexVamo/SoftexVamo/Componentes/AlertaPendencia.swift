import SwiftUI

/// "1 gasto sem foto" / "N gastos sem foto".
nonisolated func textoGastosSemFoto(_ quantidade: Int) -> String {
    quantidade == 1 ? "1 gasto sem foto" : "\(quantidade) gastos sem foto"
}

/// Faixa de pendência: "N gastos sem foto" + "Adicionar". Some quando não há pendência.
struct AlertaPendencia: View {
    let quantidade: Int
    let aoAdicionar: () -> Void

    var body: some View {
        if quantidade > 0 {
            Button(action: aoAdicionar) {
                HStack(spacing: Espaco.p) {
                    Text(textoGastosSemFoto(quantidade))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Espaco.p)
                    Text("Adicionar")
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .foregroundStyle(Tema.alertaTexto)
                .padding(.horizontal, Espaco.g)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Tema.alertaFundo, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(textoGastosSemFoto(quantidade))
            .accessibilityHint("Adicionar as fotos")
            .accessibilityAddTraits(.isButton)
        }
    }
}

private struct AlertaExemplo: View {
    var body: some View {
        VStack(spacing: 12) {
            AlertaPendencia(quantidade: 2) {}
            AlertaPendencia(quantidade: 1) {}
            AlertaPendencia(quantidade: 0) {}
        }
        .padding()
        .background(Tema.fundo)
    }
}

#Preview("Claro") { AlertaExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { AlertaExemplo().preferredColorScheme(.dark) }
