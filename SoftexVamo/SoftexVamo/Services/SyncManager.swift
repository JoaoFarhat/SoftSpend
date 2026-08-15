//
//  SyncManager.swift
//  SoftexVamo
//

import Foundation
import SwiftData
import Combine
import os

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var isSyncing = false
    @Published var pendentesRestantes: Int = 0
    private var syncActor: SyncActor?

    func configure(container: ModelContainer) {
        syncActor = SyncActor(modelContainer: container)
    }

    func sync() async {
        guard let syncActor, !isSyncing else { return }
        guard NetworkMonitor.shared.isConnected else { return }
        isSyncing = true
        defer { isSyncing = false }
        let agora = Date()
        let restantes = await syncActor.sync(agora: agora)
        pendentesRestantes = restantes
    }

}

@ModelActor
actor SyncActor {

    private let logger = Logger(subsystem: "br.com.softspend", category: "SyncActor")

    /// Salva o `modelContext` logando falhas em vez de silenciá-las.
    /// Sync em background não pode mostrar UI, mas o log aparece no Console.app.
    private func salvarContexto(_ contexto: String) {
        do {
            try modelContext.save()
        } catch {
            logger.error("Falha ao salvar após \(contexto, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func sync(agora: Date) async -> Int {
        let maxPassadas = 5

        var pendentesDepois = 0
        for _ in 0..<maxPassadas {
            let pendentesAntes = contarPendentes(agora: agora)
            await syncCiclos(agora: agora)
            await syncDias(agora: agora)
            await syncGastos(agora: agora)
            await syncComprovantes(agora: agora)
            await syncDeletions(agora: agora)
            pendentesDepois = contarPendentes(agora: agora)
            if pendentesDepois == 0 || pendentesDepois >= pendentesAntes { break }
        }
        return pendentesDepois
    }

    private func contarPendentes(agora: Date) -> Int {
        let synced = SyncStatus.synced.rawValue
        // fetchCount é mais leve que fetch — não materializa objetos em memória.
        // Não filtra por proximaTentativaEm aqui (Date dinâmico não vai em #Predicate);
        // o valor serve como indicador de progresso para o loop de passadas.
        let cicloDesc = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        let diaDesc = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        let gastoDesc = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        let ciclos = (try? modelContext.fetchCount(cicloDesc)) ?? 0
        let dias = (try? modelContext.fetchCount(diaDesc)) ?? 0
        let gastos = (try? modelContext.fetchCount(gastoDesc)) ?? 0
        return ciclos + dias + gastos
    }

    private func sincronizarEdicaoCiclo(_ ciclo: CicloSoftex, agora: Date) async {
        guard let backendId = ciclo.backendId, deveTentar(ciclo, agora: agora) else { return }

        let diasPendentes = ciclo.dias?.filter {
            $0.backendId == nil && $0.deletadoEm == nil
        } ?? []

        let diasRequest: [DiaLoteRequest]? = diasPendentes.isEmpty ? nil : diasPendentes.map {
            DiaLoteRequest(clientId: $0.clientId, data: $0.data)
        }

        // Snapshot antes do await para detectar reedição concorrente.
        // NOTA: O SyncActor tem seu próprio ModelContext isolado via @ModelActor.
        // Mudanças da UI em outro context não são visíveis aqui durante o await,
        // mas podem ser mescladas automaticamente se o store usar autosave.
        // O snapshot captura o estado local atual; após o resume, comparamos
        // para preservar edições do usuário feitas durante a requisição.
        let tituloAntes = ciclo.titulo
        let valorTotalAntes = ciclo.valor_total
        let diariaAntes = ciclo.diaria
        let periodoAntes = ciclo.periodo

        do {
            let updateRequest = CicloUpdateRequest(
                titulo: ciclo.titulo,
                valor_total: ciclo.valor_total,
                diaria: ciclo.diaria,
                periodo: ciclo.periodo
            )
            
            let cicloEditado = try await NetworkManager.shared.putCiclo(cicloId: backendId, request: updateRequest)

            if let diasRequest {
                cicloEditado.dias = try await NetworkManager.shared.syncDiasLote(cicloId: backendId, dias: diasRequest)
            }

            let houveReedicao = ciclo.titulo != tituloAntes
                || ciclo.valor_total != valorTotalAntes
                || ciclo.diaria != diariaAntes
                || ciclo.periodo != periodoAntes

            if !houveReedicao {
                ciclo.titulo = cicloEditado.titulo
                ciclo.valor_total = cicloEditado.valor_total
                ciclo.periodo = cicloEditado.periodo
                ciclo.diaria = cicloEditado.diaria
            }

            ciclo.gasto_total = cicloEditado.gasto_total
            ciclo.syncStatus = .synced
            ciclo.syncError = nil

            if let diasRemotos = cicloEditado.dias {
                let descriptor = FetchDescriptor<DiaSoftex>(
                    predicate: #Predicate { $0.ciclo?.backendId == backendId }
                )
                let locais = (try? modelContext.fetch(descriptor)) ?? []
                let idsRemotos = Set(diasRemotos.compactMap { $0.backendId })
                for local in locais where local.backendId != nil && !idsRemotos.contains(local.backendId!) {
                    local.deletadoEm = Date()
                    local.syncStatus = .pending
                }
                for diaRemoto in diasRemotos {
                    if let local = locais.first(where: { $0.backendId == diaRemoto.backendId }) {
                        local.data = diaRemoto.data
                        local.saldo = diaRemoto.saldo
                        local.syncStatus = .synced
                    } else if let remotoId = diaRemoto.backendId, !(ciclo.dias?.contains(where: { $0.backendId == remotoId }) ?? false) {
                        diaRemoto.ciclo = ciclo
                        diaRemoto.syncStatus = .synced
                        modelContext.insert(diaRemoto)
                        ciclo.dias?.append(diaRemoto)
                    } else if diaRemoto.backendId == nil {
                        logger.warning("Dia remoto sem backendId ignorado no ciclo \(String(describing: backendId), privacy: .public)")
                    }
                }
            }

            try modelContext.save()
        } catch {
            ciclo.syncError = error.localizedDescription
            marcarFalha(ciclo)
            salvarContexto("sincronizarEdicaoCiclo-catch")
        }
    }

    private func deveTentar(_ item: any Syncavel, agora: Date) -> Bool {
        guard let proxima = item.proximaTentativaEm else { return true }
        return proxima <= agora
    }

    private func calcularBackoff(tentativas: Int) -> TimeInterval {
        let base: TimeInterval = 60
        let maximo: TimeInterval = 3600
        let multiplicador = min(pow(2.0, Double(tentativas)), maximo / base)
        return base * multiplicador
    }

    private func marcarFalha(_ item: any Syncavel) {
        item.tentativas += 1
        item.proximaTentativaEm = Date().addingTimeInterval(calcularBackoff(tentativas: item.tentativas))
        item.syncStatus = .failed
    }

    private func marcarSucesso(_ item: any Syncavel) {
        item.tentativas = 0
        item.proximaTentativaEm = nil
        item.syncStatus = .synced
        item.syncError = nil
    }

    private func syncCiclos(agora: Date) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let ciclos = todos.filter { deveTentar($0, agora: agora) }

        for ciclo in ciclos {
            if ciclo.backendId != nil {
                await sincronizarEdicaoCiclo(ciclo, agora: agora)
            } else {
                do {
                    let createRequest = CicloCreateRequest(
                        client_id: ciclo.clientId,
                        titulo: ciclo.titulo,
                        valor_total: ciclo.valor_total,
                        diaria: ciclo.diaria,
                        periodo: ciclo.periodo
                    )
                    let response = try await NetworkManager.shared.postCiclo(request: createRequest)
                    ciclo.backendId = response.backendId
                    ciclo.gasto_total = response.gasto_total
                    marcarSucesso(ciclo)
                } catch {
                    ciclo.syncError = error.localizedDescription
                    marcarFalha(ciclo)
                }
            }
        }

        salvarContexto("syncCiclos")
    }

    private func syncDias(agora: Date) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let dias = todos.filter { deveTentar($0, agora: agora) }

        for dia in dias {
            guard let cicloId = dia.ciclo?.backendId else {
                // Ciclo pai ainda não sincronizado: deixar como pending para próxima passada
                continue
            }

            let request = DiaLoteRequest(clientId: dia.clientId, data: dia.data)
            do {
                let response = try await NetworkManager.shared.postDiasLote(cicloId: cicloId, dias: [request])
                if let primeiro = response.first {
                    dia.backendId = primeiro.backendId
                    // Reconcilia saldo com servidor (backend pode ajustar inicial)
                    dia.saldo = primeiro.saldo
                    // diaId dos gastos é derivado de dia?.backendId — não precisa atualizar manualmente
                    marcarSucesso(dia)
                } else {
                    dia.syncError = "Falha ao sincronizar dia"
                    marcarFalha(dia)
                }
            } catch {
                dia.syncError = error.localizedDescription
                marcarFalha(dia)
            }
        }

        salvarContexto("syncDias")
    }

    private func syncGastos(agora: Date) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let gastos = todos.filter { deveTentar($0, agora: agora) }

        for gasto in gastos {
            // Verificação de dependência via relação: se o dia pai ainda não tem
            // backendId, o gasto aguarda na fila. Assim que syncDias rodar e der
            // um backendId ao dia, na próxima passada o gasto passa aqui.
            guard let diaIdReal = gasto.dia?.backendId else {
                continue
            }

            do {
                if let backendId = gasto.backendId {
                    let updateRequest = GastoUpdateRequest(
                        titulo: gasto.titulo,
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: diaIdReal
                    )
                    let response = try await NetworkManager.shared.putGasto(gastoId: backendId, request: updateRequest)
                    gasto.comprovanteUrl = response.comprovanteUrl
                    // Só marca sucesso se não há comprovante pendente; syncComprovantes resolve o resto
                    if gasto.comprovanteData == nil && !gasto.comprovanteParaRemover {
                        marcarSucesso(gasto)
                    }
                } else {
                    let createRequest = GastoCreateRequest(
                        client_id: gasto.clientId,
                        titulo: gasto.titulo,
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: diaIdReal
                    )
                    let response = try await NetworkManager.shared.postGasto(request: createRequest)
                    guard let novoGastoId = response.backendId else {
                        throw URLError(.cannotParseResponse)
                    }
                    gasto.backendId = novoGastoId
                    gasto.comprovanteUrl = response.comprovanteUrl
                    // Só marca sucesso se não há comprovante pendente; syncComprovantes resolve o resto
                    if gasto.comprovanteData == nil && !gasto.comprovanteParaRemover {
                        marcarSucesso(gasto)
                    }
                }
            } catch {
                gasto.syncError = error.localizedDescription
                marcarFalha(gasto)
            }
        }

        salvarContexto("syncGastos")
    }

    private func syncComprovantes(agora: Date) async {
        let synced = SyncStatus.synced.rawValue
        // comprovanteData é @Transient (não persistido no banco).
        // #Predicate só pode referenciar propriedades persistidas,
        // então usamos comprovanteDataCriptografado no predicado e
        // fazemos o filtro por comprovanteData em memória depois.
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in
                item.syncStatusRaw != synced &&
                (item.comprovanteDataCriptografado != nil || item.comprovanteParaRemover) &&
                item.deletadoEm == nil
            },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let gastos = todos.filter { $0.backendId != nil && deveTentar($0, agora: agora) }

        for gasto in gastos {
            guard let backendId = gasto.backendId else { continue }
            do {
                try await sincronizarComprovante(gasto, backendId: backendId)
                // Só marca sucesso se não há mais comprovante pendente
                // (pode ter sido marcado .synced por syncGastos, mas comprovante ainda pendente)
                if gasto.comprovanteData == nil && !gasto.comprovanteParaRemover {
                    marcarSucesso(gasto)
                }
            } catch {
                gasto.syncError = error.localizedDescription
                marcarFalha(gasto)
            }
        }

        salvarContexto("syncComprovantes")
    }

    private func sincronizarComprovante(_ gasto: GastosDia, backendId: Int) async throws {
        if gasto.comprovanteData != nil && gasto.comprovanteParaRemover {
            gasto.comprovanteParaRemover = false
        }

        guard gasto.comprovanteData != nil || gasto.comprovanteParaRemover else { return }

        if let comprovanteData = gasto.comprovanteData {
            let atualizado = try await NetworkManager.shared.uploadComprovante(gastoId: backendId, imageData: comprovanteData)
            gasto.comprovanteUrl = atualizado.comprovanteUrl
            gasto.comprovanteData = nil
        } else if gasto.comprovanteParaRemover {
            do {
                _ = try await NetworkManager.shared.deleteComprovante(gastoId: backendId)
            } catch {
                if !isNotFoundError(error) {
                    throw error
                }
            }
            gasto.comprovanteUrl = nil
            gasto.comprovanteData = nil
            gasto.comprovanteParaRemover = false
        }
    }

    private func isNotFoundError(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            if case .serverError(_, _, let statusCode) = apiError {
                return statusCode == 404
            }
        }
        let nsError = error as NSError
        if let statusCode = nsError.userInfo["statusCode"] as? Int {
            return statusCode == 404
        }
        return false
    }

    private func syncDeletions(agora: Date) async {
        let synced = SyncStatus.synced.rawValue

        let gastoDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )

        let gastos = ((try? modelContext.fetch(gastoDescriptor)) ?? []).filter { deveTentar($0, agora: agora) }

        for gasto in gastos {
            guard let backendId = gasto.backendId else {
                modelContext.delete(gasto)
                continue
            }

            do {
                try await NetworkManager.shared.deleteGasto(gastoId: backendId)
            } catch {
                if !isNotFoundError(error) {
                    marcarFalha(gasto)
                    gasto.syncError = error.localizedDescription
                    continue
                }
          }
            modelContext.delete(gasto)
        }

        let diaDescriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let dias = ((try? modelContext.fetch(diaDescriptor)) ?? []).filter { deveTentar($0, agora: agora) }

        for dia in dias {

            guard let backendId = dia.backendId else {
                modelContext.delete(dia)
                continue
            }

            do {
                try await NetworkManager.shared.deleteDia(diaId: backendId)
            } catch {
                if !isNotFoundError(error) {
                    marcarFalha(dia)
                    dia.syncError = error.localizedDescription
                    continue
                }
            }
            modelContext.delete(dia)
        }

        let cicloDescriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let ciclos = ((try? modelContext.fetch(cicloDescriptor)) ?? []).filter { deveTentar($0, agora: agora) }

        for ciclo in ciclos {
            guard let backendId = ciclo.backendId else {
                modelContext.delete(ciclo)
                continue
            }

            do {
                try await NetworkManager.shared.deleteCiclo(cicloId: backendId)
            } catch {
                if !isNotFoundError(error) {
                    marcarFalha(ciclo)
                    ciclo.syncError = error.localizedDescription
                    continue
                }
            }
            modelContext.delete(ciclo)
        }

        salvarContexto("syncDeletions")
    }
}

nonisolated protocol Syncavel: AnyObject {
    var tentativas: Int { get set }
    var proximaTentativaEm: Date? { get set }
    var syncStatus: SyncStatus { get set }
    var syncError: String? { get set }
}

nonisolated extension CicloSoftex: Syncavel {}
nonisolated extension DiaSoftex: Syncavel {}
nonisolated extension GastosDia: Syncavel {}

enum SyncError: Error, LocalizedError {
    case cicloNaoSincronizado
    case modelContextNaoConfigurado
    case sincronizacaoEmProgresso

    var errorDescription: String? {
        switch self {
        case .cicloNaoSincronizado:
            return "O ciclo ainda não foi sincronizado com o servidor"
        case .modelContextNaoConfigurado:
            return "Contexto do banco de dados não configurado"
        case .sincronizacaoEmProgresso:
            return "Uma sincronização já está em andamento"
        }
    }
}
