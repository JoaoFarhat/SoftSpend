//
//  CicloViewModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 27/07/26.
//

import Foundation
import Combine
import SwiftUI
import SwiftData

@MainActor
final class CiclosViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex.vazio
    @Published var gastosInfo: GastosDia = GastosDia.example
    @Published var availableInfo: GastosDia = GastosDia.example
    @Published var isLoading: Bool = true
    @Published var selectedTab: Int = 0
    @Published var hasMorePages: Bool = true
    
    var modelContext: ModelContext?
    var errorManager: ErrorManager?
    
    private var hasLoadedOnce = false
    var index: Int = 0
    private var skip = 0
    private let limit = 5
    
    private var diasSkip = 0
    private let diasLimit = 20
    private var hasMoreDias = true
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    private func showError(_ error: Error) {
        errorManager?.show(error: error)
    }
    
    func reset() {
        self.allCiclos = []
        self.atualCiclo = CicloSoftex.vazio
        self.index = 0
        self.isLoading = true
        self.hasLoadedOnce = false
        self.hasMorePages = true
        self.skip = 0
        self.diasSkip = 0
        self.hasMoreDias = true
    }

    func fetchCiclosResumo() async {
        await loadCiclos(append: false)
    }
    
    func loadMoreCiclos() async {
        guard hasMorePages, !isLoading else { return }
        skip += limit
        await loadCiclos(append: true)
    }
    
    private func loadCiclos(append: Bool) async {
        
        guard currentUser != nil else {
            showError(APIError.serverError(message: "Usuario nao esta logado", requestId: "-", statusCode: 401))
            self.isLoading = false
            return
        }
        
        if append, !hasMorePages { return }
        if !append, hasLoadedOnce { return }
        
        isLoading = true
        
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm, order: .reverse)]
        )
        
        
        let ciclosLocais: [CicloSoftex]
        if let context = modelContext {
            ciclosLocais = (try? context.fetch(descriptor)) ?? []
        } else {
            ciclosLocais = []
        }
        
        if !ciclosLocais.isEmpty {
            if !append {
                self.allCiclos = ciclosLocais
                self.atualCiclo = ciclosLocais[0]
                self.index = 0
            } else {
                self.allCiclos.append(contentsOf: ciclosLocais)
            }
            self.isLoading = false
        }
        
        do {
            let ciclos = try await NetworkManager.shared.fetchCicloResumo(skip: skip, limit: limit)
            
            hasMorePages = ciclos.count == limit
            
            for ciclo in ciclos {
                salvarOuAtualizarCicloLocal(ciclo)
            }
            
            try modelContext?.save()
            
            let ciclosAtualizados: [CicloSoftex]
            if let context = modelContext {
                ciclosAtualizados = (try? context.fetch(descriptor)) ?? []
            } else {
                ciclosAtualizados = []
            }
            
            if !append {
                self.allCiclos = ciclosAtualizados
                self.index = 0
                
                if let primeiro = self.allCiclos.first {
                    self.atualCiclo = primeiro
                } else {
                    self.atualCiclo = CicloSoftex.vazio
                }
            } else {
                self.allCiclos = ciclosAtualizados
            }
            
            if !append, !self.allCiclos.isEmpty {
                let cicloParaSalvar = self.allCiclos[self.index]
                
                guard let cicloId = cicloParaSalvar.backendId else {
                    isLoading = false
                    return
                }
                
                self.atualCiclo = try await NetworkManager.shared.fetchCicloById(cicloId: cicloId)
                self.atualCiclo.dias = []
                self.diasSkip = 0
                self.hasMoreDias = true
                await loadMoreDias(cicloId: cicloId)
                self.salvarCicloLocal(self.atualCiclo)
            } else if !append {
                self.atualCiclo = CicloSoftex.vazio
            }
            
            isLoading = false
            hasLoadedOnce = true
            
        } catch {
            showError(error)
            
            if !append, self.allCiclos.isEmpty {
                self.allCiclos = []
                self.atualCiclo = CicloSoftex.vazio
            }
            
            isLoading = false
            hasLoadedOnce = true
        }
    }
    
    func loadMoreDias(cicloId: Int) async {
        guard hasMoreDias else { return }
        
        do {
            let dias = try await NetworkManager.shared.fetchDias(cicloId: cicloId, skip: diasSkip, limit: diasLimit)
            hasMoreDias = dias.count == diasLimit
            diasSkip += dias.count
            
            if atualCiclo.dias == nil {
                atualCiclo.dias = []
            }
            
            for dia in dias {
                salvarOuAtualizarDiaLocal(dia, no: atualCiclo)
            }
            
            try modelContext?.save()
            
            let descriptor = FetchDescriptor<DiaSoftex>(
                predicate: #Predicate { $0.ciclo?.backendId == cicloId && $0.deletadoEm == nil },
                sortBy: [SortDescriptor(\.data)]
            )
            let diasAtualizados: [DiaSoftex]
            if let context = modelContext {
                diasAtualizados = (try? context.fetch(descriptor)) ?? []
            } else {
                diasAtualizados = []
            }
            
            self.atualCiclo.dias = diasAtualizados
            
        } catch {
            showError(error)
        }
    }
    
    private func salvarOuAtualizarDiaLocal(_ dia: DiaSoftex, no ciclo: CicloSoftex) {
        if let backendId = dia.backendId {
            let descriptor = FetchDescriptor<DiaSoftex>(
                predicate: #Predicate { $0.backendId == backendId }
            )
            if let existente = try? modelContext?.fetch(descriptor).first {
                existente.data = dia.data
                existente.saldo = dia.saldo
                for gasto in dia.gastos {
                    salvarOuAtualizarGastoLocal(gasto, no: existente)
                }
                existente.syncStatus = .synced
                return
            }
        }
        dia.syncStatus = .synced
        for gasto in dia.gastos {
            salvarOuAtualizarGastoLocal(gasto, no: dia)
        }
        modelContext?.insert(dia)
        ciclo.dias?.append(dia)
    }
    
    private func salvarOuAtualizarGastoLocal(_ gasto: GastosDia, no dia: DiaSoftex) {
        if let backendId = gasto.backendId {
            let descriptor = FetchDescriptor<GastosDia>(
                predicate: #Predicate { $0.backendId == backendId }
            )
            if let existente = try? modelContext?.fetch(descriptor).first {
                existente.titulo = gasto.titulo
                existente.valor = gasto.valor
                existente.categoria = gasto.categoria
                existente.comprovanteUrl = gasto.comprovanteUrl
                existente.diaId = gasto.diaId
                existente.syncStatus = .synced
                return
            }
        }
        gasto.syncStatus = .synced
        modelContext?.insert(gasto)
        dia.gastos.append(gasto)
    }
    
    private func salvarOuAtualizarCicloLocal(_ ciclo: CicloSoftex) {
        if let backendId = ciclo.backendId {
            let descriptor = FetchDescriptor<CicloSoftex>(
                predicate: #Predicate { $0.backendId == backendId }
            )
            if let existente = try? modelContext?.fetch(descriptor).first {
                existente.titulo = ciclo.titulo
                existente.valor_total = ciclo.valor_total
                existente.gasto_total = ciclo.gasto_total
                existente.periodo = ciclo.periodo
                existente.diaria = ciclo.diaria
                existente.syncStatus = .synced
                return
            }
        }
        ciclo.syncStatus = .synced
        modelContext?.insert(ciclo)
    }
    
    func createNewCiclo(startDate: Date, endDate: Date, totalValue: Float, titulo: String) async throws {
        let dayCount = Calendar.current.datesBetween(startDate, and: endDate)
        let safeDayCount = max(dayCount, 1)
        
        let saldo = totalValue / Float(safeDayCount)
        let periodo = createPeriodoString(from: startDate, to: endDate)
        
        let newCiclo = CicloSoftex(valor_total: totalValue, gasto_total: 0, periodo: periodo, diaria: saldo, titulo: titulo, dias: nil)
        let dias: [DiaLoteRequest] = createAllDiasLoteRequest(dayCount: dayCount, startDate: startDate)
        
        try await postToNetwork(newCiclo: newCiclo, dias: dias)
    }
    
    func editCiclo(cicloId: Int, ciclo: CicloSoftex, dias: [DiaLoteRequest]? = nil) async throws {
        guard let cicloLocal = self.allCiclos.first(where: { $0.backendId == cicloId }) else { return }
        
        // Atualiza localmente primeiro
        cicloLocal.titulo = ciclo.titulo
        cicloLocal.valor_total = ciclo.valor_total
        cicloLocal.diaria = ciclo.diaria
        cicloLocal.periodo = ciclo.periodo
        cicloLocal.syncStatus = .pending
        cicloLocal.syncError = nil
        
        if let index = self.allCiclos.firstIndex(where: { $0.backendId == cicloId }) {
            self.allCiclos[index] = cicloLocal
        }
        
        if self.atualCiclo.backendId == cicloId {
            self.atualCiclo = cicloLocal
        }
        
        try? modelContext?.save()
        
        SyncManager.shared.modelContext = modelContext
        
        // Se o ciclo ainda não tem backendId, deixa o sync() normal cuidar da criação primeiro
        if cicloLocal.backendId != nil {
            try await SyncManager.shared.editarCiclo(cicloLocal, dias: dias)
        } else {
            await SyncManager.shared.sync()
            let status = cicloLocal.syncStatus
            if status == .failed {
                throw APIError.serverError(
                    message: cicloLocal.syncError ?? "Falha ao sincronizar o ciclo editado",
                    requestId: "-",
                    statusCode: 0
                )
            }
        }
    }
    
    func deleteCiclo(cicloId: Int) async throws {
        guard let ciclo = self.allCiclos.first(where: { $0.backendId == cicloId }) else { return }
        
        // Remove da UI imediatamente
        if let index = self.allCiclos.firstIndex(where: { $0.backendId == cicloId }){
            self.allCiclos.remove(at: index)
        }
        
        if self.atualCiclo.backendId == cicloId {
            if let primeiroCiclo = self.allCiclos.first {
                self.atualCiclo = primeiroCiclo
                self.index = 0
            } else {
                self.atualCiclo = CicloSoftex.vazio
                self.index = 0
            }
        }
        
        // Soft delete local
        ciclo.deletadoEm = Date()
        ciclo.syncStatus = .pending
        try? modelContext?.save()
        
        Task {
            await SyncManager.shared.sync()
        }
    }
    
    private func salvarCicloLocal(_ ciclo: CicloSoftex) {
        salvarOuAtualizarCicloLocal(ciclo)
        try? modelContext?.save()
    }
    
    func createAllDiasLoteRequest(dayCount: Int, startDate: Date) -> [DiaLoteRequest] {
        var dias: [DiaLoteRequest] = []
        let calendar = Calendar.current
        
        for i in 0..<dayCount {
            if let date = calendar.date(byAdding: .day, value: i, to: startDate) {
                dias.append(DiaLoteRequest(clientId: UUID().uuidString, data: date))
            }
        }
        return dias
    }
    
    private func createPeriodoString(from: Date, to: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM"
        return "\(dateFormatter.string(from: from)) - \(dateFormatter.string(from: to))"
    }
    
    private func salvarNovoCicloLocal(_ ciclo: CicloSoftex, comDias diasRequests: [DiaLoteRequest]) {
        let dias: [DiaSoftex] = diasRequests.compactMap { req in
            let dia = DiaSoftex(clientId: req.clientId ?? UUID().uuidString, data: req.data, saldo: ciclo.diaria)
            dia.syncStatus = .pending
            modelContext?.insert(dia)
            return dia
        }
        ciclo.dias = dias
        ciclo.syncStatus = .pending
        modelContext?.insert(ciclo)
        try? modelContext?.save()
    }
    
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async throws {
        salvarNovoCicloLocal(newCiclo, comDias: dias)
        
        self.allCiclos.insert(newCiclo, at: 0)
        self.atualCiclo = newCiclo
        self.index = 0
        
        SyncManager.shared.modelContext = modelContext
        Task {
            await SyncManager.shared.sync()
        }
    }
    
    func createNewGasto(title: String, value: Float, dia: DiaSoftex, categoria: Categoria, comprovante: Data? = nil) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let diaBackendId = dia.backendId else {
            throw APIError.serverError(message: "O dia selecionado ainda não foi sincronizado", requestId: "-", statusCode: 400)
        }
        
        let novoGasto = GastosDia(
            valor: value,
            titulo: title,
            categoria: categoria,
            diaId: diaBackendId,
            backendId: nil,
            comprovanteUrl: nil,
            comprovanteData: comprovante
        )
        
        modelContext.insert(novoGasto)
        
        guard let diaIndex = self.atualCiclo.dias?.firstIndex(where: { $0.id == dia.id }) else {
            throw APIError.serverError(message: "Dia selecionado não encontrado no ciclo atual", requestId: "-", statusCode: 404)
        }
        
        self.atualCiclo.dias?[diaIndex].gastos.append(novoGasto)
        self.atualCiclo.gasto_total += novoGasto.valor
        self.allCiclos[index] = self.atualCiclo
        
        try modelContext.save()
        
        SyncManager.shared.modelContext = modelContext
        Task {
            await SyncManager.shared.sync()
        }
    }

    func anexarComprovante(gastoId: Int, imageData: Data) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let gasto = encontrarGasto(backendId: gastoId) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        gasto.comprovanteData = imageData
        gasto.comprovanteParaRemover = false
        gasto.syncStatus = .pending
        try modelContext.save()
        
        await SyncManager.shared.sync()
    }
    
    func removerComprovante(gastoId: Int) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let gasto = encontrarGasto(backendId: gastoId) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        gasto.comprovanteData = nil
        gasto.comprovanteParaRemover = true
        gasto.syncStatus = .pending
        try modelContext.save()
        
        await SyncManager.shared.sync()
    }
    
    private func encontrarGasto(backendId: Int) -> GastosDia? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.backendId == backendId }
        )
        return (try? context.fetch(descriptor).first)
    }
    
    func deleteGasto(gastoID: Int) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let dias = atualCiclo.dias else {
            throw APIError.serverError(message: "Ciclo atual não possui dias", requestId: "-", statusCode: 404)
        }
        
        var gastoParaDeletar: GastosDia?
        
        for diaIndex in dias.indices {
            if let gastoIndex = dias[diaIndex].gastos.firstIndex(where: { $0.backendId == gastoID }) {
                let gasto = dias[diaIndex].gastos[gastoIndex]
                gastoParaDeletar = gasto
                
                self.atualCiclo.dias?[diaIndex].gastos.remove(at: gastoIndex)
                self.atualCiclo.gasto_total -= gasto.valor
                
                if self.index < self.allCiclos.count {
                    self.allCiclos[self.index] = self.atualCiclo
                }
                break
            }
        }
        
        guard let gasto = gastoParaDeletar else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        
        gasto.deletadoEm = Date()
        gasto.syncStatus = .pending
        try modelContext.save()
        
        Task {
            await SyncManager.shared.sync()
        }
    }
    
    func editGasto(gastoId: Int, novoDia: DiaSoftex, titulo: String, value: Float, categoria: Categoria) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let diaBackendId = novoDia.backendId else {
            throw APIError.serverError(message: "Dia de destino não sincronizado", requestId: "-", statusCode: 400)
        }
        guard let dias = self.atualCiclo.dias else {
            throw APIError.serverError(message: "Ciclo atual não possui dias", requestId: "-", statusCode: 404)
        }
        guard let oldDiaIndex = dias.firstIndex(where: { $0.gastos.contains(where: { $0.backendId == gastoId }) }) else {
            throw APIError.serverError(message: "Dia do gasto não encontrado", requestId: "-", statusCode: 404)
        }
        guard let oldGastoIndex = dias[oldDiaIndex].gastos.firstIndex(where: { $0.backendId == gastoId }) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        guard let newDiaIndex = dias.firstIndex(where: { $0.backendId == diaBackendId }) else {
            throw APIError.serverError(message: "Dia de destino não encontrado", requestId: "-", statusCode: 404)
        }
        guard let gastoLocal = self.atualCiclo.dias?[oldDiaIndex].gastos[oldGastoIndex] else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        
        let gastoAntigoValor = gastoLocal.valor
        let diferenca = value - gastoAntigoValor
        
        gastoLocal.titulo = titulo
        gastoLocal.valor = value
        gastoLocal.categoria = categoria
        gastoLocal.syncStatus = .pending
        gastoLocal.syncError = nil
        
        self.atualCiclo.gasto_total += diferenca
        
        if oldDiaIndex == newDiaIndex {
            self.atualCiclo.dias?[oldDiaIndex].saldo -= diferenca
        } else {
            self.atualCiclo.dias?[oldDiaIndex].saldo += gastoAntigoValor
            self.atualCiclo.dias?[oldDiaIndex].gastos.remove(at: oldGastoIndex)
            
            self.atualCiclo.dias?[newDiaIndex].saldo -= value
            self.atualCiclo.dias?[newDiaIndex].gastos.append(gastoLocal)
            gastoLocal.diaId = diaBackendId
        }
        
        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }
        
        try modelContext.save()
        
        Task {
            await SyncManager.shared.sync()
        }
    }
}
