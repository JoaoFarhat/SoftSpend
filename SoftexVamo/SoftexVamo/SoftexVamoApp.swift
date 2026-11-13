//
//  SoftexVamoApp.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct SoftexVamoApp: App {
    @StateObject var listViewModel: CiclosViewModel
    @StateObject var authService = AuthService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject var errorManager = ErrorManager()
    /// Tema de Perfil e ajustes (Automático segue o iPhone).
    @AppStorage(PreferenciaTema.chave) private var tema: PreferenciaTema = .automatico
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer

    init() {
        // Container único (`BancoLocal`): o app e o App Intent "Registrar gasto"
        // (Apple Pay) usam o mesmo — ver Models/BancoLocal.swift.
        self.modelContainer = BancoLocal.container
        let viewModel = CiclosViewModel()
        let errorManager = ErrorManager()
        viewModel.errorManager = errorManager
        // Mesmo ErrorManager do alerta da raiz (`errorAlert` em `raiz`).
        AuthService.shared.errorManager = errorManager
        self._listViewModel = StateObject(wrappedValue: viewModel)
        self._errorManager = StateObject(wrappedValue: errorManager)
        // Avisos de diária aparecem também com o app aberto.
        UNUserNotificationCenter.current().delegate = AvisosNotificacaoDelegate.compartilhado
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if VitrineView.ativa {
                    VitrineView()
                } else if let estado = DemoInicioView.pedido {
                    DemoInicioView(estado: estado)
                } else {
                    raiz
                }
                #else
                raiz
                #endif
            }
            .preferredColorScheme(tema.esquema)
            // Toque fora de um campo fecha o teclado, no app inteiro (no lugar do botão "OK", 10/11).
            .task { FecharTeclado.shared.instalar() }
            .onChange(of: tema, initial: true) { _, novo in
                // `preferredColorScheme(nil)` nem sempre desfaz um tema forçado
                // antes; a janela segue a escolha (Automático = do iPhone).
                let estilo: UIUserInterfaceStyle = switch novo {
                case .automatico: .unspecified
                case .claro: .light
                case .escuro: .dark
                }
                for cena in UIApplication.shared.connectedScenes {
                    (cena as? UIWindowScene)?.windows.forEach { $0.overrideUserInterfaceStyle = estilo }
                }
            }
            .onChange(of: scenePhase) { _, fase in
                // A ação "Registrar gasto" (Apple Pay) pode acordar o app com o
                // iPhone trancado: o token (WhenUnlockedThisDeviceOnly) fica
                // ilegível e o `AuthService` nasce com isAuthenticated == false.
                // Reler ao ativar evita um falso logout; checkAuthentication só
                // lê, nunca apaga nada. Ver docs/cartao-sem-open-finance.md §1.3.
                if fase == .active, !authService.isAuthenticated {
                    authService.checkAuthentication()
                }
            }
        }
        .modelContainer(modelContainer)
    }

    private var raiz: some View {
        Group {
            if authService.isAuthenticated {
                MainView()
                    .environmentObject(listViewModel)
                    .id(authService.currentUser?.id)
            } else {
                LoginView()

            }
        }
        .environmentObject(authService)
        .environmentObject(errorManager)
        // Único alerta de erro do app: CiclosViewModel, AuthService e as telas
        // que usam `errorManager` (exportar, excluir viagem, apagar gasto...).
        .errorAlert(errorManager: errorManager)
        .onChange(of: authService.currentUser?.id) { _, _ in
            // Com userId nos models, não precisa limpar dados no logout —
            // cada usuário só vê os próprios dados via filtro por userId.
            // Dados offline pendentes de sync são preservados para quando
            // o usuário original logar novamente.
            listViewModel.reset()
        }
    }

}
