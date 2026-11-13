//
//  ComprasSemViagemView.swift
//  SoftexVamo
//
//  Folha da fila "sem viagem" do Apple Pay (§1.5 de
//  docs/cartao-sem-open-finance.md), aberta pelo aviso do Início. Cada compra
//  mostra estabelecimento, valor, cartão e data, e vira um gasto no dia em que
//  aconteceu ("Lançar em …") ou sai da fila ("Descartar"). Sem viagem possível
//  para aquela data, só "Descartar" e o texto "Crie a viagem desta data para
//  lançar".
//

import SwiftUI
import SwiftData

struct ComprasSemViagemView: View {
    /// Itens da fila do usuário (mais recentes primeiro), recarregados pelo Início.
    let compras: [CompraAguardandoViagem]
    /// Só para a demonstração: força o usuário dono da fila.
    var userId: String? = nil
    /// Chamado depois de lançar ou descartar: o Início relê a fila.
    let aoMudar: () -> Void

    @Environment(\.modelContext) private var contexto
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: CiclosViewModel

    /// Compra esperando o "sim" do diálogo de descarte — a compra some da fila
    /// para sempre, então um toque não basta.
    @State private var paraDescartar: CompraAguardandoViagem?

    /// `UsuarioSalvo` cobre o app acordado pela ação antes do
    /// `checkAuthentication` encher `currentUser`.
    private var donoFila: String {
        userId ?? AuthService.shared.currentUser?.id ?? UsuarioSalvo.id() ?? ""
    }

    /// Destino de cada compra, uma vez por `body`: um fetch de ciclos e o
    /// resto em memória, em vez de um fetch por cartão a cada render
    /// (`viagemEDia(em:)`). Lê o banco local como o registro faz —
    /// `allCiclos` do ViewModel pode ainda não ter carregado e a folha
    /// diria "Crie a viagem desta data" por engano.
    private var destinos: [UUID: (ciclo: CicloSoftex, dia: DiaSoftex)] {
        let ciclos = RegistroApplePay.ciclosVivos(userId: donoFila, em: contexto)
        var mapa: [UUID: (ciclo: CicloSoftex, dia: DiaSoftex)] = [:]
        for compra in compras {
            mapa[compra.id] = RegistroApplePay.viagemEDia(
                para: compra.recebidaEm, userId: donoFila, ciclos: ciclos)
        }
        return mapa
    }

    var body: some View {
        let destinos = self.destinos
        NavigationStack {
            ScrollView {
                VStack(spacing: Espaco.m) {
                    ForEach(compras) { compra in
                        cartao(compra, destino: destinos[compra.id])
                    }
                }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.vertical, Espaco.g)
            }
            .background(Tema.fundo.ignoresSafeArea())
            .navigationTitle("Compras do Apple Pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onChange(of: compras.isEmpty) { _, vazia in
                // Lançou ou descartou a última: a folha fecha sozinha.
                if vazia { dismiss() }
            }
            // `presenting:` entrega a compra à ação — com o Binding manual,
            // o SwiftUI podia zerar `paraDescartar` antes do botão rodar e
            // o "Descartar" saía sem fazer nada.
            .confirmationDialog("Descartar esta compra?",
                                isPresented: Binding(get: { paraDescartar != nil },
                                                     set: { if !$0 { paraDescartar = nil } }),
                                titleVisibility: .visible,
                                presenting: paraDescartar) { compra in
                Button("Descartar", role: .destructive) {
                    descartar(compra)
                }
                Button("Cancelar", role: .cancel) {}
            } message: { compra in
                Text("\(compra.estabelecimento), \(formatarBRL(compra.valor)). A compra sai da fila e não tem desfazer.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Cartão de cada compra

    @ViewBuilder
    private func cartao(_ compra: CompraAguardandoViagem,
                        destino: (ciclo: CicloSoftex, dia: DiaSoftex)?) -> some View {
        VStack(alignment: .leading, spacing: Espaco.m) {
            HStack(spacing: Espaco.m) {
                IconeCategoria(compra.categoria, tamanho: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(compra.estabelecimento)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Tema.texto)
                        .lineLimit(1)
                    Text(subtitulo(compra))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Tema.textoFraco)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ValorMonetario(compra.valor, simbolo: false)
                    .font(.body)
                    .foregroundStyle(Tema.texto)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: Espaco.g) {
                if let destino {
                    Button {
                        lancar(compra, em: destino.dia)
                    } label: {
                        Text("Lançar em \(destino.ciclo.titulo) · \(dataCurta(destino.dia.data))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tema.marcaTexto)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Crie a viagem desta data para lançar")
                        .font(.subheadline)
                        .foregroundStyle(Tema.textoFraco)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Espaco.p)
                Button("Descartar", role: .destructive) { paraDescartar = compra }
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    /// "Nubank · 13/11, 14:32" ou só "13/11, 14:32" quando a automação não manda o cartão.
    private func subtitulo(_ compra: CompraAguardandoViagem) -> String {
        let quando = "\(dataCurta(compra.recebidaEm)), \(horaCurta(compra.recebidaEm))"
        if let cartao = compra.cartao, !cartao.isEmpty {
            return "\(cartao) · \(quando)"
        }
        return quando
    }

    // MARK: Ações

    /// "Lançar": grava o gasto no dia da compra (o item sai da fila só depois
    /// do `save`, dentro de `RegistroApplePay.lancar`) e sobe para o servidor
    /// como qualquer gasto.
    private func lancar(_ compra: CompraAguardandoViagem, em dia: DiaSoftex) {
        do {
            try RegistroApplePay.lancar(compra, em: dia, contexto: contexto)
            Task { await SyncManager.shared.sync(forcar: true) }
            aoMudar()
        } catch {
            viewModel.errorManager?.show(error: error)
        }
    }

    private func descartar(_ compra: CompraAguardandoViagem) {
        ComprasAguardandoViagem.shared.remover(id: compra.id)
        aoMudar()
    }
}

#if DEBUG
/// Folha com a viagem de exemplo: a compra de 21/07 tem destino ("Lançar em"),
/// a de 10/08 não tem (só "Descartar").
private struct ComprasSemViagemExemplo: View {
    private let dados = DadosExemplo.compartilhado
    private let viewModel = CiclosViewModel()
    private let compras: [CompraAguardandoViagem]

    init() {
        dados.ciclo.userId = "demo"
        viewModel.allCiclos = [dados.ciclo]
        compras = [
            CompraAguardandoViagem(id: UUID(), userId: "demo",
                                   valor: Decimal(string: "43.10")!,
                                   estabelecimento: "Spoleto", cartao: "Nubank",
                                   categoria: .ALIMENTACAO, recebidaEm: dados.dia(21, 13, 42)),
            CompraAguardandoViagem(id: UUID(), userId: "demo",
                                   valor: Decimal(string: "104.60")!,
                                   estabelecimento: "Taxi Aeroporto", cartao: nil,
                                   categoria: .TRANSPORTE,
                                   recebidaEm: dados.calendario.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))!),
        ]
    }

    var body: some View {
        ComprasSemViagemView(compras: compras, userId: "demo") {}
            .environmentObject(viewModel)
            .modelContainer(dados.container)
    }
}

#Preview("Claro") { ComprasSemViagemExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { ComprasSemViagemExemplo().preferredColorScheme(.dark) }
#endif
