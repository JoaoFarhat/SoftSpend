import SwiftUI
import SwiftData

/// Início (telas 3, 5, 6 e 7): passagem da viagem do dia, pendências, gastos
/// de hoje e o rodapé para lançar. O avatar abre o menu que substitui as abas.
struct InicioView: View {
    /// "Hoje" vindo do `MainView`, que acompanha a virada do dia (o demo fixa uma data).
    let hoje: Date
    /// O ciclo ainda não tem origem cadastrada; sem ela a passagem mostra só o destino.
    var origem: String? = nil
    let usuario: UsuarioMenu

    @EnvironmentObject private var viewModel: CiclosViewModel
    @Environment(\.abrirRota) private var abrirRota

    @State private var menuAberto: Bool
    @State private var lancandoGasto = false
    @State private var viagemEmEdicao: CicloSoftex?
    @State private var diaTocado: DiaResumo?

    init(hoje: Date, origem: String? = nil, usuario: UsuarioMenu, menuInicial: Bool = false) {
        self.hoje = hoje
        self.origem = origem
        self.usuario = usuario
        _menuAberto = State(initialValue: menuInicial)
    }

    var body: some View {
        let ciclo = viewModel.cicloInicioEm(hoje)
        let resumo = ResumoViagem(ciclo: ciclo, hoje: hoje)

        VStack(spacing: 0) {
            barraTopo
            ZStack(alignment: .top) {
                conteudo(ciclo: ciclo, resumo: resumo)
                if menuAberto {
                    menu(ciclo: ciclo)
                }
            }
        }
        .background(Tema.fundo.ignoresSafeArea())
        .fullScreenCover(isPresented: $lancandoGasto) {
            AddNewGastoSheetView(dias: viewModel.atualCiclo.dias ?? [])
                .environmentObject(viewModel)
        }
        .fullScreenCover(item: $viagemEmEdicao) { ciclo in
            NewCicloView(ciclo: ciclo)
                .environmentObject(viewModel)
        }
    }

    // MARK: Topo

    private var barraTopo: some View {
        HStack {
            HStack(spacing: Espaco.p) {
                SimboloBilhete()
                Text("SoftSpend")
                    .foregroundStyle(Tema.texto)
            }
            .font(.title3.weight(.bold))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.25)) { menuAberto.toggle() }
            } label: {
                AvatarIniciais(usuario: usuario, destacado: menuAberto)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(menuAberto ? "Fechar menu da conta" : "Menu da conta")
        }
        .padding(.horizontal, 20)
        .padding(.top, Espaco.p)
        .padding(.bottom, Espaco.m)
    }

    // MARK: Menu

    private func menu(ciclo: CicloSoftex?) -> some View {
        ZStack(alignment: .top) {
            Tema.fundo
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { fecharMenu() }
                .accessibilityHidden(true)
            MenuAvatar(usuario: usuario, cicloParaFechar: ciclo?.id) { rota in
                fecharMenu()
                abrirRota(rota)
            } aoSair: {
                menuAberto = false
                AuthService.shared.logout()
            }
            .padding(.horizontal, Espaco.g + 2)
        }
        .transition(.opacity)
    }

    private func fecharMenu() {
        withAnimation(.snappy(duration: 0.25)) { menuAberto = false }
    }

    // MARK: Conteúdo por estado

    @ViewBuilder
    private func conteudo(ciclo: CicloSoftex?, resumo: ResumoViagem) -> some View {
        if let ciclo, resumo.estado != .semViagem {
            comViagem(ciclo: ciclo, resumo: resumo)
        } else if viewModel.isLoading && viewModel.allCiclos.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            semViagem
        }
    }

    private var semViagem: some View {
        VStack {
            Spacer()
            VStack(spacing: Espaco.p) {
                Image(systemName: "airplane")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Tema.marca)
                    .padding(.bottom, Espaco.p)
                    .accessibilityHidden(true)
                Text("Nenhuma viagem agora")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Tema.texto)
                Text("Crie a viagem antes de sair para acompanhar quanto ainda dá para gastar a cada dia.")
                    .font(.body)
                    .foregroundStyle(Tema.textoFraco)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Espaco.g + 8)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.passagem, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Raio.passagem, style: .continuous)
                    .strokeBorder(Tema.borda, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, Espaco.g + 2)
        .safeAreaInset(edge: .bottom) {
            rodape { BotaoPrincipal("Nova viagem") { abrirRota(.novaViagem) } }
        }
    }

    private func comViagem(ciclo: CicloSoftex, resumo: ResumoViagem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CartaoPassagem(resumo: resumo, origem: origem, destino: ciclo.titulo,
                               periodo: periodo(resumo)) { dia in
                    withAnimation(.snappy) { diaTocado = diaTocado?.id == dia.id ? nil : dia }
                }
                .padding(.horizontal, Espaco.g + 2)

                if let diaTocado {
                    totalDoDia(diaTocado)
                        .padding(.horizontal, Espaco.g + 2)
                        .padding(.top, Espaco.p)
                        .transition(.opacity)
                }

                switch resumo.estado {
                case .antes:
                    cabecalho("Antes de viajar")
                    dicas
                case .durante:
                    alerta(resumo)
                    cabecalho("Hoje") {
                        Button("Todos os gastos") { abrirRota(.todosGastos(filtro: .todos)) }
                            .font(.body)
                            .foregroundStyle(Tema.marcaTexto)
                    }
                    listaHoje(ciclo)
                case .encerrada:
                    alerta(resumo)
                case .semViagem:
                    EmptyView()
                }
            }
            .padding(.bottom, Espaco.g)
        }
        .scrollIndicators(.hidden)
        .refreshable { await SyncManager.shared.sync(forcar: true) }
        .safeAreaInset(edge: .bottom) {
            rodape { botoesRodape(ciclo: ciclo, estado: resumo.estado) }
        }
        .task(id: diaTocado?.id) {
            guard diaTocado != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.snappy) { diaTocado = nil }
        }
    }

    @ViewBuilder
    private func botoesRodape(ciclo: CicloSoftex, estado: EstadoViagem) -> some View {
        switch estado {
        case .antes:
            BotaoSecundario("Editar viagem") { viagemEmEdicao = ciclo }
        case .encerrada:
            BotaoPrincipal("Fechar viagem") { abrirRota(.fecharViagem(ciclo.id)) }
        default:
            HStack(spacing: Espaco.p) {
                BotaoPrincipal("Fotografar comprovante") { lancar(em: ciclo) }
                BotaoSecundario(simbolo: "plus", rotulo: "Lançar sem foto") { lancar(em: ciclo) }
            }
        }
    }

    private func rodape<C: View>(@ViewBuilder _ conteudo: () -> C) -> some View {
        conteudo()
            .padding(.horizontal, Espaco.g + 2)
            .padding(.top, Espaco.p)
            .padding(.bottom, Espaco.p)
            .background(Tema.fundo)
    }

    // MARK: Peças

    @ViewBuilder
    private func alerta(_ resumo: ResumoViagem) -> some View {
        if !resumo.semComprovante.isEmpty {
            AlertaPendencia(quantidade: resumo.semComprovante.count) {
                abrirRota(.todosGastos(filtro: .semComprovante))
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.top, Espaco.g)
        }
    }

    private func cabecalho(_ titulo: String) -> some View {
        cabecalho(titulo) { EmptyView() }
    }

    private func cabecalho<Acao: View>(_ titulo: String, @ViewBuilder acao: () -> Acao) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titulo)
                .font(.title3.weight(.bold))
                .foregroundStyle(Tema.texto)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Espaco.p)
            acao()
        }
        .padding(.horizontal, Espaco.g + 10)
        .padding(.top, 28)
        .padding(.bottom, Espaco.m)
    }

    private var dicas: some View {
        listaAgrupada([
            "Fotografe todo comprovante na hora, mesmo os pequenos.",
            "Táxi e aplicativo: peça o recibo por e-mail.",
        ], id: \.self) { dica in
            Text(dica)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Espaco.g)
                .padding(.vertical, Espaco.m + 2)
        }
    }

    @ViewBuilder
    private func listaHoje(_ ciclo: CicloSoftex) -> some View {
        let gastos = gastosDeHoje(ciclo)
        if gastos.isEmpty {
            Text("Nenhum gasto hoje")
                .font(.body)
                .foregroundStyle(Tema.textoFraco)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Espaco.g)
                .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
                .padding(.horizontal, Espaco.g + 2)
        } else {
            listaAgrupada(gastos, id: \.id, recuoDivisoria: 64) { gasto in
                Button { abrirRota(.detalheGasto(gasto.id)) } label: {
                    LinhaGasto(gasto: gasto)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Apagar gasto", systemImage: "trash", role: .destructive) {
                        apagar(gasto, em: ciclo)
                    }
                }
            }
        }
    }

    private func listaAgrupada<Item, ID: Hashable, Linha: View>(
        _ itens: [Item], id: KeyPath<Item, ID>, recuoDivisoria: CGFloat = 0,
        @ViewBuilder linha: @escaping (Item) -> Linha
    ) -> some View {
        VStack(spacing: 0) {
            // Identidade pelo id do item: as linhas não se confundem depois de apagar um gasto.
            ForEach(itens, id: id) { item in
                if item[keyPath: id] != itens.first?[keyPath: id] {
                    Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, recuoDivisoria)
                }
                linha(item)
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
    }

    private func totalDoDia(_ dia: DiaResumo) -> some View {
        let texto: String
        if dia.futuro {
            texto = "\(diaPorExtenso(dia.data)): ainda não chegou"
        } else if dia.estourou {
            texto = "\(diaPorExtenso(dia.data)): gastou \(formatarBRL(dia.gasto)), passou \(formatarBRLCurto(dia.passou))"
        } else {
            texto = "\(diaPorExtenso(dia.data)): gastou \(formatarBRL(dia.gasto))"
        }
        return Text(texto)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(dia.estourou && !dia.futuro ? Tema.estouro : Tema.textoFraco)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Espaco.g)
            .padding(.vertical, Espaco.m)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    // MARK: Dados e ações

    private func periodo(_ resumo: ResumoViagem) -> String {
        guard let ini = resumo.dias.first?.data, let fim = resumo.dias.last?.data else { return "" }
        return periodoPorExtenso(de: ini, ate: fim)
    }

    /// Gastos não apagados do dia de hoje no ciclo do início, do mais recente ao mais antigo.
    private func gastosDeHoje(_ ciclo: CicloSoftex) -> [GastosDia] {
        let cal = Calendar.current
        return (ciclo.dias ?? [])
            .filter { $0.deletadoEm == nil && cal.isDate($0.data, inSameDayAs: hoje) }
            .flatMap(\.gastos)
            .filter { $0.deletadoEm == nil }
            .sorted { $0.criadoEm > $1.criadoEm }
    }

    private func lancar(em ciclo: CicloSoftex) {
        viewModel.garantirAtual(ciclo)
        lancandoGasto = true
    }

    private func apagar(_ gasto: GastosDia, em ciclo: CicloSoftex) {
        viewModel.garantirAtual(ciclo)
        let id = gasto.id
        Task {
            do {
                try await viewModel.deleteGasto(gastoID: id)
            } catch {
                viewModel.errorManager?.show(error: error)
            }
        }
    }
}

/// Símbolo do logo: bilhete roxo cheio com os dois recortes laterais.
struct SimboloBilhete: View {
    @ScaledMetric(relativeTo: .title3) private var largura: CGFloat = 24

    var body: some View {
        let altura = largura * 0.66
        RoundedRectangle(cornerRadius: largura * 0.18, style: .continuous)
            .fill(Tema.marca)
            .frame(width: largura, height: altura)
            .mask {
                ZStack {
                    Rectangle()
                    HStack {
                        Circle().frame(width: altura * 0.36, height: altura * 0.36).offset(x: -altura * 0.18)
                        Spacer()
                        Circle().frame(width: altura * 0.36, height: altura * 0.36).offset(x: altura * 0.18)
                    }
                    .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .accessibilityHidden(true)
    }
}
