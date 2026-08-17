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
    @Published var lastSyncError: Error?
    private var syncActor: SyncActor?
    private var networkObservationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "br.com.softspend", category: "SyncManager")

    init() {
        observeNetwork()
    }

    deinit {
        networkObservationTask?.cancel()
    }

    private func observeNetwork() {
        networkObservationTask = Task {
            var wasConnected = NetworkMonitor.shared.isConnected
            for await connected in NetworkMonitor.shared.$isConnected.values {
                if connected && !wasConnected {
                    logger.info("SyncManager: conexão voltou, sync forçado")
                    await sync(forcar: true)
                }
                wasConnected = connected
            }
        }
    }

    func configure(container: ModelContainer) {
        syncActor = SyncActor(modelContainer: container)
        if NetworkMonitor.shared.isConnected {
            Task {
                await sync(forcar: true)
            }
        }
    }

    /// Remove do banco local ciclos, dias e gastos que já foram sincronizados
    /// como deletados há mais de 7 dias. Evita acúmulo de registros mortos.
    func limparDadosMortos(context: ModelContext) {
        let limite = Date().addingTimeInterval(-7 * 24 * 3600)
        let synced = SyncStatus.synced.rawValue

        do {
            let cicloDesc = FetchDescriptor<CicloSoftex>(
                predicate: #Predicate { $0.deletadoEm != nil && $0.syncStatusRaw == synced }
            )
            let ciclos = (try? context.fetch(cicloDesc)) ?? []
            for ciclo in ciclos where ciclo.deletadoEm ?? Date.distantFuture < limite {
                context.delete(ciclo)
            }

            let diaDesc = FetchDescriptor<DiaSoftex>(
                predicate: #Predicate { $0.deletadoEm != nil && $0.syncStatusRaw == synced }
            )
            let dias = (try? context.fetch(diaDesc)) ?? []
            for dia in dias where dia.deletadoEm ?? Date.distantFuture < limite {
                context.delete(dia)
            }

            let gastoDesc = FetchDescriptor<GastosDia>(
                predicate: #Predicate { $0.deletadoEm != nil && $0.syncStatusRaw == synced }
            )
            let gastos = (try? context.fetch(gastoDesc)) ?? []
            for gasto in gastos where gasto.deletadoEm ?? Date.distantFuture < limite {
                context.delete(gasto)
            }

            try context.save()
            logger.info("limparDadosMortos: cleanup concluido")
        } catch {
            logger.error("limparDadosMortos: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// - Parameter forcar: ignora o backoff pendente dos itens que falharam.
    ///   Use em ações explícitas do usuário (pull to refresh) e quando a
    ///   conexão volta — senão um item que falhou algumas vezes fica até 1h
    ///   sem ser reenviado, mesmo com internet disponível.
    func sync(forcar: Bool = false) async {
        guard let syncActor, !isSyncing else {
            if syncActor == nil { logger.error("SyncManager: syncActor ainda não configurado") }
            if isSyncing { logger.warning("SyncManager: sync já em andamento, ignorado") }
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            logger.warning("SyncManager: sem conexão, sync ignorado")
            return
        }
        let userId = AuthService.shared.currentUser?.id ?? ""
        guard !userId.isEmpty else {
            logger.error("SyncManager: userId vazio, sync ignorado")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        lastSyncError = nil
        let agora = Date()
        logger.info("SyncManager: iniciando sync para userId \(userId, privacy: .private), forcar=\(forcar, privacy: .public)")
        let restantes = await syncActor.sync(agora: agora, userId: userId, forcar: forcar)
        pendentesRestantes = restantes
        logger.info("SyncManager: sync finalizado, pendentes restantes=\(restantes, privacy: .public)")
    }

}

@ModelActor
actor SyncActor {

    private let logger = Logger(subsystem: "br.com.softspend", category: "SyncActor")

    private func salvarContexto(_ contexto: String) {
        do {
            try modelContext.save()
        } catch {
            logger.error("Falha ao salvar após \(contexto, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func sync(agora: Date, userId: String, forcar: Bool = false) async -> Int {
        let maxPassadas = 5

        var pendentesDepois = 0
        for passada in 0..<maxPassadas {
            let pendentesAntes = contarPendentes(agora: agora, userId: userId)
            logger.info("SyncActor: passada \(passada, privacy: .public), pendentesAntes=\(pendentesAntes, privacy: .public)")
            await syncCiclos(agora: agora, userId: userId, forcar: forcar)
            await syncDias(agora: agora, userId: userId, forcar: forcar)
            await syncGastos(agora: agora, userId: userId, forcar: forcar)
            await syncComprovantes(agora: agora, userId: userId, forcar: forcar)
            await syncDeletions(agora: agora, userId: userId, forcar: forcar)
            pendentesDepois = contarPendentes(agora: agora, userId: userId)
            logger.info("SyncActor: passada \(passada, privacy: .public), pendentesDepois=\(pendentesDepois, privacy: .public)")
            if pendentesDepois == 0 || pendentesDepois >= pendentesAntes { break }
        }
        return pendentesDepois
    }

    private func contarPendentes(agora: Date, userId: String) -> Int {
        let synced = SyncStatus.synced.rawValue
        let cicloDesc = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil && $0.userId == userId }
        )
        var diaDesc = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        diaDesc.relationshipKeyPathsForPrefetching = [\.ciclo]
        var gastoDesc = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        gastoDesc.relationshipKeyPathsForPrefetching = [\.dia]
        let ciclos = (try? modelContext.fetchCount(cicloDesc)) ?? 0
        let todosDias = (try? modelContext.fetch(diaDesc)) ?? []
        let todosGastos = (try? modelContext.fetch(gastoDesc)) ?? []
        let dias = todosDias.filter { $0.ciclo?.userId == userId }.count
        let gastos = todosGastos.filter { $0.dia?.ciclo?.userId == userId }.count
        return ciclos + dias + gastos
    }

    private func sincronizarEdicaoCiclo(_ ciclo: CicloSoftex, agora: Date, forcar: Bool = false) async {
        guard let backendId = ciclo.backendId, deveTentar(ciclo, agora: agora, forcar: forcar) else {
            logger.info("sincronizarEdicaoCiclo: pulado backendId=\(String(describing: ciclo.backendId), privacy: .public)")
            return
        }

        logger.info("sincronizarEdicaoCiclo: iniciando backendId=\(backendId, privacy: .public) titulo=\(ciclo.titulo, privacy: .private)")

        // Carrega os dias do ciclo explicitamente no contexto do SyncActor,
        // pois `ciclo.dias` pode nao estar faultado e retornar vazio.
        let cicloId = ciclo.id
        var diasDesc = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { _ in true },
            sortBy: [SortDescriptor(\.data)]
        )
        diasDesc.relationshipKeyPathsForPrefetching = [\.ciclo]
        let todosDias = ((try? modelContext.fetch(diasDesc)) ?? [])
        let locais = todosDias.filter {
            guard let diaCiclo = $0.ciclo else { return false }
            return diaCiclo.id == cicloId
        }
        let diasAtivos = locais.filter { $0.deletadoEm == nil }

        // Envia TODOS os dias nao deletados para o backend, nao apenas os pendentes,
        // para que o PUT /ciclos/{id}/dias/lote sincronize adicoes/remocoes de datas.
        let diasRequest: [DiaLoteRequest]? = diasAtivos.isEmpty ? nil : diasAtivos.map {
            DiaLoteRequest(clientId: $0.clientId, data: $0.data)
        }

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

            // 1. Sincroniza datas primeiro: cria novos dias e deleta os que
            // sairam do periodo (com seus gastos) em cascata no backend.
            var diasRemotos: [DiaSoftex]?
            if let diasRequest {
                diasRemotos = try await NetworkManager.shared.syncDiasLote(cicloId: backendId, dias: diasRequest)
                logger.info("sincronizarEdicaoCiclo: dias/lote ok backendId=\(backendId, privacy: .public)")
            }

            // 2. Depois atualiza o ciclo, para que gasto_total ja reflita as
            // remocoes de gastos feitas pelo lote.
            let cicloEditado = try await NetworkManager.shared.putCiclo(cicloId: backendId, request: updateRequest)
            logger.info("sincronizarEdicaoCiclo: PUT ok backendId=\(backendId, privacy: .public)")

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

            if let diasRemotos {
                let idsRemotos = Set(diasRemotos.compactMap { $0.backendId })
                let clientIdsRemotos = Set(diasRemotos.compactMap { $0.clientId })

                // Marca dias locais ativos que nao existem mais no backend
                // (por backendId ou clientId). Isso evita dias orfaos caso
                // o lote nao os tenha removido; syncDeletions se encarrega de
                // enviar DELETE /dias/{id} individual.
                for local in locais where local.deletadoEm == nil {
                    let aindaExiste = (local.backendId != nil && idsRemotos.contains(local.backendId!))
                        || (local.clientId != nil && clientIdsRemotos.contains(local.clientId))
                    if !aindaExiste {
                        local.deletadoEm = Date()
                        local.syncStatus = .pending
                    }
                }

                // Atualiza/insere dias remotos, casando por backendId ou clientId para evitar duplicatas
                for diaRemoto in diasRemotos {
                    if let local = locais.first(where: { $0.backendId == diaRemoto.backendId })
                        ?? locais.first(where: { $0.clientId == diaRemoto.clientId }) {
                        local.data = diaRemoto.data
                        local.saldo = diaRemoto.saldo
                        local.backendId = diaRemoto.backendId
                        local.clientId = diaRemoto.clientId ?? local.clientId
                        local.deletadoEm = nil
                        local.syncStatus = .synced
                    } else if let remotoId = diaRemoto.backendId {
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

    private func deveTentar(_ item: any Syncavel, agora: Date, forcar: Bool = false) -> Bool {
        if forcar { return true }
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

    private func syncCiclos(agora: Date, userId: String, forcar: Bool = false) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil && item.userId == userId },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let ciclos = todos.filter { deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncCiclos: \(ciclos.count, privacy: .public) ciclo(s) pendente(s) para userId \(userId, privacy: .private)")

        for ciclo in ciclos {
            if ciclo.backendId != nil {
                await sincronizarEdicaoCiclo(ciclo, agora: agora, forcar: forcar)
            } else {
                logger.info("syncCiclos: POST ciclo clientId=\(ciclo.clientId, privacy: .private) titulo=\(ciclo.titulo, privacy: .private)")
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
                    logger.info("syncCiclos: POST ok, backendId=\(response.backendId.map(String.init) ?? "nil", privacy: .public)")
                } catch {
                    ciclo.syncError = error.localizedDescription
                    marcarFalha(ciclo)
                    logger.error("syncCiclos: POST falhou: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        salvarContexto("syncCiclos")
    }

    private func syncDias(agora: Date, userId: String, forcar: Bool = false) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let dias = todos.filter { $0.ciclo?.userId == userId && deveTentar($0, agora: agora, forcar: forcar) }

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

    private func syncGastos(agora: Date, userId: String, forcar: Bool = false) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let gastos = todos.filter { $0.dia?.ciclo?.userId == userId && deveTentar($0, agora: agora, forcar: forcar) }

        for gasto in gastos {
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

    private func syncComprovantes(agora: Date, userId: String, forcar: Bool = false) async {
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in
                item.syncStatusRaw != synced &&
                (item.comprovanteDataCriptografado != nil || item.comprovanteParaRemover) &&
                item.deletadoEm == nil
            },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let gastos = todos.filter { $0.dia?.ciclo?.userId == userId && $0.backendId != nil && deveTentar($0, agora: agora, forcar: forcar) }

        for gasto in gastos {
            guard let backendId = gasto.backendId else { continue }
            do {
                try await sincronizarComprovante(gasto, backendId: backendId)
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

    private func syncDeletions(agora: Date, userId: String, forcar: Bool = false) async {
        let synced = SyncStatus.synced.rawValue

        let gastoDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )

        let todosGastos = ((try? modelContext.fetch(gastoDescriptor)) ?? [])
        let gastos = todosGastos
            .filter { $0.dia?.ciclo?.userId == userId && deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncDeletions: \(gastos.count, privacy: .public) gasto(s) para deletar")

        for gasto in gastos {
            guard let backendId = gasto.backendId else {
                marcarSucesso(gasto)
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
            marcarSucesso(gasto)
        }

        let diaDescriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosDias = ((try? modelContext.fetch(diaDescriptor)) ?? [])
        let dias = todosDias
            .filter { $0.ciclo?.userId == userId && deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncDeletions: \(dias.count, privacy: .public) dia(s) para deletar")

        for dia in dias {

            guard let backendId = dia.backendId else {
                marcarSucesso(dia)
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
            marcarSucesso(dia)
        }

        let cicloDescriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil && item.userId == userId },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let ciclos = ((try? modelContext.fetch(cicloDescriptor)) ?? [])
            .filter { deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncDeletions: \(ciclos.count, privacy: .public) ciclo(s) para deletar")

        for ciclo in ciclos {
            guard let backendId = ciclo.backendId else {
                marcarSucesso(ciclo)
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
            marcarSucesso(ciclo)
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
