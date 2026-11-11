//
//  SyncAPI.swift
//  SoftexVamo
//

import Foundation

/// Chamadas de rede usadas pelo `SyncActor`, e só elas.
///
/// Existe para o `SyncActor` poder ser testado com uma API falsa
/// (`SoftSpendTests/FakeSyncAPI.swift`). Em produção quem implementa é o
/// `NetworkManager`, que é o padrão do `init` do `SyncActor`.
///
/// É `nonisolated` (e a conformidade do `NetworkManager` também) pelo mesmo
/// motivo do `NetworkManager`: com `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// sem isso as chamadas feitas pelo `SyncActor` passariam pelo MainActor.
/// Ver "Isolamento de actor" no `AGENTS.md`.
nonisolated protocol SyncAPI: Sendable {
    func postCiclo(request: CicloCreateRequest) async throws -> CicloSoftex
    func putCiclo(cicloId: Int, request: CicloUpdateRequest) async throws -> CicloSoftex
    func deleteCiclo(cicloId: Int) async throws

    /// `POST /ciclos/{id}/dias/lote`: só cria (deduplica por `client_id`).
    func postDiasLote(cicloId: Int, dias: [DiaLoteRequest]) async throws -> [DiaSoftex]
    /// `PUT /ciclos/{id}/dias/lote`: substitui a lista e **remove** os dias que não vierem nela.
    func syncDiasLote(cicloId: Int, dias: [DiaLoteRequest]) async throws -> [DiaSoftex]
    func deleteDia(diaId: Int) async throws

    func postGasto(request: GastoCreateRequest) async throws -> GastosDia
    func putGasto(gastoId: Int, request: GastoUpdateRequest) async throws -> GastosDia
    func deleteGasto(gastoId: Int) async throws

    func uploadComprovante(gastoId: Int, imageData: Data, mime: String) async throws -> GastosDia
    func deleteComprovante(gastoId: Int) async throws -> GastosDia
}

nonisolated extension NetworkManager: SyncAPI {}
