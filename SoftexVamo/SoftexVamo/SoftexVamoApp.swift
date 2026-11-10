//
//  SoftexVamoApp.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import SwiftData
import os
import UserNotifications

@main
struct SoftexVamoApp: App {
    @StateObject var listViewModel: CiclosViewModel
    @StateObject var authService = AuthService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject var errorManager = ErrorManager()
    /// Tema de Perfil e ajustes (Automático segue o iPhone).
    @AppStorage(PreferenciaTema.chave) private var tema: PreferenciaTema = .automatico

    let modelContainer: ModelContainer

    init() {
        self.modelContainer = Self.createModelContainer()
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

    private static let appLogger = Logger(subsystem: "br.com.softspend", category: "SoftexVamoApp")

    /// Abre o banco local com o schema versionado (`SoftSpendSchemaV1`) e o
    /// `SoftSpendMigrationPlan`. O nome `"softspend"` e o arquivo
    /// `softspend_v1.sqlite` não mudam: o banco da `main` é reconhecido como V1.
    ///
    /// Se o container não abrir (banco de build antiga que não bate com nenhuma
    /// versão do plano, ou erro inesperado), o banco vai para quarentena: o
    /// `.sqlite`, o `-wal` e o `-shm` são movidos para
    /// `Application Support/softspend-backup-<yyyyMMdd-HHmmss>/` e um banco novo
    /// é criado. Nada é apagado; o que já estava sincronizado volta do backend.
    /// Spec: docs/migracao-banco-local-ios.md.
    private static func createModelContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: SoftSpendSchemaV1.self)

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

        func abrir() throws -> ModelContainer {
            try ModelContainer(
                for: schema,
                migrationPlan: SoftSpendMigrationPlan.self,
                configurations: [config]
            )
        }

        do {
            return try abrir()
        } catch {
            let nsError = error as NSError
            appLogger.error("Falha ao abrir banco local em \(storeURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            appLogger.error("userInfo do erro: \(String(describing: nsError.userInfo), privacy: .public)")

            if let backupDir = moverParaQuarentena(storeURL: storeURL, supportDir: supportDir) {
                appLogger.warning("Banco antigo em quarentena (backup) em \(backupDir.path, privacy: .public). Criando banco novo.")
            }

            do {
                return try abrir()
            } catch {
                let nsError = error as NSError
                appLogger.fault("Falha fatal ao recriar banco: \(String(describing: error), privacy: .public) userInfo: \(String(describing: nsError.userInfo), privacy: .public)")
                fatalError("Não foi possível criar o banco local: \(error)")
            }
        }
    }

    /// Move o `.sqlite`, o `-wal` e o `-shm` do banco para uma pasta de backup
    /// datada ao lado. Nunca apaga. Devolve a pasta se moveu ao menos um arquivo.
    private static func moverParaQuarentena(storeURL: URL, supportDir: URL) -> URL? {
        let fm = FileManager.default
        let nome = storeURL.lastPathComponent
        let arquivos = [nome, nome + "-wal", nome + "-shm"]
            .map { storeURL.deletingLastPathComponent().appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }

        guard !arquivos.isEmpty else {
            appLogger.warning("Nenhum arquivo do banco para pôr em quarentena em \(storeURL.path, privacy: .public).")
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backupDir = supportDir.appendingPathComponent("softspend-backup-\(formatter.string(from: Date()))")
        if fm.fileExists(atPath: backupDir.path) {
            backupDir = supportDir.appendingPathComponent("softspend-backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
        }

        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            appLogger.error("Não conseguiu criar a pasta de backup \(backupDir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        var moveuAlgum = false
        for arquivo in arquivos {
            do {
                try fm.moveItem(at: arquivo, to: backupDir.appendingPathComponent(arquivo.lastPathComponent))
                moveuAlgum = true
            } catch {
                appLogger.error("Não conseguiu mover \(arquivo.lastPathComponent, privacy: .public) para o backup: \(String(describing: error), privacy: .public)")
            }
        }
        return moveuAlgum ? backupDir : nil
    }
}
