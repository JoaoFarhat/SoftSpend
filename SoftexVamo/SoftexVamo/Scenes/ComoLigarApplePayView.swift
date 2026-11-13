//
//  ComoLigarApplePayView.swift
//  SoftexVamo
//
//  Tela "Como ligar o Apple Pay" (§1.6 de docs/cartao-sem-open-finance.md).
//  A automação não é criada pelo app — a Apple não permite; aqui só ensina.
//

import SwiftUI

struct ComoLigarApplePayView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pague com o Apple Pay e o SoftSpend grava o gasto sozinho, sem abrir o app. A automação é sua, no app Atalhos — o SoftSpend não cria nada por você.")
                    .font(.body)
                    .foregroundStyle(Tema.textoFraco)
                    .padding(.horizontal, Espaco.p)
                    .padding(.top, Espaco.p)

                secao("Como ligar")
                grupo {
                    passo(1, "Abra o app **Atalhos** → aba **Automação** → **+** → **Transação** (em alguns iOS aparece como **Carteira**).")
                    divisoria
                    passo(2, "Escolha os cartões que quer acompanhar e marque **Executar imediatamente**.")
                    divisoria
                    passo(3, "Toque em **Criar novo atalho**, procure **SoftSpend → Registrar gasto** e preencha: Valor = **Valor**, Estabelecimento = **Estabelecimento**, Cartão = **Cartão ou passe**.")
                    divisoria
                    passo(4, "Desligue **Notificar quando executar** (opcional, para não receber um aviso a cada compra).")
                    divisoria
                    passo(5, "Pague algo com o Apple Pay e confira no app.")
                }

                secao("O que esperar")
                grupo {
                    item("Só vale para compras pelo **Apple Pay** no iPhone ou no Apple Watch (não pega cartão físico, compra online sem Apple Pay, boleto, Pix).")
                    divisoria
                    item("**Pode atrasar**, e o iPhone precisa ter sido desbloqueado ao menos uma vez desde que ligou.")
                    divisoria
                    item("**Alguns bancos e cartões não disparam** a automação. Se a sua compra não aparecer, lance à mão ou escaneie o comprovante.")
                    divisoria
                    item("Só reais; compra em outra moeda é recusada com aviso.")
                    divisoria
                    item("O app escolhe a categoria pelo nome do local; confira e troque se precisar.")
                    divisoria
                    item("Nada sai do seu iPhone para outro serviço: o gasto é gravado no app e sobe só para o servidor do SoftSpend, como qualquer gasto.")
                }
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.bottom, Espaco.g + 8)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Apple Pay")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Partes (mesmo desenho de PerfilView)

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

    private func passo(_ numero: Int, _ texto: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Espaco.m) {
            Text("\(numero)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Tema.marcaTexto)
                .frame(width: 22, height: 22)
                .background(Tema.marcaFundo, in: Circle())
                .accessibilityHidden(true)
            Text(texto)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Passo \(numero)")
    }

    private func item(_ texto: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Espaco.m) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Tema.textoFraco)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(texto)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Claro") {
    NavigationStack {
        ComoLigarApplePayView()
    }
    .preferredColorScheme(.light)
}

#Preview("Escuro") {
    NavigationStack {
        ComoLigarApplePayView()
    }
    .preferredColorScheme(.dark)
}
