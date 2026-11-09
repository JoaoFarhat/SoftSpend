import SwiftUI

/// "Sobrou R$ 315,40. Um dia passou da diária." — a frase do resumo de Fechar viagem.
func fraseFechamento(gasto: Decimal, total: Decimal, diasEstourados: Int) -> String {
    let sobra = total - gasto
    let saldo: String
    if sobra > 0 {
        saldo = "Sobrou \(formatarBRLCurto(sobra))."
    } else if sobra < 0 {
        saldo = "Passou \(formatarBRLCurto(-sobra)) do total."
    } else {
        saldo = "Gastou o total certinho."
    }
    let dias: String
    switch diasEstourados {
    case 0: dias = "Nenhum dia passou da diária."
    case 1: dias = "Um dia passou da diária."
    default: dias = "\(diasEstourados) dias passaram da diária."
    }
    return "\(saldo) \(dias)"
}

/// Tela 14: resumo da viagem, o que falta antes de gerar e a geração do
/// relatório (PDF ou CSV, montado pelo servidor em `GET /ciclos/{id}/export`)
/// com a folha de compartilhar. Gerar com pendências é permitido.
struct FecharViagemView: View {
    let cicloId: UUID
    let hoje: Date

    @EnvironmentObject private var viewModel: CiclosViewModel
    @Environment(\.abrirRota) private var abrirRota

    @State private var formato: ExportFormato = .pdf
    @State private var exportando = false
    @State private var arquivo: URL?
    @State private var tarefa: Task<Void, Never>?

    private var ciclo: CicloSoftex? { viewModel.ciclo(id: cicloId) }

    var body: some View {
        let resumo = ResumoViagem(ciclo: ciclo, hoje: hoje)
        let gastos = gastosValidos(ciclo)
        let semFoto = gastos.filter { !temComprovanteValido($0) }.count
        let comFoto = gastos.count - semFoto

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cartaoResumo(resumo)
                titulo("Antes de gerar")
                checklist(comFoto: comFoto, semFoto: semFoto, total: gastos.count)
                titulo("Formato")
                escolhaFormato
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.bottom, Espaco.g)
        }
        .safeAreaInset(edge: .bottom) {
            rodape(pendencias: semFoto)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Fechar viagem")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: Binding(get: { arquivo != nil }, set: { if !$0 { arquivo = nil } })) {
            if let arquivo { ActivityViewController(activityItems: [arquivo]) }
        }
        .onDisappear {
            // Saiu da tela no meio da geração (voltou ou abriu "Resolver"): cancela
            // e solta o estado aqui, enquanto a tela ainda existe; a tarefa
            // cancelada não escreve mais no @State.
            tarefa?.cancel()
            tarefa = nil
            exportando = false
        }
    }

    // MARK: Resumo

    private func cartaoResumo(_ resumo: ResumoViagem) -> some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text(ciclo.map(cidadeEPeriodoFechamento) ?? "Viagem")
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
            HStack(alignment: .bottom) {
                valor(rotulo: "Gasto", resumo.gastoTotal, alinhamento: .leading)
                Spacer(minLength: Espaco.p)
                valor(rotulo: "de", resumo.total, alinhamento: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gasto \(formatarBRL(resumo.gastoTotal)) de \(formatarBRLCurto(resumo.total))")
            Text(fraseFechamento(gasto: resumo.gastoTotal, total: resumo.total,
                                 diasEstourados: resumo.diasEstourados))
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Espaco.g + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous))
        .padding(.top, Espaco.p)
    }

    @ScaledMetric(relativeTo: .title2) private var tamanhoValor: CGFloat = 22

    private func valor(rotulo: String, _ v: Decimal, alinhamento: HorizontalAlignment) -> some View {
        VStack(alignment: alinhamento, spacing: 2) {
            Text(rotulo)
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
            Text(rotulo == "de" ? formatarBRLCurto(v) : formatarBRL(v))
                .font(.larga(tamanhoValor, .bold))
                .monospacedDigit()
                .foregroundStyle(Tema.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func titulo(_ texto: String) -> some View {
        Text(texto)
            .font(.title3.weight(.bold))
            .foregroundStyle(Tema.texto)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Espaco.p)
            .padding(.top, 28)
            .padding(.bottom, Espaco.m)
    }

    // MARK: Checklist

    private func checklist(comFoto: Int, semFoto: Int, total: Int) -> some View {
        VStack(spacing: 0) {
            if total == 0 {
                linhaChecklist(simbolo: "minus", cor: Tema.textoFraco, texto: "Nenhum gasto lançado")
            } else {
                if comFoto > 0 {
                    linhaChecklist(simbolo: "checkmark", cor: Tema.ok,
                                   texto: comFoto == 1 ? "1 gasto com comprovante" : "\(comFoto) gastos com comprovante")
                }
                if comFoto > 0 && semFoto > 0 {
                    Rectangle().fill(Tema.borda).frame(height: 0.5)
                }
                if semFoto > 0 {
                    HStack(spacing: Espaco.m) {
                        linhaChecklist(simbolo: "exclamationmark", cor: Tema.alertaTexto,
                                       texto: "\(semFoto) sem foto", preenche: false)
                        Spacer(minLength: Espaco.p)
                        Button("Resolver") {
                            abrirRota(.todosGastos(filtro: .semComprovante, cicloId: cicloId))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Tema.marcaTexto)
                        .accessibilityLabel("Resolver gastos sem foto")
                        .padding(.trailing, Espaco.g)
                    }
                }
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    private func linhaChecklist(simbolo: String, cor: Color, texto: String, preenche: Bool = true) -> some View {
        HStack(spacing: Espaco.m) {
            Image(systemName: simbolo)
                .font(.body.weight(.bold))
                .foregroundStyle(cor)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(texto)
                .font(.body)
                .foregroundStyle(Tema.texto)
            if preenche { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Espaco.g)
        .frame(minHeight: 50)
    }

    // MARK: Formato

    private var escolhaFormato: some View {
        HStack(spacing: Espaco.m) {
            opcaoFormato(.pdf, titulo: "PDF", detalhe: "com as fotos")
            opcaoFormato(.csv, titulo: "CSV", detalhe: "planilha")
        }
    }

    private func opcaoFormato(_ f: ExportFormato, titulo: String, detalhe: String) -> some View {
        let escolhido = formato == f
        return Button { formato = f } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo)
                    .font(.headline)
                    .foregroundStyle(Tema.texto)
                Text(detalhe)
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
            }
            .padding(.horizontal, Espaco.g)
            .padding(.vertical, Espaco.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous))
            .overlay {
                if escolhido {
                    RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous)
                        .strokeBorder(Tema.marca, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(escolhido ? [.isSelected] : [])
    }

    // MARK: Rodapé

    private func rodape(pendencias: Int) -> some View {
        VStack(spacing: Espaco.p) {
            BotaoPrincipalCarregando("Gerar e compartilhar", carregando: exportando) { exportar() }
                .disabled(exportando || ciclo == nil)
            if pendencias > 0 {
                Text("Dá para gerar mesmo com pendências; elas aparecem marcadas.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.p)
        .padding(.bottom, Espaco.p)
        .background(Tema.fundo)
    }

    /// Mesma exportação de antes: `exportarCiclo(formato:)` com as fotos
    /// embutidas (padrão `.imagem`) e a folha de compartilhar.
    private func exportar() {
        guard let ciclo, !exportando else { return }
        viewModel.garantirAtual(ciclo)
        exportando = true
        let escolhido = formato
        tarefa = Task {
            do {
                let url = try await viewModel.exportarCiclo(formato: escolhido)
                guard !Task.isCancelled else { return }
                arquivo = url
            } catch is CancellationError {
                return
            } catch let erro as URLError where erro.code == .notConnectedToInternet {
                viewModel.errorManager?.show(title: "Sem conexão",
                                             message: "Você precisa estar online para exportar o relatório.")
            } catch {
                if Task.isCancelled { return }
                viewModel.errorManager?.show(error: error)
            }
            guard !Task.isCancelled else { return }
            exportando = false
            tarefa = nil
        }
    }
}

/// "Cuiabá, 20 a 25 de julho".
private func cidadeEPeriodoFechamento(_ ciclo: CicloSoftex) -> String {
    guard let (ini, fim) = intervaloViagem(ciclo) else { return nomeCidade(ciclo.titulo) }
    return "\(nomeCidade(ciclo.titulo)), \(periodoPorExtenso(de: ini, ate: fim))"
}

/// Gastos não apagados da viagem.
private func gastosValidos(_ ciclo: CicloSoftex?) -> [GastosDia] {
    (ciclo?.dias ?? []).filter { $0.deletadoEm == nil }
        .flatMap(\.gastos)
        .filter { $0.deletadoEm == nil }
}

/// Folha de compartilhamento do sistema, para o PDF do relatório.
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
