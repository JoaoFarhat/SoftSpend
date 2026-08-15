//
//  SyncManager.swift
//  SoftexVamo
//

import Foundation
import SwiftData
import Combine

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    var modelContext: ModelContext?
    @Published var isSyncing = false
    
    func sync() async {
        guard let context = modelContext, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        
        let agora = Date()
        
        do {
            try await syncCiclos(context, agora: agora)
            try await syncDias(context, agora: agora)
            try await syncGastos(context, agora: agora)
            try await syncDeletions(context, agora: agora)
        } catch {
            print("Sync error: \(error.localizedDescription)")
        }
    }
    
    func editarCiclo(_ ciclo: CicloSoftex, dias: [DiaLoteRequest]?) async throws {
        guard !isSyncing else {
            throw SyncError.sincronizacaoEmProgresso
        }
        guard let backendId = ciclo.backendId else {
            throw SyncError.cicloNaoSincronizado
        }
        guard let context = modelContext else {
            throw SyncError.modelContextNaoConfigurado
        }
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            let updateRequest = CicloUpdateRequest(
                titulo: ciclo.titulo,
                valor_total: ciclo.valor_total,
                diaria: ciclo.diaria,
                periodo: ciclo.periodo
            )
            var cicloEditado = try await NetworkManager.shared.putCiclo(cicloId: backendId, request: updateRequest)
            
            if let dias {
                cicloEditado.dias = try await NetworkManager.shared.syncDiasLote(cicloId: backendId, dias: dias)
            }
            
            ciclo.titulo = cicloEditado.titulo
            ciclo.valor_total = cicloEditado.valor_total
            ciclo.gasto_total = cicloEditado.gasto_total
            ciclo.periodo = cicloEditado.periodo
            ciclo.diaria = cicloEditado.diaria
            ciclo.syncStatus = .synced
            ciclo.syncError = nil
            
            if let diasRemotos = cicloEditado.dias {
                let descriptor = FetchDescriptor<DiaSoftex>(
                    predicate: #Predicate { $0.ciclo?.backendId == backendId }
                )
                let locais = (try? context.fetch(descriptor)) ?? []
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
                    } else {
                        diaRemoto.ciclo = ciclo
                        diaRemoto.syncStatus = .synced
                        context.insert(diaRemoto)
                        ciclo.dias?.append(diaRemoto)
                    }
                }
            }
            
            try context.save()
        } catch {
            ciclo.syncStatus = .failed
            ciclo.syncError = error.localizedDescription
            try? context.save()
            throw error
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
    
    private func syncCiclos(_ context: ModelContext, agora: Date) async throws {
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != "synced" && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        let ciclos = todos.filter { deveTentar($0, agora: agora) }
        
        for ciclo in ciclos {
            do {
                if let backendId = ciclo.backendId {
                    let updateRequest = CicloUpdateRequest(
                        titulo: ciclo.titulo,
                        valor_total: ciclo.valor_total,
                        diaria: ciclo.diaria,
                        periodo: ciclo.periodo
                    )
                    let response = try await NetworkManager.shared.putCiclo(cicloId: backendId, request: updateRequest)
                    ciclo.gasto_total = response.gasto_total
                    marcarSucesso(ciclo)
                } else {
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
                }
            } catch {
                ciclo.syncError = error.localizedDescription
                marcarFalha(ciclo)
            }
        }
        
        try? context.save()
    }
    
    private func syncDias(_ context: ModelContext, agora: Date) async throws {
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != "synced" && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        let dias = todos.filter { deveTentar($0, agora: agora) }
        
        for dia in dias {
            guard let cicloId = dia.ciclo?.backendId else {
                dia.syncError = "Ciclo ainda não syncado"
                dia.syncStatus = .failed
                continue
            }
            
            let request = DiaLoteRequest(clientId: dia.clientId, data: dia.data)
            do {
                let response = try await NetworkManager.shared.postDiasLote(cicloId: cicloId, dias: [request])
                if let primeiro = response.first {
                    dia.backendId = primeiro.backendId
                    for gasto in dia.gastos where gasto.diaId == nil {
                        gasto.diaId = primeiro.backendId
                    }
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
        
        try? context.save()
    }
    
    private func syncGastos(_ context: ModelContext, agora: Date) async throws {
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != "synced" && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        let gastos = todos.filter { deveTentar($0, agora: agora) }
        
        for gasto in gastos {
            guard let diaId = gasto.diaId else {
                gasto.syncError = "Dia ainda não sincronizado"
                marcarFalha(gasto)
                continue
            }
            
            do {
                if let backendId = gasto.backendId {
                    let updateRequest = GastoUpdateRequest(
                        titulo: gasto.titulo,
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: gasto.diaId
                    )
                    let response = try await NetworkManager.shared.putGasto(gastoId: backendId, request: updateRequest)
                    try await sincronizarComprovante(gasto, backendId: backendId)
                    if gasto.comprovanteData == nil && !gasto.comprovanteParaRemover {
                        gasto.comprovanteUrl = response.comprovanteUrl
                    }
                    marcarSucesso(gasto)
                } else {
                    let createRequest = GastoCreateRequest(
                        client_id: gasto.clientId,
                        titulo: gasto.titulo,
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: diaId
                    )
                    let response = try await NetworkManager.shared.postGasto(request: createRequest)
                    guard let novoGastoId = response.backendId else {
                        throw URLError(.cannotParseResponse)
                    }
                    gasto.backendId = novoGastoId
                    try await sincronizarComprovante(gasto, backendId: novoGastoId)
                    if gasto.comprovanteData == nil && !gasto.comprovanteParaRemover {
                        gasto.comprovanteUrl = response.comprovanteUrl
                    }
                    marcarSucesso(gasto)
                }
            } catch {
                gasto.syncError = error.localizedDescription
                marcarFalha(gasto)
            }
        }
        
        try? context.save()
    }
    
    private func sincronizarComprovante(_ gasto: GastosDia, backendId: Int) async throws {
        guard gasto.comprovanteData != nil || gasto.comprovanteParaRemover else { return }
        
        if gasto.comprovanteData != nil && gasto.comprovanteParaRemover {
            print("Estado inconsistente: comprovanteData e comprovanteParaRemover ativos. Remoção ignorada.")
            gasto.comprovanteParaRemover = false
        }
        
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
        guard let apiError = error as? APIError else { return false }
        if case .serverError(_, _, let statusCode) = apiError {
            return statusCode == 404
        }
        return false
    }
    
    private func syncDeletions(_ context: ModelContext, agora: Date) async throws {
        let gastoDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != "synced" && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosGastos = (try? context.fetch(gastoDescriptor)) ?? []
        let gastos = todosGastos.filter { deveTentar($0, agora: agora) }
        
        for gasto in gastos {
            guard let backendId = gasto.backendId else {
                context.delete(gasto)
                continue
            }
            
            do {
                try await NetworkManager.shared.deleteGasto(gastoId: backendId)
                context.delete(gasto)
            } catch {
                marcarFalha(gasto)
                gasto.syncError = error.localizedDescription
            }
        }
        
        let diaDescriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != "synced" && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosDias = (try? context.fetch(diaDescriptor)) ?? []
        let dias = todosDias.filter { deveTentar($0, agora: agora) }
        
        for dia in dias {
            if let backendId = dia.backendId {
                do {
                    for gasto in dia.gastos where gasto.backendId != nil && gasto.deletadoEm == nil {
                        try await NetworkManager.shared.deleteGasto(gastoId: gasto.backendId!)
                    }
                    try await NetworkManager.shared.deleteDia(diaId: backendId)
                    context.delete(dia)
                } catch {
                    marcarFalha(dia)
                    dia.syncError = error.localizedDescription
                }
            } else {
                for gasto in dia.gastos {
                    context.delete(gasto)
                }
                context.delete(dia)
            }
        }
        
        let cicloDescriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != "synced" && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosCiclos = (try? context.fetch(cicloDescriptor)) ?? []
        let ciclos = todosCiclos.filter { deveTentar($0, agora: agora) }
        
        for ciclo in ciclos {
            guard let backendId = ciclo.backendId else {
                context.delete(ciclo)
                continue
            }
            
            do {
                try await NetworkManager.shared.deleteCiclo(cicloId: backendId)
                context.delete(ciclo)
            } catch {
                marcarFalha(ciclo)
                ciclo.syncError = error.localizedDescription
            }
        }
        
        try? context.save()
    }
}

protocol Syncavel: AnyObject {
    var tentativas: Int { get set }
    var proximaTentativaEm: Date? { get set }
    var syncStatus: SyncStatus { get set }
    var syncError: String? { get set }
}

extension CicloSoftex: Syncavel {}
extension DiaSoftex: Syncavel {}
extension GastosDia: Syncavel {}

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
