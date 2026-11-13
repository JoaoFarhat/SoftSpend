import SwiftUI

/// "1 gasto sem foto" / "N gastos sem foto".
nonisolated func textoGastosSemFoto(_ quantidade: Int) -> String {
    quantidade == 1 ? "1 gasto sem foto" : "\(quantidade) gastos sem foto"
}

/// "1 compra do Apple Pay esperando uma viagem" / "N compras ..." (fila do §1.5).
nonisolated func textoComprasApplePay(_ quantidade: Int) -> String {
    quantidade == 1 ? "1 compra do Apple Pay esperando uma viagem"
                    : "\(quantidade) compras do Apple Pay esperando uma viagem"
}

/// Faixa de pendência: texto + ação à direita. Some quando não há pendência.
/// O padrão é "N gastos sem foto" + "Adicionar"; `texto`, `rotulo` e `dica`
/// vêm de fora para os outros avisos (ex.: a fila do Apple Pay no Início).
struct AlertaPendencia: View {
    let quantidade: Int
    let texto: String
    let rotulo: String
    let dica: String
    let aoAdicionar: () -> Void

    init(quantidade: Int, texto: String? = nil, rotulo: String = "Adicionar",
         dica: String = "Adicionar as fotos", aoAdicionar: @escaping () -> Void) {
        self.quantidade = quantidade
        self.texto = texto ?? textoGastosSemFoto(quantidade)
        self.rotulo = rotulo
        self.dica = dica
        self.aoAdicionar = aoAdicionar
    }

    var body: some View {
        if quantidade > 0 {
            Button(action: aoAdicionar) {
                HStack(spacing: Espaco.p) {
                    Text(texto)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Espaco.p)
                    Text(rotulo)
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
            .accessibilityLabel(texto)
            .accessibilityHint(dica)
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
