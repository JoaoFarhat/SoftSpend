//
//  BancoLocal.swift
//  SoftexVamo
//
//  Container único do banco local (SwiftData), extraído de `SoftexVamoApp`.
//

import Foundation
import CoreData
import SwiftData
import os

/// O `ModelContainer` único do app, compartilhado com o App Intent
/// "Registrar gasto" (Apple Pay, docs/cartao-sem-open-finance.md §1.3).
/// O nome `"softspend"` e o arquivo `softspend_v1.sqlite` não mudam, e a
/// quarentena continua igual: dois containers no mesmo arquivo é o que se
/// quer evitar, e o `mainContext` compartilhado faz a tela aberta atualizar
/// na hora em que a ação grava um gasto.
///
/// `nonisolated` porque a ação pode rodar com o aparelho trancado, fora do
/// MainActor; a inicialização é preguiçosa e thread-safe (static let).
nonisolated enum BancoLocal {
    private static let abertura = criar()

    static let container: ModelContainer = abertura.container

    /// `true` quando o banco real não abriu por falta de espaço no iPhone:
    /// nenhum arquivo foi tocado e `container` é só em memória (nada é
    /// gravado). A faixa `avisoSemEspaco` fica no topo do `SoftexVamoApp.raiz`
    /// até o usuário liberar espaço e reabrir — aí o banco de verdade volta
    /// com tudo intacto, inclusive o que ainda não subiu.
    static let semEspacoNoDisco: Bool = abertura.semEspacoNoDisco

    static let avisoSemEspaco = "Sem espaço no iPhone; libere espaço e abra de novo"

    private static let logger = Logger(subsystem: "br.com.softspend", category: "BancoLocal")

    /// O que fazer quando o `ModelContainer` não abre. Decisão pura sobre o
    /// `NSError` (domínio + código + cadeia `NSUnderlyingErrorKey`), testada
    /// em `SoftSpendTests/FaltaDeEspacoBancoTests.swift`.
    nonisolated enum AcaoFalhaAbertura {
        /// Falta de espaço: não mexe em arquivo nenhum; abre só em memória.
        case emMemoriaSemEspaco
        /// Outro erro: `.sqlite`, `-wal` e `-shm` vão para a quarentena.
        case quarentena
    }

    /// Falta de espaço aparece como `NSCocoaErrorDomain` 640
    /// (`NSFileWriteOutOfSpaceError`) quando a falha vem do arquivo, ou como
    /// `NSSQLiteErrorDomain` 13 (`SQLITE_FULL`) quando vem do SQLite — às
    /// vezes como `NSUnderlyingError` de um erro maior do Core Data. `ENOSPC`
    /// (28) em `NSPOSIXErrorDomain` é a mesma coisa um andar abaixo.
    static func acaoAposFalhaDeAbertura(_ erro: Error) -> AcaoFalhaAbertura {
        ehFaltaDeEspaco(erro as NSError) ? .emMemoriaSemEspaco : .quarentena
    }

    private static func ehFaltaDeEspaco(_ erro: NSError) -> Bool {
        switch (erro.domain, erro.code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSSQLiteErrorDomain, 13),
             (NSPOSIXErrorDomain, 28):
            return true
        default:
            break
        }
        guard let subjacente = erro.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return ehFaltaDeEspaco(subjacente)
    }

    /// Abre o banco local com o schema versionado (`SoftSpendSchemaV1`) e o
    /// `SoftSpendMigrationPlan`.
    ///
    /// Se o container não abrir, o erro decide o fallback
    /// (`acaoAposFalhaDeAbertura`):
    ///
    /// - **Falta de espaço** (`NSCocoaErrorDomain` 640, `NSSQLiteErrorDomain`
    ///   13/`SQLITE_FULL`, `ENOSPC` — também via `NSUnderlyingErrorKey`):
    ///   nenhum arquivo é tocado; o container é só em memória
    ///   (`semEspacoNoDisco`) e o app avisa "Sem espaço no iPhone; libere
    ///   espaço e abra de novo". O `.sqlite` original — e o que ainda não
    ///   subiu — fica intacto.
    /// - **Qualquer outro erro** (banco de build antiga que não bate com
    ///   nenhuma versão do plano, corrupção...): quarentena — o `.sqlite`, o
    ///   `-wal` e o `-shm` são movidos para
    ///   `Application Support/softspend-backup-<yyyyMMdd-HHmmss>/` e um banco
    ///   novo é criado. Nada é apagado; o que já estava sincronizado volta do
    ///   backend.
    /// Spec: docs/migracao-banco-local-ios.md.
    private static func criar() -> (container: ModelContainer, semEspacoNoDisco: Bool) {
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

        func abrirEmMemoria() throws -> ModelContainer {
            let configMemoria = ModelConfiguration(
                "softspend",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: schema,
                migrationPlan: SoftSpendMigrationPlan.self,
                configurations: [configMemoria]
            )
        }

        do {
            return (try abrir(), false)
        } catch {
            let nsError = error as NSError
            logger.error("Falha ao abrir banco local em \(storeURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            logger.error("userInfo do erro: \(String(describing: nsError.userInfo), privacy: .public)")

            if acaoAposFalhaDeAbertura(error) == .emMemoriaSemEspaco {
                logger.warning("Sem espaço no iPhone: \(storeURL.path, privacy: .public) intocado, banco abre só em memória.")
                do {
                    return (try abrirEmMemoria(), true)
                } catch {
                    let nsError = error as NSError
                    logger.fault("Falha fatal ao abrir banco em memória: \(String(describing: error), privacy: .public) userInfo: \(String(describing: nsError.userInfo), privacy: .public)")
                    fatalError("Não foi possível criar o banco local em memória: \(error)")
                }
            }

            if let backupDir = moverParaQuarentena(storeURL: storeURL, supportDir: supportDir) {
                logger.warning("Banco antigo em quarentena (backup) em \(backupDir.path, privacy: .public). Criando banco novo.")
            }

            do {
                return (try abrir(), false)
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
