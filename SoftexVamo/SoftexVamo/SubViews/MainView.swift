//
//  MainView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI
import SwiftData
import Combine

/// Raiz do app autenticado: `NavigationStack` com o início na base.
struct MainView: View {
    @EnvironmentObject var viewModel: CiclosViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var syncManager = SyncManager.shared
    @ObservedObject private var authService = AuthService.shared

    /// "Hoje" fixo (modo de demonstração, DEBUG). `nil` = data atual, que
    /// acompanha a virada do dia e a volta do app para o primeiro plano.
    var hojeFixo: Date? = nil
    /// Desligado só no modo de demonstração, que não tem usuário nem rede.
    var sincronizar: Bool = true
    var origem: String? = nil
    var usuario: UsuarioMenu? = nil
    var menuInicial: Bool = false
    /// Pilha e lançamento abertos ao entrar (modo de demonstração, DEBUG).
    var caminhoInicial: [Rota] = []
    var lancamentoInicial: Lancamento? = nil

    @State private var caminho: [Rota] = []
    /// Relógio do início: atualizado na virada do dia e ao voltar para o app.
    @State private var agora: Date = .now

    private var hoje: Date { hojeFixo ?? agora }

    private var usuarioAtual: UsuarioMenu {
        if let usuario { return usuario }
        let u = authService.currentUser
        return UsuarioMenu(nome: u?.nome ?? "", email: u?.email ?? "")
    }

    var body: some View {
        NavigationStack(path: $caminho) {
            InicioView(hoje: hoje, origem: origem, usuario: usuarioAtual, menuInicial: menuInicial,
                       lancamentoInicial: lancamentoInicial)
                .navigationTitle("Início")
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Rota.self) { rota in
                    DestinoRota(rota: rota, hoje: hoje)
                }
        }
        .environment(\.abrirRota) { caminho.append($0) }
        .tint(Tema.marcaTexto)
        .task {
            guard sincronizar else { return }
            viewModel.fetchCiclosResumo()
        }
        .onAppear {
            viewModel.modelContext = modelContext
            if !caminhoInicial.isEmpty, caminho.isEmpty { caminho = caminhoInicial }
            guard sincronizar else { return }
            syncManager.configure(container: modelContext.container)
            syncManager.limparDadosMortos(context: modelContext)
        }
        .onChange(of: scenePhase) { _, fase in
            if fase == .active { agora = .now }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            agora = .now
        }
        .onChange(of: syncManager.isSyncing) { _, isSyncing in
            if sincronizar, !isSyncing, syncManager.lastSyncError == nil {
                viewModel.fetchCiclosResumo()
            }
        }
    }
}

/// Tela de cada rota. Até a tarefa dona de cada tela existir, mostra a tela antiga.
private struct DestinoRota: View {
    let rota: Rota
    let hoje: Date

    @EnvironmentObject var viewModel: CiclosViewModel

    var body: some View {
        switch rota {
        case .novaViagem:
            // A tela antiga tem o próprio "Voltar"; esconde a barra do sistema.
            NewCicloView()
                .toolbar(.hidden, for: .navigationBar)
        case .viagens:
            HistoricoView()
        case .viagem(let id):
            // Detalhe provisório: a tela antiga do ciclo, sem trocar o ciclo do início.
            ViagemProvisoria(cicloId: id)
        case .todosGastos:
            // A lista antiga já tem busca e filtro por categoria (Tarefa 7 traz os filtros novos).
            ViagemProvisoria(cicloId: viewModel.cicloInicioEm(hoje)?.id)
        case .detalheGasto(let id):
            DetalheGastoView(gastoId: id, hoje: hoje)
        case .fecharViagem(let id):
            FecharViagemProvisoria(cicloId: id)
        case .perfil:
            PerfilView()
        }
    }
}

extension CiclosViewModel {
    /// Como `cicloInicio`, com o "hoje" injetável.
    func cicloInicioEm(_ hoje: Date) -> CicloSoftex? {
        cicloDoInicio(allCiclos, hoje: hoje)
    }

    /// As ações de gasto do ViewModel trabalham sobre `atualCiclo`; antes de
    /// lançar, editar ou exportar a partir de outra tela, aponta para o ciclo certo.
    func garantirAtual(_ ciclo: CicloSoftex) {
        if atualCiclo.id != ciclo.id {
            abrirViagem(ciclo)
        }
    }

    func ciclo(id: UUID?) -> CicloSoftex? {
        guard let id else { return nil }
        return allCiclos.first { $0.id == id }
    }
}

/// Tela antiga do ciclo (lista de gastos com busca, edição e exportação).
private struct ViagemProvisoria: View {
    let cicloId: UUID?
    @EnvironmentObject var viewModel: CiclosViewModel

    var body: some View {
        CiclosListView()
            .onAppear {
                if let ciclo = viewModel.ciclo(id: cicloId) {
                    viewModel.garantirAtual(ciclo)
                }
            }
    }
}

/// Exportação PDF/CSV que já existia, até a tela de fechar viagem (Tarefa 9).
private struct FecharViagemProvisoria: View {
    let cicloId: UUID
    @EnvironmentObject var viewModel: CiclosViewModel
    @State private var exportando = false
    @State private var arquivo: URL?

    private var ciclo: CicloSoftex? { viewModel.ciclo(id: cicloId) }

    var body: some View {
        let resumo = ResumoViagem(ciclo: ciclo, hoje: .now)
        VStack(alignment: .leading, spacing: Espaco.g) {
            Text(ciclo.map { nomeCidade($0.titulo) } ?? "Viagem")
                .font(.title2.weight(.bold))
                .foregroundStyle(Tema.texto)
            Text("Você gastou \(formatarBRL(resumo.gastoTotal)) dos \(formatarBRLCurto(resumo.total))")
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
            AlertaPendencia(quantidade: resumo.semComprovante.count) {}
                .allowsHitTesting(false)
            Spacer()
            if exportando {
                ProgressView().frame(maxWidth: .infinity)
            }
            BotaoPrincipal("Gerar PDF") { exportar(.pdf) }
            BotaoSecundario("Gerar CSV") { exportar(.csv) }
        }
        .padding(Espaco.g)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Fechar viagem")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(exportando)
        .sheet(isPresented: Binding(get: { arquivo != nil }, set: { if !$0 { arquivo = nil } })) {
            if let arquivo { ActivityViewController(activityItems: [arquivo]) }
        }
    }

    private func exportar(_ formato: ExportFormato) {
        guard let ciclo, !exportando else { return }
        viewModel.garantirAtual(ciclo)
        exportando = true
        Task {
            do {
                arquivo = try await viewModel.exportarCiclo(formato: formato)
            } catch let erro as URLError where erro.code == .notConnectedToInternet {
                viewModel.errorManager?.show(title: "Sem conexão",
                                             message: "Você precisa estar online para exportar o relatório.")
            } catch {
                viewModel.errorManager?.show(error: error)
            }
            exportando = false
        }
    }
}

#Preview {
    MainView()
        .environmentObject(CiclosViewModel())
}
