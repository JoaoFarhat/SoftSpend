import Foundation
import SwiftData
import os

/// O container único do banco local (§1.3 de `docs/cartao-sem-open-finance.md`).
///
/// O `SoftexVamoApp` e a ação do Apple Pay (`RegistrarGastoIntent`, que roda
/// sem abrir o app) usam a mesma instância: dois `ModelContainer` no mesmo
/// arquivo é o que se quer evitar. Como a ação grava no `mainContext`
/// compartilhado, a tela aberta também atualiza na hora.
///
/// O conteúdo é o `createModelContainer` que vivia em `SoftexVamoApp`, sem
/// mudança: nome `"softspend"`, arquivo `softspend_v1.sqlite` e quarentena do
/// banco que não abre (`docs/migracao-banco-local-ios.md`).
nonisolated enum BancoLocal {
    static let container: ModelContainer = criar()

    private static let logger = Logger(subsystem: "br.com.softspend", category: "BancoLocal")

    /// Abre o banco local com o schema versionado (`SoftSpendSchemaV1`) e o
    /// `SoftSpendMigrationPlan`. O nome `"softspend"` e o arquivo
    /// `softspend_v1.sqlite` não mudam: o banco da `main` é reconhecido como V1.
    ///
    /// Se o container não abrir (banco de build antiga que não bate com nenhuma
    /// versão do plano, ou erro inesperado), o banco vai para quarentena: o
    /// `.sqlite`, o `-wal` e o `-shm` são movidos para
    /// `Application Support/softspend-backup-<yyyyMMdd-HHmmss>/` e um banco novo
    /// é criado. Nada é apagado; o que já estava sincronizado volta do backend.
    private static func criar() -> ModelContainer {
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
            logger.error("Falha ao abrir banco local em \(storeURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            logger.error("userInfo do erro: \(String(describing: nsError.userInfo), privacy: .public)")

            if let backupDir = moverParaQuarentena(storeURL: storeURL, supportDir: supportDir) {
                logger.warning("Banco antigo em quarentena (backup) em \(backupDir.path, privacy: .public). Criando banco novo.")
            }

            do {
                return try abrir()
            } catch {
                let nsError = error as NSError
                logger.fault("Falha fatal ao recriar banco: \(String(describing: error), privacy: .public) userInfo: \(String(describing: nsError.userInfo), privacy: .public)")
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
            logger.warning("Nenhum arquivo do banco para pôr em quarentena em \(storeURL.path, privacy: .public).")
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
            logger.error("Não conseguiu criar a pasta de backup \(backupDir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        var moveuAlgum = false
        for arquivo in arquivos {
            do {
                try fm.moveItem(at: arquivo, to: backupDir.appendingPathComponent(arquivo.lastPathComponent))
                moveuAlgum = true
            } catch {
                logger.error("Não conseguiu mover \(arquivo.lastPathComponent, privacy: .public) para o backup: \(String(describing: error), privacy: .public)")
            }
        }
        return moveuAlgum ? backupDir : nil
    }
}
