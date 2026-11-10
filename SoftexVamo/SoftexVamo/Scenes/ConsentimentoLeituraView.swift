import SwiftUI

/// Tela 8: pergunta, uma vez, se a foto do comprovante pode ir para a leitura
/// automática (Google Gemini). Exigência do `AGENTS.md` (LGPD).
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

                Text("Ler o comprovante para você?")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Tema.texto)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                    .accessibilityAddTraits(.isHeader)

                Text("A foto é enviada para um serviço de leitura (Google Gemini) que preenche valor, local, data e categoria. Ela não é usada para outra coisa e continua guardada só na sua conta.")
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
