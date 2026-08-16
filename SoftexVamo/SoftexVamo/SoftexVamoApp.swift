//
//  SoftexVamoApp.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import SwiftData

@main
struct SoftexVamoApp: App {
    @StateObject var listViewModel = CiclosViewModel()
    @StateObject var authService = AuthService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared

    var body: some Scene {
        WindowGroup {
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
            .onChange(of: authService.currentUser?.id) { _, _ in
                // Com userId nos models, não precisa limpar dados no logout —
                // cada usuário só vê os próprios dados via filtro por userId.
                // Dados offline pendentes de sync são preservados para quando
                // o usuário original logar novamente.
                listViewModel.reset()
            }
            .onChange(of: networkMonitor.isConnected) { _, isConnected in
                // Quando a conexão volta, dispara o sync para enviar itens
                // pendentes que acumularam enquanto offline. O debounce de 1s
                // evita disparar sync em rajadas quando a rede oscila.
                if isConnected {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await SyncManager.shared.sync()
                    }
                }
            }
            .modelContainer(for: [CicloSoftex.self, DiaSoftex.self, GastosDia.self, UserModel.self])
        }
    }
}
