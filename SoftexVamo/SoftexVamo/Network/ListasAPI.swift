//
//  ListasAPI.swift
//  SoftexVamo
//

import Foundation

/// Chamadas de leitura das listas usadas pelo `CiclosViewModel`, e só elas:
/// o resumo das viagens (`fetchCicloResumo`, paginado por cursor `antes_de`)
/// e os dias da viagem aberta (`fetchDias`, paginado por `skip`).
///
/// Existe para o `CiclosViewModel` poder ser testado com uma API falsa
/// (`SoftSpendTests/FakeListasAPI.swift`), como o `SyncAPI` faz pelo
/// `SyncActor`. Em produção quem implementa é o `NetworkManager`, que é o
/// padrão do `init(api:)` do ViewModel.
///
/// É `nonisolated` pelo mesmo motivo do `SyncAPI`/`NetworkManager`: com
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, sem isso a conformidade do
/// `NetworkManager` (cujos métodos são `nonisolated`) não valeria. Ver
/// "Isolamento de actor" no `AGENTS.md`.
nonisolated protocol ListasAPI: Sendable {
    /// `GET /usuario/ciclos/resumo`: `antesDe` é o menor `backendId` da página
    /// anterior (`nil` na primeira). `skip` é o parâmetro legado, sempre 0 aqui.
    func fetchCicloResumo(antesDe: Int?, skip: Int, limit: Int) async throws -> [CicloSoftex]

    /// `GET /ciclos/{id}/dias`: página por `skip`.
    func fetchDias(cicloId: Int, skip: Int, limit: Int) async throws -> [DiaSoftex]
}

nonisolated extension NetworkManager: ListasAPI {}
