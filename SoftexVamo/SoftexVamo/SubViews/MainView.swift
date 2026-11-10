//
//  MainView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI
import SwiftData
import Combine

/// Abas da barra de baixo. O redesenho tinha tirado a barra e deixado tudo no menu do avatar, e o
/// usuário não achava as telas (decisão do usuário de 10/11: voltar com 3 abas).
enum Aba: Hashable, CaseIterable {
    case inicio, viagens, gastos

    var titulo: String {
        switch self {
        case .inicio: "Início"
        case .viagens: "Viagens"
        case .gastos: "Gastos"
        }
    }

    var simbolo: String {
        switch self {
        case .inicio: "house"
        case .viagens: "suitcase"
        case .gastos: "list.bullet"
        }
    }
}

/// Raiz do app autenticado: uma barra com 3 abas (Início, Viagens, Gastos), cada uma com a própria
/// `NavigationStack`. O avatar do início fica só com o que é da conta (Perfil e ajustes, Sair).
/// A barra é desenhada à mão, igual à do Safeel (pedido do usuário de 10/11): ícone, nome em negrito
/// na aba ativa e um traço embaixo dela.
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

    @State private var aba: Aba = .inicio
    /// Abas já abertas ficam vivas (escondidas), preservando a pilha e a rolagem de cada uma.
    @State private var visitadas: Set<Aba> = [.inicio]
    /// Pilha de cada aba: trocar de aba não perde onde o usuário estava na outra.
    @State private var caminhos: [Aba: [Rota]] = [:]
    /// Relógio do início: atualizado na virada do dia e ao voltar para o app.
    @State private var agora: Date = .now

    private var hoje: Date { hojeFixo ?? agora }

    private var usuarioAtual: UsuarioMenu {
        if let usuario { return usuario }
        let u = authService.currentUser
        return UsuarioMenu(nome: u?.nome ?? "", email: u?.email ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(Aba.allCases.filter(visitadas.contains), id: \.self) { item in
                    let ativa = item == aba
                    conteudo(item)
                        .opacity(ativa ? 1 : 0)
                        .allowsHitTesting(ativa)
                        .accessibilityHidden(!ativa)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 0) {
                ForEach(Aba.allCases, id: \.self) { item in
                    BotaoAba(aba: item, selecionada: item == aba) { selecionar(item) }
                }
            }
            .padding(.horizontal, Espaco.p)
            .padding(.top, Espaco.p)
            .background {
                Tema.superficie.ignoresSafeArea(edges: .bottom)
            }
        }
        .environment(\.abrirRota) { abrir($0) }
        .tint(Tema.marcaTexto)
        .task {
            guard sincronizar else { return }
            viewModel.fetchCiclosResumo()
        }
        .onAppear {
            viewModel.modelContext = modelContext
            if !caminhoInicial.isEmpty, caminhos.isEmpty { abrirInicial(caminhoInicial) }
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

    @ViewBuilder
    private func conteudo(_ item: Aba) -> some View {
        switch item {
        case .inicio:
            pilha(.inicio) {
                InicioView(hoje: hoje, origem: origem, usuario: usuarioAtual, menuInicial: menuInicial,
                           lancamentoInicial: lancamentoInicial)
                    .navigationTitle("Início")
                    .toolbar(.hidden, for: .navigationBar)
            }
        case .viagens:
            pilha(.viagens) {
                ViagensView(hoje: hoje, origem: origem)
            }
        case .gastos:
            pilha(.gastos) {
                // Os gastos da viagem do início (a que o usuário está vendo), como o "Ver todos".
                TodosGastosView(cicloId: viewModel.cicloInicioEm(hoje)?.id, filtro: .todos)
            }
        }
    }

    /// Toque numa aba: abre a aba; tocar de novo na aba aberta volta para a raiz dela.
    private func selecionar(_ item: Aba) {
        if item == aba {
            caminhos[item] = []
        } else {
            aba = item
            visitadas.insert(item)
        }
    }

    /// Uma aba: a tela raiz numa `NavigationStack` com a pilha daquela aba.
    private func pilha<Raiz: View>(_ aba: Aba, @ViewBuilder raiz: () -> Raiz) -> some View {
        NavigationStack(path: Binding(get: { caminhos[aba] ?? [] }, set: { caminhos[aba] = $0 })) {
            raiz()
                .navigationDestination(for: Rota.self) { rota in
                    DestinoRota(rota: rota, hoje: hoje, origem: origem, usuario: usuarioAtual)
                }
        }
    }

    /// "Viagens" é uma aba: troca de aba em vez de empilhar a mesma lista de novo. O resto empilha
    /// na aba atual.
    private func abrir(_ rota: Rota) {
        if rota == .viagens {
            selecionar(.viagens)
        } else {
            caminhos[aba, default: []].append(rota)
        }
    }

    /// Pilha de entrada do modo de demonstração: começando por Viagens, abre na aba Viagens.
    private func abrirInicial(_ rotas: [Rota]) {
        if rotas.first == .viagens {
            selecionar(.viagens)
            caminhos[.viagens] = Array(rotas.dropFirst())
        } else {
            caminhos[.inicio] = rotas
        }
    }
}

/// Botão da barra de abas, no desenho do Safeel: ícone, nome (negrito quando ativa) e um traço
/// embaixo da aba ativa.
private struct BotaoAba: View {
    let aba: Aba
    let selecionada: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(spacing: 2) {
                Image(systemName: aba.simbolo)
                    .font(.body)
                Text(aba.titulo)
                    .font(.caption2)
                    .fontWeight(selecionada ? .bold : .regular)
                Capsule()
                    .fill(selecionada ? Tema.texto : .clear)
                    .frame(width: 24, height: 3)
            }
            .foregroundStyle(selecionada ? Tema.texto : Tema.textoFraco)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(aba.titulo)
        .accessibilityAddTraits(selecionada ? [.isButton, .isSelected] : .isButton)
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
