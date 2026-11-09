import SwiftUI

// MARK: - Fluxo de lançamento

/// Lançar gasto a partir do início: consentimento (tela 8, só na primeira vez)
/// → câmera (tela 9) → confirmar (tela 10). O "+" começa direto no confirmar.
struct LancarGastoView: View {
    enum Etapa { case consentimento, camera, confirmar }

    let ciclo: CicloSoftex
    let hoje: Date
    /// Imagem no lugar da câmera (modo de demonstração).
    var previewCamera: UIImage? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var etapa: Etapa
    @State private var rascunho: RascunhoGasto
    /// Começou pela câmera: o "voltar" do confirmar é "Refazer foto".
    private let comFoto: Bool

    init(ciclo: CicloSoftex, hoje: Date, comFoto: Bool,
         etapaInicial: Etapa? = nil, rascunho: RascunhoGasto? = nil, previewCamera: UIImage? = nil) {
        self.ciclo = ciclo
        self.hoje = hoje
        self.comFoto = comFoto
        self.previewCamera = previewCamera
        let inicial: Etapa
        if let etapaInicial {
            inicial = etapaInicial
        } else if !comFoto {
            inicial = .confirmar
        } else {
            inicial = Consentimento.leituraAutomatica == nil ? .consentimento : .camera
        }
        _etapa = State(initialValue: inicial)
        _rascunho = State(initialValue: rascunho ?? RascunhoGasto(dia: diaDeHoje(ciclo, hoje: hoje)))
    }

    var body: some View {
        Group {
            switch etapa {
            case .consentimento:
                ConsentimentoLeituraView { permitiu in
                    Consentimento.leituraAutomatica = permitiu
                    etapa = .camera
                }
            case .camera:
                CameraComprovanteView(aoFechar: fecharCamera, aoEscolher: receber, previewFixo: previewCamera)
            case .confirmar:
                ConfirmarGastoView(
                    rascunho: rascunho, ciclo: ciclo, hoje: hoje,
                    rotuloVoltar: comFoto ? "Refazer foto" : "Cancelar",
                    aoVoltar: {
                        if comFoto {
                            rascunho.cancelarLeitura()
                            etapa = .camera
                        } else {
                            dismiss()
                        }
                    },
                    aoSalvar: { dismiss() }
                )
            }
        }
        // A câmera é sempre escura, nos dois temas (barra de status clara). Fora
        // dela volta ao tema do aparelho: `nil` não desfaz o `.dark` na apresentação.
        .preferredColorScheme(etapa == .camera ? .dark : temaDoAparelho)
        .background((etapa == .camera ? Color.black : Tema.fundo).ignoresSafeArea())
        .presentationBackground(etapa == .camera ? Color.black : Tema.fundo)
        .onDisappear { rascunho.cancelarLeitura() }
    }

    /// Tema do sistema (o da tela, que não sofre o `preferredColorScheme` da janela).
    private var temaDoAparelho: ColorScheme {
        let cena = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        return cena?.screen.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    private func receber(_ resultado: ResultadoComprovante) {
        switch resultado {
        case .foto(let imagem):
            rascunho.receberImagem(imagem, ler: true)
        case .arquivo(let url):
            rascunho.receberArquivo(url, ler: true)
        case .semFoto:
            rascunho.removerComprovante()
        }
        etapa = .confirmar
    }

    /// O "✕" da câmera volta ao confirmar se já passou por ele; senão fecha.
    private func fecharCamera() {
        if rascunho.temComprovante || !rascunho.titulo.isEmpty || !rascunho.valorTexto.isEmpty {
            etapa = .confirmar
        } else {
            dismiss()
        }
    }
}

/// Dia do ciclo que cai em `hoje`; senão o primeiro dia.
func diaDeHoje(_ ciclo: CicloSoftex, hoje: Date) -> DiaSoftex? {
    let dias = diasValidos(ciclo)
    return dias.first { Calendar.current.isDate($0.data, inSameDayAs: hoje) } ?? dias.first
}

func diasValidos(_ ciclo: CicloSoftex) -> [DiaSoftex] {
    (ciclo.dias ?? []).filter { $0.deletadoEm == nil }.sorted { $0.data < $1.data }
}

/// "23/07", independente do idioma do aparelho.
func dataCurta(_ data: Date) -> String {
    let c = Calendar.current.dateComponents([.day, .month], from: data)
    return String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0)
}

// MARK: - Tela 10

/// Confirmar gasto: o que foi lido (ou nada, sem foto) para corrigir e salvar.
/// Também é a edição do gasto, a partir do detalhe.
struct ConfirmarGastoView: View {
    @Bindable var rascunho: RascunhoGasto
    let ciclo: CicloSoftex
    let hoje: Date
    let rotuloVoltar: String
    let aoVoltar: () -> Void
    let aoSalvar: () -> Void

    @EnvironmentObject private var viewModel: CiclosViewModel
    @FocusState private var foco: Campo?
    @State private var adicionandoComprovante = false
    @State private var opcoesComprovante = false

    @ScaledMetric(relativeTo: .largeTitle) private var tamanhoValor: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var larguraMiniatura: CGFloat = 52

    private enum Campo { case valor, descricao }

    var body: some View {
        VStack(spacing: 0) {
            barraTopo
            ScrollView {
                VStack(alignment: .leading, spacing: Espaco.m) {
                    cabecalho
                    if let aviso = rascunho.aviso {
                        Text(aviso)
                            .font(.footnote)
                            .foregroundStyle(Tema.alertaTexto)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    campoDescricao
                    HStack(spacing: Espaco.p + 2) {
                        campoData
                        campoHora
                    }
                    categorias
                    faixaSobra
                }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.bottom, Espaco.g)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            BotaoPrincipal(rascunho.editando ? "Salvar alterações" : "Salvar gasto", acao: salvar)
                .disabled(!rascunho.podeSalvar)
                .opacity(rascunho.podeSalvar ? 1 : 0.45)
                .padding(.horizontal, Espaco.g + 2)
                .padding(.vertical, Espaco.p)
                .background(Tema.fundo)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("OK") { foco = nil }
            }
        }
        .escolherComprovante(isPresented: $adicionandoComprovante) { resultado in
            // Anexar depois não passa pela leitura, como antes.
            switch resultado {
            case .foto(let imagem): rascunho.receberImagem(imagem, ler: false)
            case .arquivo(let url): rascunho.receberArquivo(url, ler: false)
            case .semFoto: break
            }
        }
        .confirmationDialog("Comprovante", isPresented: $opcoesComprovante, titleVisibility: .hidden) {
            Button("Trocar comprovante") { adicionandoComprovante = true }
            Button("Remover comprovante", role: .destructive) { rascunho.removerComprovante() }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // MARK: Topo

    private var barraTopo: some View {
        HStack {
            Button(action: aoVoltar) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").fontWeight(.semibold)
                    Text(rotuloVoltar)
                }
                .frame(minHeight: 44)
            }
            .foregroundStyle(Tema.marcaTexto)
            Spacer()
        }
        .font(.body)
        .padding(.horizontal, Espaco.g + 2)
    }

    private var cabecalho: some View {
        HStack(alignment: .center, spacing: Espaco.m) {
            miniatura
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if rascunho.lendo {
                        ProgressView().controlSize(.mini)
                    }
                    Text(textoStatus)
                        .font(.subheadline)
                        .foregroundStyle(Tema.textoFraco)
                        .fixedSize(horizontal: false, vertical: true)
                }
                campoValor
            }
        }
        .padding(.top, Espaco.p)
    }

    private var textoStatus: String {
        if rascunho.lendo { return "Lendo o comprovante" }
        if rascunho.leuComprovante { return "Lido do comprovante. Confira." }
        if rascunho.editando { return "Editar gasto" }
        if rascunho.temComprovante { return "Comprovante anexado" }
        return "Novo gasto"
    }

    @ViewBuilder
    private var miniatura: some View {
        let forma = RoundedRectangle(cornerRadius: Raio.selo, style: .continuous)
        let altura = larguraMiniatura * 1.3
        Button {
            if rascunho.temComprovante { opcoesComprovante = true } else { adicionandoComprovante = true }
        } label: {
            Group {
                if let imagem = rascunho.imagem {
                    Image(uiImage: imagem).resizable().scaledToFill()
                } else if rascunho.temComprovante && rascunho.comprovanteEhPdf {
                    Tema.superficie2.overlay {
                        Image(systemName: "doc.fill").foregroundStyle(Tema.textoFraco)
                    }
                } else if rascunho.temComprovante, let url = rascunho.urlSalva.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { fase in
                        if let img = fase.image { img.resizable().scaledToFill() } else { Tema.superficie2 }
                    }
                } else {
                    Tema.superficie.overlay {
                        Image(systemName: "camera")
                            .foregroundStyle(Tema.textoFraco)
                    }
                }
            }
            .frame(width: larguraMiniatura, height: altura)
            .clipShape(forma)
            .overlay {
                forma.strokeBorder(Tema.borda, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rascunho.temComprovante ? "Comprovante anexado. Trocar ou remover" : "Adicionar comprovante")
    }

    private var campoValor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("R$")
            TextField("0,00", text: Binding(
                get: { rascunho.valorTexto },
                set: { rascunho.valorTexto = $0; rascunho.marcarEditado(.valor) }
            ))
            .keyboardType(.decimalPad)
            .focused($foco, equals: .valor)
        }
        .font(.larga(tamanhoValor, .bold))
        .monospacedDigit()
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .foregroundStyle(Tema.texto)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Valor em reais")
    }

    // MARK: Campos

    private func caixa<C: View>(_ rotulo: String, @ViewBuilder conteudo: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rotulo)
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
            conteudo()
                .font(.body)
                .foregroundStyle(Tema.texto)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    private var campoDescricao: some View {
        caixa("Descrição") {
            TextField("Ex.: almoço, táxi", text: Binding(
                get: { rascunho.titulo },
                set: { rascunho.titulo = $0; rascunho.marcarEditado(.titulo) }
            ))
            .focused($foco, equals: .descricao)
            .submitLabel(.done)
        }
        .onTapGesture { foco = .descricao }
    }

    private var campoData: some View {
        Menu {
            ForEach(diasValidos(ciclo), id: \.id) { dia in
                Button {
                    rascunho.dia = dia
                } label: {
                    if dia.id == rascunho.dia?.id {
                        Label(diaComSemana(dia.data), systemImage: "checkmark")
                    } else {
                        Text(diaComSemana(dia.data))
                    }
                }
            }
        } label: {
            caixa("Data") {
                Text(rascunho.dia.map { dataCurta($0.data) } ?? "Escolher")
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Data, \(rascunho.dia.map { diaPorExtenso($0.data) } ?? "não escolhida")")
    }

    private var campoHora: some View {
        caixa("Hora") {
            Text(horaCurta(rascunho.criadoEm))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// "Quarta, 23/07".
    private func diaComSemana(_ data: Date) -> String {
        let semana = data.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "pt_BR")))
        let nome = semana.replacingOccurrences(of: "-feira", with: "")
        return "\(nome.prefix(1).uppercased())\(nome.dropFirst()), \(dataCurta(data))"
    }

    private var categorias: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text("Categoria")
                .font(.headline)
                .foregroundStyle(Tema.texto)
                .padding(.top, Espaco.p)
                .accessibilityAddTraits(.isHeader)
            FluxoQuebrado(espaco: Espaco.p) {
                ForEach(Categoria.allCases) { categoria in
                    chip(categoria)
                }
            }
        }
    }

    private func chip(_ categoria: Categoria) -> some View {
        let selecionada = categoria == rascunho.categoria
        return Button {
            rascunho.categoria = categoria
            rascunho.marcarEditado(.categoria)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: categoria.simboloContorno)
                    .accessibilityHidden(true)
                Text(categoria.localizedName)
            }
            .font(.body)
            .foregroundStyle(selecionada ? Tema.sobreCor : Tema.texto)
            .padding(.horizontal, Espaco.m + 2)
            .padding(.vertical, Espaco.p + 2)
            .background(selecionada ? categoria.cor : Tema.superficie2,
                        in: RoundedRectangle(cornerRadius: Raio.campo, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selecionada ? .isSelected : [])
    }

    // MARK: Faixa da diária

    /// Só aparece quando o gasto é do dia de hoje, durante a viagem: os outros
    /// dias não têm "hoje ainda sobra".
    @ViewBuilder
    private var faixaSobra: some View {
        let resumo = ResumoViagem(ciclo: ciclo, hoje: hoje)
        if case .durante = resumo.estado,
           let dia = rascunho.dia, Calendar.current.isDate(dia.data, inSameDayAs: hoje) {
            // Na edição, o valor antigo já está no total de hoje.
            let jaContado = rascunho.diaOriginal.map { Calendar.current.isDate($0.data, inSameDayAs: hoje) } == true
                ? rascunho.valorOriginal : 0
            let sobra = sobraDepois(de: rascunho.valor - jaContado, resumo: resumo)
            let passou = sobra < 0
            Group {
                if passou {
                    Text("Passa \(Text(formatarBRL(-sobra)).bold()) da diária")
                } else {
                    Text("Hoje ainda sobra \(Text(formatarBRL(sobra)).bold()) depois deste")
                }
            }
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(passou ? Tema.alertaTexto : Tema.ok)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Espaco.g)
            .padding(.vertical, Espaco.m + 2)
            .background(passou ? Tema.alertaFundo : Tema.okFundo,
                        in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .padding(.top, Espaco.p)
        }
    }

    // MARK: Salvar

    private func salvar() {
        // Síncrono, antes da Task: um segundo toque não cria outro gasto.
        guard rascunho.iniciarSalvamento() else { return }
        foco = nil
        viewModel.garantirAtual(ciclo)
        Task {
            do {
                // `salvando` volta a false dentro do `salvar` antes do dismiss.
                try await rascunho.salvar(em: viewModel)
                aoSalvar()
            } catch {
                // A tela não tem o alerta do ErrorManager: o aviso aparece no próprio formulário.
                rascunho.aviso = "Não foi possível salvar o gasto. Tente novamente."
            }
        }
    }
}

extension Categoria {
    /// SF Symbol de contorno, para os chips de categoria.
    var simboloContorno: String {
        switch self {
        case .ALIMENTACAO: return "fork.knife"
        case .TRANSPORTE: return "car"
        case .LAZER: return "gamecontroller"
        case .COMPRAS: return "bag"
        case .OUTROS: return "ellipsis"
        }
    }
}

/// Itens lado a lado, quebrando linha quando não cabem.
struct FluxoQuebrado: Layout {
    var espaco: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let linhas = organizar(largura: proposal.width ?? .infinity, subviews: subviews)
        let altura = linhas.map(\.altura).reduce(0, +) + espaco * CGFloat(max(linhas.count - 1, 0))
        let largura = linhas.map(\.largura).max() ?? 0
        return CGSize(width: proposal.width ?? largura, height: altura)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for linha in organizar(largura: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for indice in linha.indices {
                let tamanho = subviews[indice].sizeThatFits(.unspecified)
                subviews[indice].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(tamanho))
                x += tamanho.width + espaco
            }
            y += linha.altura + espaco
        }
    }

    private struct Linha { var indices: [Int] = []; var largura: CGFloat = 0; var altura: CGFloat = 0 }

    private func organizar(largura: CGFloat, subviews: Subviews) -> [Linha] {
        var linhas: [Linha] = []
        var atual = Linha()
        for (i, sub) in subviews.enumerated() {
            let t = sub.sizeThatFits(.unspecified)
            let nova = atual.indices.isEmpty ? t.width : atual.largura + espaco + t.width
            if nova > largura, !atual.indices.isEmpty {
                linhas.append(atual)
                atual = Linha()
                atual.indices = [i]; atual.largura = t.width; atual.altura = t.height
            } else {
                atual.indices.append(i); atual.largura = nova; atual.altura = max(atual.altura, t.height)
            }
        }
        if !atual.indices.isEmpty { linhas.append(atual) }
        return linhas
    }
}
