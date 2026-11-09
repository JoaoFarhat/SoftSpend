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
                    DestinoRota(rota: rota, hoje: hoje, origem: origem, usuario: usuarioAtual)
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

/// Tela de cada rota.
private struct DestinoRota: View {
    let rota: Rota
    let hoje: Date
    let origem: String?
    let usuario: UsuarioMenu

    @EnvironmentObject var viewModel: CiclosViewModel
    @Environment(\.formularioNovaViagem) private var formularioNovaViagem

    var body: some View {
        switch rota {
        case .novaViagem:
            // A tela tem o próprio "Cancelar"; esconde a barra do sistema.
            NewCicloView(formulario: formularioNovaViagem)
                .toolbar(.hidden, for: .navigationBar)
        case .viagens:
            ViagensView(hoje: hoje, origem: origem)
        case .viagem(let id):
            // Os gastos da viagem aberta, sem trocar o ciclo do início.
            DetalheViagemView(cicloId: id, hoje: hoje)
        case .todosGastos(let filtro, let cicloId):
            // Sem viagem indicada, a do início (a que o usuário está vendo).
            TodosGastosView(cicloId: cicloId ?? viewModel.cicloInicioEm(hoje)?.id, filtro: filtro)
        case .detalheGasto(let id):
            DetalheGastoView(gastoId: id, hoje: hoje)
        case .fecharViagem(let id):
            FecharViagemView(cicloId: id, hoje: hoje)
        case .perfil:
            PerfilView(usuario: usuario)
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

#Preview {
    MainView()
        .environmentObject(CiclosViewModel())
}
