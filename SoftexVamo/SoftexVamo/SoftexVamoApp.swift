//
//  SoftexVamoApp.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import SwiftData
import os

@main
struct SoftexVamoApp: App {
    @StateObject var listViewModel = CiclosViewModel()
    @StateObject var authService = AuthService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared

    let modelContainer: ModelContainer

    init() {
        self.modelContainer = Self.createModelContainer()
    }

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
        }
        .modelContainer(modelContainer)
    }

    private static let appLogger = Logger(subsystem: "br.com.softspend", category: "SoftexVamoApp")

    /// Cria o ModelContainer com fallback destrutivo: se o banco existente for
    /// incompatível com o schema atual (ex: UserModel.id mudou de Int para
    /// String, CicloSoftex ganhou userId, etc.), apaga o arquivo e cria um
    /// novo. Isso perde dados locais não-sincronizados, mas evita crash/save
    /// silencioso enquanto o app ainda não tem um SchemaMigrationPlan oficial.
    /// TODO: substituir por VersionedSchema + SchemaMigrationPlan antes do
    /// release para usuários reais.
    private static func createModelContainer() -> ModelContainer {
        let models: [any PersistentModel.Type] = [CicloSoftex.self, DiaSoftex.self, GastosDia.self, UserModel.self]
        let schema = Schema(models)

        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        let storeURL = supportDir.appendingPathComponent("softspend_v1.sqlite")
        let config = ModelConfiguration(
            "softspend",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            appLogger.error("Falha ao abrir banco local em \(storeURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            appLogger.warning("Apagando banco incompatível e recriando (fallback destrutivo).")

            if FileManager.default.fileExists(atPath: storeURL.path) {
                do {
                    try FileManager.default.removeItem(at: storeURL)
                    appLogger.warning("Banco antigo removido: \(storeURL, privacy: .public)")
                } catch {
                    appLogger.error("Não conseguiu apagar banco antigo: \(error.localizedDescription, privacy: .public)")
                }
            }

            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                appLogger.fault("Falha fatal ao recriar banco: \(error.localizedDescription, privacy: .public)")
                fatalError("Não foi possível criar o banco local: \(error)")
            }
        }
    }
}
