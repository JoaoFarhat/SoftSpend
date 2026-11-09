import SwiftUI
import SwiftData

/// Tela 11: foto do comprovante grande (com ampliar), nome, valor, data,
/// categoria e comprovante; "Editar" reabre o confirmar e "Apagar gasto" pede confirmação.
struct DetalheGastoView: View {
    let gastoId: UUID
    /// "Hoje" do início (o demo fixa uma data), para a faixa da diária na edição.
    let hoje: Date

    @EnvironmentObject private var viewModel: CiclosViewModel
    @Environment(\.dismiss) private var dismiss
    @Query private var gastos: [GastosDia]

    @State private var editando: RascunhoGasto?
    @State private var ampliada = false
    @State private var confirmandoApagar = false
    @State private var adicionandoComprovante = false
    @State private var apagando = false

    init(gastoId: UUID, hoje: Date = .now) {
        self.gastoId = gastoId
        self.hoje = hoje
        _gastos = Query(filter: #Predicate<GastosDia> { $0.id == gastoId })
    }

    var body: some View {
        Group {
            if let gasto = gastos.first, gasto.deletadoEm == nil, let ciclo = gasto.dia?.ciclo {
                conteudo(gasto, ciclo: ciclo)
            } else {
                Text("Gasto não encontrado")
                    .foregroundStyle(Tema.textoFraco)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func conteudo(_ gasto: GastosDia, ciclo: CicloSoftex) -> some View {
        let imagemLocal = gasto.comprovanteData.flatMap(UIImage.init(data:))
        let temComprovante = gasto.comprovanteUrl != nil || gasto.comprovanteDataCriptografado != nil

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if temComprovante {
                    foto(gasto, imagemLocal: imagemLocal)
                } else {
                    semFoto
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(gasto.titulo)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Tema.texto)
                        .accessibilityAddTraits(.isHeader)
                    ValorMonetario(gasto.valor, destaque: true)
                        .foregroundStyle(Tema.texto)
                }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.top, Espaco.g + 4)

                lista(gasto, temComprovante: temComprovante)
                    .padding(.top, Espaco.g)

                Button("Apagar gasto", role: .destructive) { confirmandoApagar = true }
                    .font(.body)
                    .foregroundStyle(Tema.estouro)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, Espaco.g)
                    .disabled(apagando)
            }
            .padding(.bottom, Espaco.g)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Editar") { editando = RascunhoGasto(editando: gasto) }
                    .foregroundStyle(Tema.marcaTexto)
            }
        }
        .confirmationDialog("Apagar este gasto?", isPresented: $confirmandoApagar, titleVisibility: .visible) {
            Button("Apagar gasto", role: .destructive) { apagar(gasto, ciclo: ciclo) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("\(gasto.titulo), \(formatarBRL(gasto.valor)). O gasto sai da viagem.")
        }
        .escolherComprovante(isPresented: $adicionandoComprovante) { resultado in
            anexar(resultado, gasto: gasto)
        }
        .fullScreenCover(item: $editando) { rascunho in
            ConfirmarGastoView(rascunho: rascunho, ciclo: ciclo, hoje: hoje,
                               rotuloVoltar: "Cancelar",
                               aoVoltar: { editando = nil },
                               aoSalvar: { editando = nil })
                .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: $ampliada) {
            FotoAmpliadaView(imagem: imagemLocal, url: gasto.comprovanteUrl.flatMap(URL.init(string:)))
        }
    }

    // MARK: Foto

    @ScaledMetric(relativeTo: .body) private var alturaFoto: CGFloat = 230

    private func foto(_ gasto: GastosDia, imagemLocal: UIImage?) -> some View {
        let forma = RoundedRectangle(cornerRadius: Raio.lista, style: .continuous)
        let ehPdf = gasto.comprovanteEhPdf
        return Button { if !ehPdf { ampliada = true } } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if ehPdf {
                        Tema.superficie.overlay {
                            Label("PDF anexado", systemImage: "doc.fill")
                                .foregroundStyle(Tema.textoFraco)
                        }
                    } else if let imagemLocal {
                        Image(uiImage: imagemLocal).resizable().scaledToFill()
                    } else if let url = gasto.comprovanteUrl.flatMap(URL.init(string:)) {
                        AsyncImage(url: url) { fase in
                            if let img = fase.image {
                                img.resizable().scaledToFill()
                            } else if fase.error != nil {
                                Tema.superficie.overlay {
                                    Image(systemName: "doc.text.image").font(.title2).foregroundStyle(Tema.textoFraco)
                                }
                            } else {
                                Tema.superficie.overlay { ProgressView() }
                            }
                        }
                    }
                }
                // Comprovante alinhado pelo topo, onde ficam loja, data e total.
                .frame(maxWidth: .infinity)
                .frame(height: alturaFoto, alignment: .top)
                .clipped()

                if !ehPdf {
                    Text("Ampliar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Espaco.p)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Raio.selo, style: .continuous))
                        .padding(Espaco.m)
                }
            }
            .clipShape(forma)
            .contentShape(forma)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.p)
        .accessibilityLabel(ehPdf ? "Comprovante em PDF" : "Foto do comprovante. Ampliar")
    }

    private var semFoto: some View {
        Button { adicionandoComprovante = true } label: {
            VStack(spacing: Espaco.p) {
                Image(systemName: "camera")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text("Adicionar comprovante")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(Tema.marcaTexto)
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Raio.lista, style: .continuous)
                    .strokeBorder(Tema.borda, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.p)
    }

    // MARK: Lista

    private func lista(_ gasto: GastosDia, temComprovante: Bool) -> some View {
        let data = gasto.dia.map { "\(dataCurta($0.data)), \(horaCurta(gasto.criadoEm))" } ?? horaCurta(gasto.criadoEm)
        return VStack(spacing: 0) {
            linha("Data") {
                Text(data).monospacedDigit().foregroundStyle(Tema.texto)
            }
            divisoria
            linha("Categoria") {
                Text(gasto.categoria.localizedName).foregroundStyle(Tema.texto)
            }
            divisoria
            linha("Comprovante") {
                if temComprovante {
                    Label("anexado", systemImage: "checkmark")
                        .labelStyle(RotuloCompacto())
                        .foregroundStyle(Tema.ok)
                } else {
                    Button("Adicionar comprovante") { adicionandoComprovante = true }
                        .foregroundStyle(Tema.marcaTexto)
                }
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
    }

    private var divisoria: some View {
        Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, Espaco.g)
    }

    private func linha<V: View>(_ rotulo: String, @ViewBuilder valor: () -> V) -> some View {
        HStack {
            Text(rotulo).foregroundStyle(Tema.textoFraco)
            Spacer(minLength: Espaco.p)
            valor()
        }
        .font(.body)
        .padding(.horizontal, Espaco.g)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }

    // MARK: Ações

    private func apagar(_ gasto: GastosDia, ciclo: CicloSoftex) {
        viewModel.garantirAtual(ciclo)
        let id = gasto.id
        apagando = true
        Task {
            do {
                try await viewModel.deleteGasto(gastoID: id)
                // Estado da tela resetado antes de sair da pilha.
                apagando = false
                dismiss()
            } catch {
                apagando = false
                viewModel.errorManager?.show(error: error)
            }
        }
    }

    private func anexar(_ resultado: ResultadoComprovante, gasto: GastosDia) {
        let dados: Data?
        let mime: String
        switch resultado {
        case .foto(let imagem):
            dados = NotaFiscal.codificar(imagem); mime = "image/jpeg"
        case .arquivo(let url):
            switch NotaFiscal.abrir(url) {
            case .imagem(let imagem): dados = NotaFiscal.codificar(imagem); mime = "image/jpeg"
            case .pdf(let pdf): dados = pdf; mime = "application/pdf"
            case .erro(let mensagem):
                viewModel.errorManager?.show(title: "Comprovante", message: mensagem)
                return
            }
        case .semFoto:
            return
        }
        guard let dados else { return }
        let id = gasto.id
        Task {
            do {
                try await viewModel.anexarComprovante(gastoId: id, imageData: dados, mime: mime)
            } catch {
                viewModel.errorManager?.show(error: error)
            }
        }
    }
}

extension RascunhoGasto: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// "✓ anexado": ícone e texto juntos, no tamanho do texto.
private struct RotuloCompacto: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.fontWeight(.semibold)
            configuration.title
        }
    }
}

// MARK: - Foto ampliada

/// Comprovante em tela cheia, com pinça e toque duplo para ampliar.
struct FotoAmpliadaView: View {
    let imagem: UIImage?
    let url: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var escala: CGFloat = 1
    @State private var escalaBase: CGFloat = 1
    @State private var deslocamento: CGSize = .zero
    @State private var deslocamentoBase: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Group {
                if let imagem {
                    Image(uiImage: imagem).resizable().scaledToFit()
                } else if let url {
                    AsyncImage(url: url) { fase in
                        if let img = fase.image { img.resizable().scaledToFit() } else { ProgressView().tint(.white) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(escala)
            .offset(deslocamento)
            .gesture(
                MagnifyGesture()
                    .onChanged { escala = max(1, min(escalaBase * $0.magnification, 6)) }
                    .onEnded { _ in escalaBase = escala; if escala == 1 { centralizar() } }
                    .simultaneously(with: DragGesture()
                        .onChanged { valor in
                            guard escala > 1 else { return }
                            deslocamento = CGSize(width: deslocamentoBase.width + valor.translation.width,
                                                  height: deslocamentoBase.height + valor.translation.height)
                        }
                        .onEnded { _ in deslocamentoBase = deslocamento })
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if escala > 1 { escala = 1; escalaBase = 1; centralizar() } else { escala = 2.5; escalaBase = 2.5 }
                }
            }
            .accessibilityLabel("Foto do comprovante")

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Fechar")
            .padding(Espaco.g)
        }
    }

    private func centralizar() {
        deslocamento = .zero
        deslocamentoBase = .zero
    }
}
