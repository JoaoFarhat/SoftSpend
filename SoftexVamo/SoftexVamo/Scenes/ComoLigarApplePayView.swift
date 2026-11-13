import SwiftUI

/// "Como ligar o Apple Pay" (§1.6 de docs/cartao-sem-open-finance.md): o passo
/// a passo para criar a automação no app Atalhos e as limitações honestas.
/// Aberta pela linha "Apple Pay (atalho)" em Perfil e ajustes.
/// A automação não é criada pelo app — a Apple não permite.
struct ComoLigarApplePayView: View {
    private static let passos: [String] = [
        "Abra o app Atalhos → aba Automação → + → Transação (em alguns iOS aparece como Carteira).",
        "Escolha os cartões que quer acompanhar e marque Executar imediatamente.",
        "Toque em Criar novo atalho, procure SoftSpend → Registrar gasto e preencha: Valor = Valor, Estabelecimento = Estabelecimento, Cartão = Cartão ou passe.",
        "Desligue Notificar quando executar (opcional, para não receber um aviso a cada compra).",
        "Pague algo com o Apple Pay e confira no app."
    ]

    private static let limitacoes: [String] = [
        "Só vale para compras pelo Apple Pay no iPhone ou no Apple Watch (não pega cartão físico, compra online sem Apple Pay, boleto, Pix).",
        "Pode atrasar, e o iPhone precisa ter sido desbloqueado ao menos uma vez desde que ligou.",
        "Alguns bancos e cartões não disparam a automação. Se a sua compra não aparecer, lance à mão ou escaneie o comprovante.",
        "Só reais; compra em outra moeda é recusada com aviso.",
        "O app escolhe a categoria pelo nome do local; confira e troque se precisar.",
        "Nada sai do seu iPhone para outro serviço: o gasto é gravado no app e sobe só para o servidor do SoftSpend, como qualquer gasto."
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pague com o Apple Pay e o SoftSpend grava o gasto sozinho, sem abrir o app e sem perguntar nada.")
                    .font(.body)
                    .foregroundStyle(Tema.textoFraco)
                    .padding(.horizontal, Espaco.p)
                    .padding(.top, Espaco.p)

                secao("Como ligar")
                grupo {
                    ForEach(Array(Self.passos.enumerated()), id: \.offset) { indice, texto in
                        if indice > 0 { divisoria }
                        passo(numero: indice + 1, texto: texto)
                    }
                }

                secao("O que esperar")
                grupo {
                    ForEach(Array(Self.limitacoes.enumerated()), id: \.offset) { indice, texto in
                        if indice > 0 { divisoria }
                        item(texto)
                    }
                }
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.bottom, Espaco.g + 8)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Apple Pay")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func secao(_ titulo: String) -> some View {
        Text(titulo)
            .font(.title3.weight(.bold))
            .foregroundStyle(Tema.texto)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Espaco.p)
            .padding(.top, 28)
            .padding(.bottom, Espaco.m)
    }

    private func grupo<C: View>(@ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(spacing: 0) { conteudo() }
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    private var divisoria: some View {
        Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, Espaco.g)
    }

    private func passo(numero: Int, texto: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Espaco.m) {
            Text("\(numero).")
                .font(.body.weight(.semibold))
                .foregroundStyle(Tema.marcaTexto)
            Text(texto)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func item(_ texto: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Espaco.m) {
            Text("•")
                .font(.body)
                .foregroundStyle(Tema.textoFraco)
            Text(texto)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Claro") {
    NavigationStack { ComoLigarApplePayView() }
        .preferredColorScheme(.light)
}

#Preview("Escuro") {
    NavigationStack { ComoLigarApplePayView() }
        .preferredColorScheme(.dark)
}
