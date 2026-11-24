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
    @State private var confirmandoDescarte = false
    @State private var adicionandoComprovante = false
    @State private var apagando = false
    /// Falha ao apagar ou anexar. A tela não tem o alerta do ErrorManager, então avisa aqui.
    @State private var erro: String?

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
        // A nota pode não abrir por dois motivos. Chave indisponível agora
        // (`keyNotAvailable`, iPhone trancado): a nota pode estar boa e não se
        // oferece "Descartar nota" por uma leitura que nem aconteceu. Bytes
        // guardados que a chave atual não abre (cifrados por outra chave ou
        // corrompidos; `lerComprovante` devolve `nil`) ou chave inválida: não
        // há foto para mostrar nem bytes para enviar — a saída é descartar.
        let dadosNota: Data?
        let chaveIndisponivel: Bool
        do {
            dadosNota = try gasto.lerComprovante()
            chaveIndisponivel = false
        } catch ComprovanteCryptoError.keyNotAvailable {
            dadosNota = nil
            chaveIndisponivel = true
        } catch {
            dadosNota = nil
            chaveIndisponivel = false
        }
        let imagemLocal = dadosNota.flatMap(UIImage.init(data:))
        // Remoção feita offline (pendente de sync) não conta como anexado.
        let temComprovante = temComprovanteValido(gasto)
        let notaIlegivel = gasto.comprovanteDataCriptografado != nil && dadosNota == nil && !chaveIndisponivel

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if notaIlegivel {
                    notaIlegivelView
                } else if temComprovante {
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

                lista(gasto, temComprovante: temComprovante, notaIlegivel: notaIlegivel)
                    .padding(.top, Espaco.g)

                Button("Apagar gasto", role: .destructive) { confirmandoApagar = true }
                    .font(.body)
                    .foregroundStyle(Tema.estouro)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, Espaco.g)
                    .disabled(apagando)
            }
            .padding(.bottom, Espaco.g)
            .larguraLegivel()
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
        .confirmationDialog("Descartar a nota?", isPresented: $confirmandoDescarte, titleVisibility: .visible) {
            Button("Descartar nota", role: .destructive) { descartarNota(gasto) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A nota guardada não abre neste aparelho e sai do gasto. Não tem desfazer.")
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
        .alert("Não deu certo", isPresented: Binding(get: { erro != nil }, set: { if !$0 { erro = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(erro ?? "")
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

    /// Nota guardada que a chave atual não abre: aviso no lugar da foto e a
    /// saída ("Descartar nota"), que destrava o envio do gasto.
    private var notaIlegivelView: some View {
        VStack(spacing: Espaco.p) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Tema.alertaTexto)
                .accessibilityHidden(true)
            Text("A nota não abre neste aparelho")
                .font(.body.weight(.semibold))
                .foregroundStyle(Tema.texto)
            Button("Descartar nota", role: .destructive) { confirmandoDescarte = true }
                .font(.body.weight(.semibold))
                .foregroundStyle(Tema.estouro)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Espaco.g)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.p)
    }

    // MARK: Lista

    private func lista(_ gasto: GastosDia, temComprovante: Bool, notaIlegivel: Bool) -> some View {
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
                if notaIlegivel {
                    Text("não abre").foregroundStyle(Tema.estouro)
                } else if temComprovante {
                    Label("anexado", systemImage: "checkmark")
                        .labelStyle(RotuloCompacto())
                        .foregroundStyle(Tema.ok)
                } else {
                    Button("Adicionar comprovante") { adicionandoComprovante = true }
                        .foregroundStyle(Tema.marcaTexto)
                }
            }
            divisoria
            linha("Envio") { envio(gasto) }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
    }

    /// Estado de envio ao servidor; na falha, o texto do `syncError` embaixo.
    @ViewBuilder
    private func envio(_ gasto: GastosDia) -> some View {
        let estado = EstadoEnvio.de(gasto)
        let cor: Color = switch estado {
        case .enviado: Tema.texto
        case .aguardando, .aguardandoAssinatura: Tema.textoFraco
        case .falhou, .apagadoEmOutroAparelho: Tema.estouro
        }
        VStack(alignment: .trailing, spacing: 2) {
            if let simbolo = estado.simbolo {
                Label(estado.rotulo, systemImage: simbolo)
                    .labelStyle(RotuloCompacto())
                    .foregroundStyle(cor)
            } else {
                Text(estado.rotulo)
                    .foregroundStyle(cor)
            }
            if let detalhe = estado.detalhe {
                Text(detalhe)
                    .font(.caption)
                    .foregroundStyle(Tema.textoFraco)
                    .multilineTextAlignment(.trailing)
            }
        }
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
                erro = "Não foi possível apagar o gasto. Tente novamente."

            }
        }
    }

    /// "Descartar nota": a mesma remoção do comprovante — limpa os bytes que
    /// não abrem e marca a remoção para subir (o DELETE do servidor vale
    /// mesmo quando a nota nunca chegou lá: o 404 é tratado como removido).
    private func descartarNota(_ gasto: GastosDia) {
        let id = gasto.id
        Task {
            do {
                try await viewModel.removerComprovante(gastoId: id)
            } catch {
                erro = "Não foi possível descartar a nota. Tente novamente."
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
                erro = mensagem
                return
            }
        case .semFoto:
            return
        }
        guard let dados else {
            erro = "Não foi possível ler a imagem do comprovante."
            return
        }
        let id = gasto.id
        Task {
            do {
                try await viewModel.anexarComprovante(gastoId: id, imageData: dados, mime: mime)
            } catch {
                erro = "Não foi possível anexar o comprovante. Tente novamente."
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
