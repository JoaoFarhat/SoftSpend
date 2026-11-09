//
//  ViagensView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI

/// Viagens fora do "Agora": as próximas (da mais perto para a mais longe) e as
/// anteriores (da mais recente para a mais antiga; sem datas, no fim).
func gruposViagens(_ ciclos: [CicloSoftex], agora: CicloSoftex?, hoje: Date,
                   calendario: Calendar = .current) -> (proximas: [CicloSoftex], anteriores: [CicloSoftex]) {
    let h = calendario.startOfDay(for: hoje)
    let outras = ciclos.filter { $0.deletadoEm == nil && $0.id != agora?.id }
        .map { ($0, intervaloViagem($0, calendario: calendario)) }
    let proximas = outras.filter { ($0.1?.ini ?? .distantPast) > h }
        .sorted { $0.1!.ini < $1.1!.ini }.map(\.0)
    let anteriores = outras.filter { ($0.1?.ini ?? .distantPast) <= h }
        .enumerated()
        .sorted { a, b in
            switch (a.element.1, b.element.1) {
            case let (x?, y?): return x.ini == y.ini ? a.offset < b.offset : x.ini > y.ini
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }
        .map(\.element.0)
    return (proximas, anteriores)
}

/// "SAO–CGB" com origem; só "CGB" sem ela.
private func rotaCodigos(origem: String?, destino: String) -> String {
    guard let origem else { return codigoCidade(destino) }
    return "\(codigoCidade(origem))–\(codigoCidade(destino))"
}

/// "Cuiabá, 20 a 25 de julho".
private func cidadeEPeriodo(_ ciclo: CicloSoftex) -> String {
    guard let (ini, fim) = intervaloViagem(ciclo) else { return nomeCidade(ciclo.titulo) }
    return "\(nomeCidade(ciclo.titulo)), \(periodoPorExtenso(de: ini, ate: fim))"
}

/// Tela 16: a viagem de agora e as anteriores, com acesso ao PDF de cada uma.
/// Abrir uma viagem não troca a viagem do início.
struct ViagensView: View {
    let hoje: Date
    var origem: String? = nil

    @EnvironmentObject private var viewModel: CiclosViewModel
    @Environment(\.abrirRota) private var abrirRota

    var body: some View {
        let agora = viewModel.cicloInicioEm(hoje)
        let grupos = gruposViagens(viewModel.allCiclos, agora: agora, hoje: hoje)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if agora == nil && grupos.proximas.isEmpty && grupos.anteriores.isEmpty {
                    vazio
                }
                if let agora {
                    secao("Agora")
                    cartaoAgora(agora)
                }
                if !grupos.proximas.isEmpty {
                    secao("Próximas")
                    lista(grupos.proximas, futuras: true)
                }
                if !grupos.anteriores.isEmpty {
                    secao("Anteriores")
                    lista(grupos.anteriores, futuras: false)
                }
            }
            .padding(.bottom, Espaco.g)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Viagens")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { abrirRota(.novaViagem) } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                }
                .tint(Tema.marcaTexto)
                .accessibilityLabel("Nova viagem")
            }
        }
    }

    private func abrir(_ ciclo: CicloSoftex) {
        viewModel.abrirViagem(ciclo)
        abrirRota(.viagem(ciclo.id))
    }

    // MARK: Partes

    private func secao(_ titulo: String) -> some View {
        Text(titulo)
            .font(.title3.weight(.bold))
            .foregroundStyle(Tema.texto)
            .padding(.horizontal, Espaco.g + 10)
            .padding(.top, 28)
            .padding(.bottom, Espaco.m)
            .accessibilityAddTraits(.isHeader)
    }

    private func cartaoAgora(_ ciclo: CicloSoftex) -> some View {
        let resumo = ResumoViagem(ciclo: ciclo, hoje: hoje)
        let proporcao: Double = resumo.total > 0
            ? min(max(NSDecimalNumber(decimal: resumo.gastoTotal / resumo.total).doubleValue, 0), 1) : 0
        let estado: String = {
            switch resumo.estado {
            case .durante(let dia, let de): return "dia \(dia)/\(de)"
            case .antes(let faltam): return faltam == 1 ? "amanhã" : "em \(faltam) dias"
            case .encerrada: return "encerrada"
            case .semViagem: return ""
            }
        }()
        let estadoAcessivel: String = {
            if case .durante(let dia, let de) = resumo.estado { return "dia \(dia) de \(de)" }
            return estado
        }()
        let gasto = "\(formatarBRLCurto(resumo.gastoTotal)) de \(formatarBRLCurto(resumo.total))"

        return Button { abrir(ciclo) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(rotaCodigos(origem: origem, destino: ciclo.titulo))
                        .font(.headline)
                        .foregroundStyle(Tema.texto)
                    Spacer(minLength: Espaco.p)
                    Text(estado)
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(Tema.textoFraco)
                }
                Text(cidadeEPeriodo(ciclo))
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
                    .padding(.top, 2)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tema.barraDia)
                        Capsule().fill(Tema.marca)
                            .frame(width: geo.size.width * proporcao)
                    }
                }
                .frame(height: 6)
                .padding(.top, Espaco.m + 2)
                Text(gasto)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Tema.textoFraco)
                    .padding(.top, 6)
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.vertical, Espaco.g)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous)
                    .strokeBorder(Tema.marca, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Espaco.g + 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cidadeEPeriodo(ciclo)), \(estadoAcessivel). Gastou \(gasto)")
        .accessibilityAddTraits(.isButton)
        .contextMenu { acoes(ciclo) }
    }

    private func lista(_ ciclos: [CicloSoftex], futuras: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(ciclos, id: \.id) { ciclo in
                if ciclo.id != ciclos.first?.id {
                    Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, Espaco.g)
                }
                linha(ciclo, futura: futuras)
                    .onAppear {
                        if !futuras, ciclo.id == ciclos.last?.id { viewModel.loadMoreCiclos() }
                    }
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
    }

    /// Anteriores mostram o que foi gasto; próximas, o total da viagem.
    private func linha(_ ciclo: CicloSoftex, futura: Bool) -> some View {
        let valor = futura ? ciclo.valor_total : ciclo.gasto_total
        return HStack(alignment: .center, spacing: Espaco.m) {
            Button { abrir(ciclo) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rotaCodigos(origem: origem, destino: ciclo.titulo))
                        .font(.headline)
                        .foregroundStyle(Tema.texto)
                    Text(cidadeEPeriodo(ciclo))
                        .font(.subheadline)
                        .foregroundStyle(Tema.textoFraco)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(cidadeEPeriodo(ciclo)), \(futura ? "total de" : "gastou") \(formatarBRLCurto(valor))")

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatarBRLCurto(valor))
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(Tema.texto)
                    .accessibilityHidden(true)
                if !futura {
                    Button("PDF") { abrirRota(.fecharViagem(ciclo.id)) }
                        .font(.subheadline)
                        .foregroundStyle(Tema.marcaTexto)
                        .buttonStyle(.plain)
                        .accessibilityLabel("PDF de \(nomeCidade(ciclo.titulo))")
                }
            }
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .contextMenu { acoes(ciclo) }
    }

    @ViewBuilder
    private func acoes(_ ciclo: CicloSoftex) -> some View {
        Button { abrir(ciclo) } label: { Label("Abrir viagem", systemImage: "list.bullet") }
        Button { abrirRota(.fecharViagem(ciclo.id)) } label: { Label("Fechar viagem e PDF", systemImage: "doc.text") }
    }

    private var vazio: some View {
        VStack(alignment: .leading, spacing: Espaco.m) {
            Text("Nenhuma viagem ainda")
                .font(.body)
                .foregroundStyle(Tema.textoFraco)
            BotaoPrincipal("Nova viagem") { abrirRota(.novaViagem) }
        }
        .padding(Espaco.g)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, 28)
    }
}

/// Detalhe de uma viagem aberta em Viagens: os gastos dela (tela 12, com o
/// ciclo aberto) e as ações da viagem. Não troca a viagem do início.
struct DetalheViagemView: View {
    let cicloId: UUID
    let hoje: Date

    @EnvironmentObject private var viewModel: CiclosViewModel
    @EnvironmentObject private var errorManager: ErrorManager
    @Environment(\.abrirRota) private var abrirRota
    @Environment(\.dismiss) private var dismiss
    @State private var editando: CicloSoftex?
    @State private var lancando: CicloSoftex?
    @State private var confirmarExclusao = false

    private var ciclo: CicloSoftex? { viewModel.ciclo(id: cicloId) }

    var body: some View {
        TodosGastosView(cicloId: cicloId)
            .toolbar {
                if let ciclo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { lancando = ciclo } label: { Label("Lançar gasto", systemImage: "plus") }
                            Button { abrirRota(.fecharViagem(ciclo.id)) } label: {
                                Label("Fechar viagem e PDF", systemImage: "doc.text")
                            }
                            Button { editando = ciclo } label: { Label("Editar viagem", systemImage: "pencil") }
                            Button(role: .destructive) { confirmarExclusao = true } label: {
                                Label("Excluir viagem", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Ações da viagem")
                    }
                }
            }
            .onAppear {
                if let ciclo { viewModel.garantirAtual(ciclo) }
            }
            .fullScreenCover(item: $editando) { ciclo in
                NewCicloView(ciclo: ciclo)
                    .environmentObject(viewModel)
                    .environmentObject(errorManager)
            }
            .fullScreenCover(item: $lancando) { ciclo in
                LancarGastoView(ciclo: ciclo, hoje: hoje, comFoto: false)
                    .environmentObject(viewModel)
                    .environmentObject(errorManager)
            }
            .confirmationDialog("Excluir \(ciclo.map { nomeCidade($0.titulo) } ?? "viagem")?",
                                isPresented: $confirmarExclusao, titleVisibility: .visible) {
                Button("Excluir viagem", role: .destructive) { excluir() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("A viagem e todos os gastos dela serão apagados.")
            }
    }

    private func excluir() {
        guard let ciclo else { return }
        Task {
            do {
                try await viewModel.deleteCiclo(ciclo: ciclo)
                dismiss()
            } catch {
                errorManager.show(error: error)
            }
        }
    }
}
