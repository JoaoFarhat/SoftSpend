import SwiftUI

/// Tela 8: pergunta, uma vez, se a foto ou o arquivo (comprovante ou fatura
/// do cartão) pode ir para a leitura automática (Google Gemini). Exigência do
/// `AGENTS.md` (LGPD) e da §2.8 de docs/cartao-sem-open-finance.md.
struct ConsentimentoLeituraView: View {
    /// `true` = "Permitir leitura"; `false` = "Agora não, preencho eu".
    let aoResponder: (Bool) -> Void

    @ScaledMetric(relativeTo: .title2) private var ladoIcone: CGFloat = 48

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "doc.text")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Tema.marcaTexto)
                    .frame(width: ladoIcone, height: ladoIcone)
                    .background(Tema.marcaFundo, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
                    .accessibilityHidden(true)

                Text("Ler o comprovante ou a fatura para você?")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Tema.texto)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                    .accessibilityAddTraits(.isHeader)

                Text("A foto ou arquivo (comprovante ou fatura do cartão) é enviado para um serviço de leitura (Google Gemini) que preenche valor, local, data e categoria ou lê as compras. O comprovante continua guardado só na sua conta; a fatura não fica guardada — só as compras que você confirmar.")
                    .padding(.top, Espaco.m)

                Text("Você pode mudar isso depois em Perfil e ajustes.")
                    .padding(.top, Espaco.m)
            }
            .font(.body)
            .foregroundStyle(Tema.textoFraco)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 72)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Espaco.p) {
                BotaoPrincipal("Permitir leitura") { aoResponder(true) }
                Button("Agora não, preencho eu") { aoResponder(false) }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Tema.textoFraco)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.bottom, Espaco.p)
            .background(Tema.fundo)
        }
        .background(Tema.fundo.ignoresSafeArea())
    }
}

#Preview("Claro") { ConsentimentoLeituraView { _ in }.preferredColorScheme(.light) }
#Preview("Escuro") { ConsentimentoLeituraView { _ in }.preferredColorScheme(.dark) }
