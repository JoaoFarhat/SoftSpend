//
//  MainView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI
import SwiftData

/// Filtro com que "Todos os gastos" abre.
enum FiltroGastos: Hashable {
    case todos
    case semComprovante
    case categoria(Categoria)
}

/// Destinos empilhados a partir do início.
enum Rota: Hashable {
    case novaViagem
    case viagens
    case viagem(UUID)
    case todosGastos(filtro: FiltroGastos)
    case detalheGasto(UUID)
    case fecharViagem(UUID)
    case perfil
}

extension EnvironmentValues {
    /// Empilha uma rota no `NavigationStack` do `MainView`.
    @Entry var abrirRota: (Rota) -> Void = { _ in }
}

/// Raiz do app autenticado: `NavigationStack` com o início na base.
struct MainView: View {
    @EnvironmentObject var viewModel: CiclosViewModel
    @Environment(\.modelContext) private var modelContext
    @StateObject private var syncManager = SyncManager.shared
    @ObservedObject private var authService = AuthService.shared

    /// "Hoje" do início; o modo de demonstração (DEBUG) fixa uma data.
    var hoje: Date = .now
    /// Desligado só no modo de demonstração, que não tem usuário nem rede.
    var sincronizar: Bool = true
    var origem: String? = nil
    var usuario: UsuarioMenu? = nil
    var menuInicial: Bool = false

    @State private var caminho: [Rota] = []

    private var usuarioAtual: UsuarioMenu {
        if let usuario { return usuario }
        let u = authService.currentUser
        return UsuarioMenu(nome: u?.nome ?? "", email: u?.email ?? "")
    }

    var body: some View {
        NavigationStack(path: $caminho) {
            InicioView(hoje: hoje, origem: origem, usuario: usuarioAtual, menuInicial: menuInicial)
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
            guard sincronizar else { return }
            syncManager.configure(container: modelContext.container)
            syncManager.limparDadosMortos(context: modelContext)
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
            NewCicloView()
        case .viagens:
            HistoricoView()
        case .viagem(let id):
            // Detalhe provisório: a tela antiga do ciclo, sem trocar o ciclo do início.
            ViagemProvisoria(cicloId: id)
        case .todosGastos:
            // A lista antiga já tem busca e filtro por categoria (Tarefa 7 traz os filtros novos).
            ViagemProvisoria(cicloId: viewModel.cicloInicioEm(hoje)?.id)
        case .detalheGasto(let id):
            GastoProvisorio(gastoId: id)
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

/// Edição do gasto com a tela antiga (Tarefa 6 traz o detalhe novo).
private struct GastoProvisorio: View {
    let gastoId: UUID
    @EnvironmentObject var viewModel: CiclosViewModel
    @Query private var gastos: [GastosDia]

    init(gastoId: UUID) {
        self.gastoId = gastoId
        _gastos = Query(filter: #Predicate<GastosDia> { $0.id == gastoId })
    }

    var body: some View {
        if let gasto = gastos.first, let dia = gasto.dia, let ciclo = dia.ciclo {
            AddNewGastoSheetView(dias: ciclo.dias ?? [], gastoToEdit: gasto, diaDoGasto: dia)
                .toolbar(.hidden, for: .navigationBar)
                .onAppear { viewModel.garantirAtual(ciclo) }
        } else {
            Text("Gasto não encontrado")
                .foregroundStyle(Tema.textoFraco)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tema.fundo)
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
