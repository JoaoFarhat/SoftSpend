//
//  ImportarFaturaView.swift
//  SoftSpend
//
//  Tela "Importar fatura do cartão" (A1, §2.1 de
//  docs/cartao-sem-open-finance.md): escolher PDF/OFX/CSV → consentimento →
//  leitura → conferência em três grupos (já lançadas / faltam / fora) →
//  "Importar". Toda a regra está no `ImportarFaturaViewModel`; aqui só a
//  montagem — a prévia é struct, nada de `@Model` mutado no `body`.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportarFaturaView: View {
    @StateObject private var vm: ImportarFaturaViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var contexto
    @State private var escolhendoArquivo = false
    /// "Fora desta viagem" nasce recolhido (§2.5).
    @State private var foraAberto = false
    @ScaledMetric(relativeTo: .title2) private var ladoIcone: CGFloat = 48

    init(
        ciclo: CicloSoftex,
        api: FaturaAPI = NetworkManager.shared,
        sincronizar: @escaping @MainActor () async -> Void = {
            await SyncManager.shared.sync(forcar: true)
        },
        criarGasto: @escaping @MainActor (CompraLida, DiaSoftex) async throws -> Void
    ) {
        _vm = StateObject(wrappedValue: ImportarFaturaViewModel(
            ciclo: ciclo, api: api, sincronizar: sincronizar, criarGasto: criarGasto
        ))
    }

    var body: some View {
        NavigationStack {
            conteudo
                .navigationTitle("Importar fatura")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fechar") { dismiss() }
                    }
                }
                .background(Tema.fundo.ignoresSafeArea())
        }
        .fileImporter(
            isPresented: $escolhendoArquivo,
            allowedContentTypes: [
                .pdf, .commaSeparatedText, .plainText,
                UTType(filenameExtension: "ofx") ?? .data
            ],
            allowsMultipleSelection: false
        ) { resultado in
            // `.failure` é o cancelar do usuário: fica na tela atual.
            if case .success(let urls) = resultado, let url = urls.first {
                vm.receberArquivo(url)
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // O `init` não lê o environment: o contexto entra aqui.
            if vm.contexto == nil { vm.contexto = contexto }
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        switch vm.etapa {
        case .escolhendo:
            telaTexto(
                "doc.badge.arrow.up",
                "Conferir a fatura do cartão",
                "Escolha a fatura em PDF, OFX ou CSV. O SoftSpend compara as compras com os gastos da viagem e mostra o que falta — nada é criado antes de você tocar em Importar.\n\nPDF protegido por senha funciona: o app pede a senha na hora e não a guarda."
            )
            .safeAreaInset(edge: .bottom) {
                BotaoPrincipal("Escolher arquivo") { escolhendoArquivo = true }
                    .padding(.horizontal, Espaco.g + 2)
                    .padding(.bottom, Espaco.p)
                    .background(Tema.fundo)
            }
        case .consentindo(.pergunta):
            ConsentimentoLeituraView { permitiu in
                vm.responderConsentimento(permitiu)
            }
        case .consentindo(.avisoFatura):
            // §2.8: a primeira importação mostra um aviso de uma tela —
            // a fatura tem mais dado pessoal que o comprovante.
            telaTexto(
                "doc.text.magnifyingglass",
                "A fatura passa pela IA",
                "A fatura vai para o Google Gemini para ler as compras. Pode ter seu nome e endereço. O arquivo não fica guardado no SoftSpend, só as compras que você confirmar. OFX e CSV não vão para a IA."
            )
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Espaco.p) {
                    BotaoPrincipal("Continuar") { vm.continuarAvisoFatura() }
                    Button("Agora não") { vm.voltarParaEscolha() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Tema.textoFraco)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.bottom, Espaco.p)
                .background(Tema.fundo)
            }
        case .lendo:
            aguardando(
                "Lendo a fatura…",
                detalhe: "A leitura por IA pode demorar até um minuto. Nada é gravado agora."
            )
        case .pedindoSenha:
            pedindoSenha
        case .conferindo:
            conferindo
        case .importando:
            aguardando(
                "Importando…",
                detalhe: "Gravando a fatura e criando os gastos marcados."
            )
        case .pronto:
            telaTexto(
                "checkmark.circle.fill",
                "Fatura importada",
                "\(vm.resumoImportacao)\n\nOs gastos novos aparecem na viagem com os outros; o selo \"Na fatura\" confirma o vínculo."
            )
            .safeAreaInset(edge: .bottom) {
                BotaoPrincipal("Fechar") { dismiss() }
                    .padding(.horizontal, Espaco.g + 2)
                    .padding(.bottom, Espaco.p)
                    .background(Tema.fundo)
            }
        case .erro(let mensagem):
            telaTexto("exclamationmark.triangle", "Não foi dessa vez", mensagem)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Espaco.p) {
                    BotaoPrincipal("Escolher outro arquivo") { vm.voltarParaEscolha() }
                    Button("Fechar") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Tema.textoFraco)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.bottom, Espaco.p)
                .background(Tema.fundo)
            }
        }
    }

    // MARK: - Telas de texto

    /// Moldura das telas de uma mensagem (escolha, aviso, pronto, erro):
    /// ícone, título grande e corpo — mesmo desenho do consentimento.
    private func telaTexto(_ simbolo: String, _ titulo: String, _ corpo: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                icone(simbolo)
                Text(titulo)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Tema.texto)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                    .accessibilityAddTraits(.isHeader)
                Text(corpo)
                    .font(.body)
                    .foregroundStyle(Tema.textoFraco)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Espaco.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 72)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func icone(_ simbolo: String) -> some View {
        Image(systemName: simbolo)
            .font(.title2.weight(.medium))
            .foregroundStyle(Tema.marcaTexto)
            .frame(width: ladoIcone, height: ladoIcone)
            .background(Tema.marcaFundo, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .accessibilityHidden(true)
    }

    private func aguardando(_ titulo: String, detalhe: String) -> some View {
        VStack(spacing: Espaco.m) {
            ProgressView()
                .controlSize(.large)
            Text(titulo)
                .font(.headline)
                .foregroundStyle(Tema.texto)
            Text(detalhe)
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Espaco.g)
    }

    // MARK: - Senha do PDF (§2.4)

    private var pedindoSenha: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                icone("lock.doc")
                Text("Fatura protegida por senha")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Tema.texto)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                    .accessibilityAddTraits(.isHeader)
                Text(vm.senhaIncorreta
                     ? "Senha incorreta. Tente de novo — ela vai só na requisição e não é guardada."
                     : "Digite a senha do PDF. Ela vai só na requisição — o app não a guarda nem mostra de novo.")
                    .font(.body)
                    .foregroundStyle(vm.senhaIncorreta ? Tema.estouro : Tema.textoFraco)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Espaco.m)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Senha do PDF")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoFraco)
                        .accessibilityHidden(true)
                    SecureField("Senha do PDF", text: $vm.senha)
                        .font(.body)
                        .foregroundStyle(Tema.texto)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { vm.enviarSenha() }
                }
                .padding(.horizontal, Espaco.g)
                .padding(.vertical, Espaco.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
                .padding(.top, Espaco.g)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 72)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            BotaoPrincipal("Ler fatura") { vm.enviarSenha() }
                .disabled(vm.senha.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, Espaco.g + 2)
                .padding(.bottom, Espaco.p)
                .background(Tema.fundo)
        }
    }

    // MARK: - Conferência (§2.5)

    private var conferindo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cabecalho
                avisos
                if vm.compras.isEmpty {
                    cartaoVazio("Nenhuma compra foi lida deste arquivo.")
                } else {
                    if !vm.jaLancadas.isEmpty {
                        secao("Já lançadas")
                        grupo(vm.jaLancadas) { linhaJaLancada($0) }
                    }
                    if !vm.faltam.isEmpty || !vm.estornosEEncargos.isEmpty {
                        secao("Faltam na viagem", acao: acaoMarcarTodas)
                        if !vm.faltam.isEmpty {
                            grupo(vm.faltam) { linhaFaltam($0) }
                        }
                        if !vm.estornosEEncargos.isEmpty {
                            grupo(vm.estornosEEncargos) { linhaOutros($0) }
                                .padding(.top, Espaco.p)
                        }
                    }
                    if !vm.foraDaViagem.isEmpty {
                        secaoFora
                    }
                }
            }
            .padding(.bottom, Espaco.g)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            BotaoPrincipal("Importar") { Task { await vm.importar() } }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.bottom, Espaco.p)
                .background(Tema.fundo)
        }
    }

    /// Emissor/final do cartão, vencimento e total — o que o leitor achou.
    private var cabecalho: some View {
        let fatura = vm.fatura
        let titulo = [
            fatura?.emissor,
            fatura?.finalCartao.map { "···\($0)" }
        ].compactMap { $0 }.joined(separator: " ")
        var detalhes: [String] = []
        if let fechamento = fatura?.fechamento {
            detalhes.append("fecha \(dataCurta(fechamento))")
        }
        if let vencimento = fatura?.vencimento {
            detalhes.append("vence \(dataCurta(vencimento))")
        }
        if let total = fatura?.totalFatura {
            detalhes.append("total \(formatarBRL(total))")
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text(titulo.isEmpty ? "Fatura lida" : titulo)
                .font(.headline)
                .foregroundStyle(Tema.texto)
            if !detalhes.isEmpty {
                Text(detalhes.joined(separator: " · "))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Tema.textoFraco)
            }
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.m)
    }

    /// Avisos do servidor, do `soma_confere` e dos gastos pendentes (§2.5).
    @ViewBuilder
    private var avisos: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            if let avisoPendentes = vm.avisoPendentes {
                faixa(avisoPendentes + ".")
            }
            if let fatura = vm.fatura {
                if fatura.somaConfere == false {
                    let diferenca = fatura.diferenca.map {
                        " (diferença de \(formatarBRL($0)))"
                    } ?? ""
                    faixa("Não consegui ler tudo: confira a lista antes de importar\(diferenca).")
                }
                ForEach(fatura.avisos, id: \.self) { faixa($0) }
            }
        }
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.m)
    }

    private func faixa(_ texto: String) -> some View {
        HStack(alignment: .top, spacing: Espaco.p) {
            Image(systemName: "exclamationmark.triangle")
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(texto)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tema.alertaTexto)
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .background(Tema.alertaFundo, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    private func secao(_ titulo: String, acao: (() -> AnyView)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titulo)
                .font(.title3.weight(.bold))
                .foregroundStyle(Tema.texto)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Espaco.p)
            if let acao { acao() }
        }
        .padding(.horizontal, Espaco.g + 10)
        .padding(.top, 28)
        .padding(.bottom, Espaco.m)
    }

    /// "Marcar todas" / "Desmarcar todas" do "Faltam na viagem" (§2.5).
    private func acaoMarcarTodas() -> AnyView {
        let todas = !vm.faltam.isEmpty && vm.faltam.allSatisfy(\.marcada)
        return AnyView(
            Button(todas ? "Desmarcar todas" : "Marcar todas") {
                todas ? vm.desmarcarTodas() : vm.marcarTodas()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Tema.marcaTexto)
            .buttonStyle(.plain)
        )
    }

    /// "Fora desta viagem (N)": o resto da fatura, recolhido e ignorado (§2.5).
    private var secaoFora: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { foraAberto.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Fora desta viagem (\(vm.foraDaViagem.count))")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Tema.texto)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Espaco.p)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tema.textoFraco)
                        .rotationEffect(.degrees(foraAberto ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Espaco.g + 10)
                .padding(.top, 28)
                .padding(.bottom, Espaco.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(vm.foraDaViagem.count) compras fora da viagem, ignoradas")
            .accessibilityHint(foraAberto ? "Toque para recolher" : "Toque para ver")

            if foraAberto {
                grupo(vm.foraDaViagem) { linhaOutros($0, fora: true) }
            }
        }
    }

    /// Cartão de linhas com divisor — mesmo desenho das listas do app.
    private func grupo<Linha: View>(
        _ itens: [ImportarFaturaViewModel.CompraConferencia],
        @ViewBuilder linha: @escaping (ImportarFaturaViewModel.CompraConferencia) -> Linha
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(itens) { item in
                if item.id != itens.first?.id {
                    Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, 64)
                }
                linha(item)
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
    }

    private func cartaoVazio(_ texto: String) -> some View {
        Text(texto)
            .font(.body)
            .foregroundStyle(Tema.textoFraco)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Espaco.g)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .padding(.horizontal, Espaco.g + 2)
            .padding(.top, 28)
    }

    // MARK: - Linhas da conferência

    /// Descrição formatada, data curta, parcela e valor original.
    private func infoCompra(_ compra: CompraLida) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(InterpretadorComprovante.formatarTitulo(compra.descricao))
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
            let detalhes = [dataCurta(compra.data), compra.textoParcela, compra.valorOriginal]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !detalhes.isEmpty {
                Text(detalhes)
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Já lançadas": o selo do match e os botões "Confirmar"/"Desvincular".
    private func linhaJaLancada(_ item: ImportarFaturaViewModel.CompraConferencia) -> some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            HStack(alignment: .top, spacing: Espaco.m) {
                IconeCategoria(item.compra.categoria)
                infoCompra(item.compra)
                VStack(alignment: .trailing, spacing: 4) {
                    ValorMonetario(item.compra.valor)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Tema.texto)
                    seloMatch(item)
                }
            }
            if !item.confirmada {
                HStack(spacing: Espaco.g) {
                    if item.compra.match?.matchStatus == .review {
                        Button("Confirmar") { vm.confirmar(item.id) }
                            .foregroundStyle(Tema.marcaTexto)
                    }
                    Button("Desvincular") { vm.desvincular(item.id) }
                        .foregroundStyle(Tema.textoFraco)
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .padding(.leading, 42)
            }
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .accessibilityElement(children: .contain)
    }

    /// "Faltam": desmarcada por padrão; toque marca/desmarca. Uma compra
    /// desvinculada cai aqui com "Vincular de novo".
    private func linhaFaltam(_ item: ImportarFaturaViewModel.CompraConferencia) -> some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            HStack(alignment: .top, spacing: Espaco.m) {
                IconeCategoria(item.compra.categoria)
                infoCompra(item.compra)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.alternarMarcada(item.id) }
                VStack(alignment: .trailing, spacing: 4) {
                    ValorMonetario(item.compra.valor)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Tema.texto)
                    Button { vm.alternarMarcada(item.id) } label: {
                        Image(systemName: item.marcada ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(item.marcada ? Tema.marca : Tema.textoFraco)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.marcada ? "Desmarcar compra" : "Marcar compra")
                }
            }
            if item.desvinculada {
                Button("Vincular de novo") { vm.revincular(item.id) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tema.marcaTexto)
                    .buttonStyle(.plain)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .accessibilityElement(children: .contain)
    }

    /// Estorno/encargo dentro da viagem ou compra fora dela: só leitura.
    private func linhaOutros(
        _ item: ImportarFaturaViewModel.CompraConferencia, fora: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: Espaco.m) {
            IconeCategoria(item.compra.categoria)
            infoCompra(item.compra)
            VStack(alignment: .trailing, spacing: 4) {
                ValorMonetario(item.compra.valor)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Tema.texto)
                if item.compra.tipo != .compra {
                    Selo(texto: item.compra.tipo.rotulo, estilo: .neutro)
                }
            }
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .opacity(fora ? 0.55 : 1)
        .accessibilityElement(children: .contain)
    }

    /// Selo do vínculo: "Revisar" vira "Confirmado" quando a pessoa confirma.
    @ViewBuilder
    private func seloMatch(_ item: ImportarFaturaViewModel.CompraConferencia) -> some View {
        if item.confirmada {
            Selo(texto: OpenFinanceMatchStatus.confirmed.titulo, estilo: .ok)
        } else if let status = item.compra.match?.matchStatus {
            switch status {
            case .autoMatched, .confirmed:
                Selo(texto: status.titulo, estilo: .ok)
            case .review:
                Selo(texto: status.titulo, estilo: .alerta)
            case .pendente:
                Selo(texto: status.titulo, estilo: .neutro)
            }
        }
    }
}

#if DEBUG
#Preview("Escolha do arquivo") {
    let dados = DadosExemplo.compartilhado
    ImportarFaturaView(ciclo: dados.ciclo) { _, _ in }
        .modelContainer(dados.container)
        .preferredColorScheme(.light)
}
#endif
