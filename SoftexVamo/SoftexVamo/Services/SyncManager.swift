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
        
        let agora = Date()
        
        do {
            try await syncCiclos(context, agora: agora)
            try await syncDias(context, agora: agora)
            try await syncGastos(context, agora: agora)
            try await syncDeletions(context)
        } catch {
            print("Sync error: \(error.localizedDescription)")
        }
        
        isSyncing = false
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
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        let ciclos = todos.filter { $0.syncStatus == .pending && $0.deletadoEm == nil && deveTentar($0, agora: agora) }
        
        for ciclo in ciclos {
            do {
                let request = CicloCreateRequest(
                    client_id: ciclo.clientId,
                    titulo: ciclo.titulo,
                    valor_total: ciclo.valor_total,
                    diaria: ciclo.diaria,
                    periodo: ciclo.periodo
                )
                let response = try await NetworkManager.shared.postCiclo(request: request)
                
                ciclo.backendId = response.backendId
                ciclo.gasto_total = response.gasto_total
                marcarSucesso(ciclo)
            } catch {
                ciclo.syncError = error.localizedDescription
                marcarFalha(ciclo)
            }
        }
        
        try? context.save()
    }
    
    private func syncDias(_ context: ModelContext, agora: Date) async throws {
        let descriptor = FetchDescriptor<DiaSoftex>(
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        let dias = todos.filter { $0.syncStatus == .pending && $0.deletadoEm == nil && deveTentar($0, agora: agora) }
        
        for dia in dias {
            guard let cicloId = dia.ciclo?.backendId else {
                dia.syncError = "Ciclo ainda não syncado"
                dia.syncStatus = SyncStatus.failed
                continue
            }
            
            let request = DiaLoteRequest(clientId: dia.clientId, data: dia.data)
            do {
                let response = try await NetworkManager.shared.postDiasLote(cicloId: cicloId, dias: [request])
                if let primeiro = response.first {
                    dia.backendId = primeiro.backendId
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
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        let gastos = todos.filter { $0.syncStatus == .pending && $0.deletadoEm == nil && deveTentar($0, agora: agora) }
        
        for gasto in gastos {
            guard let diaId = gasto.diaId else {
                gasto.syncError = "Dia não tem backendId"
                gasto.syncStatus = SyncStatus.failed
                continue
            }
            
            let request = GastoCreateRequest(
                client_id: gasto.clientId,
                titulo: gasto.titulo,
                valor: gasto.valor,
                categoria: gasto.categoria,
                dia_id: diaId
            )
            
            do {
                let response = try await NetworkManager.shared.postGasto(request: request)
                gasto.backendId = response.backendId
                gasto.comprovanteUrl = response.comprovanteUrl
                marcarSucesso(gasto)
            } catch {
                gasto.syncError = error.localizedDescription
                marcarFalha(gasto)
            }
        }
        
        try? context.save()
    }
    
    private func syncDeletions(_ context: ModelContext) async throws {
        let cicloDescriptor = FetchDescriptor<CicloSoftex>(
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosCiclos = (try? context.fetch(cicloDescriptor)) ?? []
        let ciclos = todosCiclos.filter { $0.deletadoEm != nil }
        
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
        
        let gastoDescriptor = FetchDescriptor<GastosDia>(
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosGastos = (try? context.fetch(gastoDescriptor)) ?? []
        let gastos = todosGastos.filter { $0.deletadoEm != nil }
        
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
