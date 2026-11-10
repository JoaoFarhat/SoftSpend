//
//  SoftSpendSchema.swift
//  SoftexVamo
//
//  Schema versionado do banco local (SwiftData).
//  Spec: docs/migracao-banco-local-ios.md
//

import SwiftData

/// V1 = o schema que a `main` já gravava em `softspend_v1.sqlite` antes de
/// existir versão. Aponta para as classes vivas: qualquer mudança em um
/// `@Model` muda o checksum e deixa de reconhecer os bancos existentes.
/// Antes da primeira mudança de modelo, congele o V1 em cópias aninhadas e
/// crie o V2 (seção 5 da spec).
nonisolated enum SoftSpendSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            CicloSoftex.self,
            DiaSoftex.self,
            GastosDia.self,
            UserModel.self,
            CartaoOpenFinance.self,
            FaturaCartao.self,
            TransacaoCartao.self,
        ]
    }
}

/// Plano de migração do banco local. Hoje só existe o V1, sem stages.
nonisolated enum SoftSpendMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SoftSpendSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
