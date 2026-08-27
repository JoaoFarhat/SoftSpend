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
import os

@MainActor
final class CiclosViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex.vazio
    @Published var gastosInfo: GastosDia = GastosDia.example
    @Published var availableInfo: GastosDia = GastosDia.example
    @Published var isLoading: Bool = true
    @Published var selectedTab: Int = 0
    @Published var hasMorePages: Bool = true
    @Published var isOffline: Bool = false
    
    var modelContext: ModelContext?
    weak var errorManager: ErrorManager?
    
    private var hasLoadedOnce = false
    var index: Int = 0
    private var skip = 0
    private let limit = 5
    
    private var diasSkip = 0
    private let diasLimit = 20
    private var hasMoreDias = true
    var isLoadingDias = false
    
    private var loadCiclosTask: Task<Void, Never>?
    private var loadMoreDiasTask: Task<Void, Never>?
    private var networkObservationTask: Task<Void, Never>?
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    private let viewModelLogger = Logger(subsystem: "br.com.softspend", category: "CiclosViewModel")

    init() {
        observeNetwork()
    }

    deinit {
        networkObservationTask?.cancel()
        loadCiclosTask?.cancel()
        loadMoreDiasTask?.cancel()
    }

    private func observeNetwork() {
        networkObservationTask = Task {
            for await connected in NetworkMonitor.shared.$isConnected.values {
                self.isOffline = !connected
            }
        }
    }

    private func showError(_ error: Error) {
        viewModelLogger.error("CiclosViewModel error: \(error.localizedDescription, privacy: .public)")
        errorManager?.show(error: error)
    }

    private func salvarLocal() {
        do {
            try modelContext?.save()
        } catch {
            showError(APIError.serverError(
                message: "Erro ao salvar dados localmente: \(error.localizedDescription)",
                requestId: "-",
                statusCode: 500
            ))
        }
    }
    
    func reset() {
        loadCiclosTask?.cancel()
        loadMoreDiasTask?.cancel()
        loadCiclosTask = nil
        loadMoreDiasTask = nil
        
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

    func limparDadosLocais() {
        guard let modelContext else { return }
        try? modelContext.delete(model: GastosDia.self)
        try? modelContext.delete(model: DiaSoftex.self)
        try? modelContext.delete(model: CicloSoftex.self)
        try? modelContext.delete(model: UserModel.self)
        try? modelContext.save()
    }

    func fetchCiclosResumo() {
        loadCiclos(append: false)
    }
    
    func loadMoreCiclos() {
        guard hasMorePages, !isLoading else { return }
        skip += limit
        loadCiclos(append: true)
    }
    
    private func loadCiclos(append: Bool) {
        guard currentUser != nil else {
            showError(APIError.serverError(message: "Usuario nao esta logado", requestId: "-", statusCode: 401))
            self.isLoading = false
            return
        }
        
        if append, !hasMorePages { return }
        if !append, hasLoadedOnce { return }
        
        loadCiclosTask?.cancel()
        loadMoreDiasTask?.cancel()
        loadCiclosTask = nil
        loadMoreDiasTask = nil
        
        loadCiclosTask = Task {
            isLoading = true
            
            if !append {
                deduplicarCiclosLocais()
            }
            
            let userId = currentUser?.id ?? ""
            let descriptor = FetchDescriptor<CicloSoftex>(
                predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId },
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
                    let idsExistentes = Set(self.allCiclos.map { $0.id })
                    let novos = ciclosLocais.filter { !idsExistentes.contains($0.id) }
                    self.allCiclos.append(contentsOf: novos)
                }
                self.isLoading = false
            }

            guard NetworkMonitor.shared.isConnected else {
                if !append, !ciclosLocais.isEmpty {
                    self.diasSkip = 0
                    self.hasMoreDias = false
                    carregarDiasLocais()
                }
                isLoading = false
                hasLoadedOnce = true
                return
            }

            do {
                let ciclos = try await NetworkManager.shared.fetchCicloResumo(skip: skip, limit: limit)
                
                guard !Task.isCancelled else { return }
                
                hasMorePages = ciclos.count == limit
                
                for ciclo in ciclos {
                    salvarOuAtualizarCicloLocal(ciclo)
                }

                salvarLocal()
                
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
                
                if !append, self.allCiclos.indices.contains(self.index) {
                    let cicloParaSalvar = self.allCiclos[self.index]
                    
                    guard let cicloId = cicloParaSalvar.backendId else {
                        isLoading = false
                        hasLoadedOnce = true
                        return
                    }
                    
                    self.atualCiclo = cicloParaSalvar
                    self.atualCiclo.dias = []
                    self.diasSkip = 0
                    self.hasMoreDias = true
                    loadMoreDiasTask?.cancel()
                    loadMoreDiasTask = nil
                    loadMoreDiasTask = Task {
                        await loadMoreDias(cicloId: cicloId)
                    }
                } else if !append {
                    self.atualCiclo = CicloSoftex.vazio
                }
                
                isLoading = false
                hasLoadedOnce = true
                
            } catch {
                guard !Task.isCancelled else { return }
                showError(error)
                
                if !append, self.allCiclos.isEmpty {
                    self.allCiclos = []
                    self.atualCiclo = CicloSoftex.vazio
                }
                
                isLoading = false
                hasLoadedOnce = true
            }
        }
    }
    
    private func deduplicarCiclosLocais() {
        guard let context = modelContext else { return }
        let userId = currentUser?.id ?? ""
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId },
            sortBy: [SortDescriptor(\.criadoEm, order: .forward)]
        )
        let todos: [CicloSoftex]
        do {
            todos = try context.fetch(descriptor)
        } catch {
            showError(APIError.serverError(
                message: "Deduplicação: falha ao buscar ciclos: \(error.localizedDescription)",
                requestId: "-",
                statusCode: 500
            ))
            return
        }

        var originalPorBackendId: [Int: CicloSoftex] = [:]
        var originalPorClientId: [String: CicloSoftex] = [:]
        var duplicatas: [CicloSoftex] = []
        for ciclo in todos {
            var isDuplicata = false
            if let bid = ciclo.backendId {
                if originalPorBackendId[bid] != nil {
                    isDuplicata = true
                } else {
                    originalPorBackendId[bid] = ciclo
                }
            } else {
                let cid = ciclo.clientId
                if originalPorClientId[cid] != nil {
                    isDuplicata = true
                } else {
                    originalPorClientId[cid] = ciclo
                }
            }
            if isDuplicata {
                duplicatas.append(ciclo)
            }
        }

        guard !duplicatas.isEmpty else { return }

        for dup in duplicatas {
            let original: CicloSoftex?
            if let bid = dup.backendId {
                original = originalPorBackendId[bid]
            } else {
                original = originalPorClientId[dup.clientId]
            }
            guard let original, original !== dup else { continue }
            for dia in dup.dias ?? [] {
                dia.ciclo = original
            }
            context.delete(dup)
        }

        salvarLocal()
    }
    
    func loadMoreDias(cicloId: Int) async {
        carregarDiasLocais()

        loadMoreDiasTask?.cancel()
        loadMoreDiasTask = Task {
            guard hasMoreDias, !isLoadingDias else { return }
            isLoadingDias = true
            defer { isLoadingDias = false }
            
            guard NetworkMonitor.shared.isConnected else { return }
            
            do {
                let dias = try await NetworkManager.shared.fetchDias(cicloId: cicloId, skip: diasSkip, limit: diasLimit)
                
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    
                    hasMoreDias = dias.count == diasLimit
                    diasSkip += dias.count

                    if atualCiclo.dias == nil {
                        atualCiclo.dias = []
                    }

                    for dia in dias {
                        salvarOuAtualizarDiaLocal(dia, no: atualCiclo)
                    }

                    salvarLocal()
                    carregarDiasLocais()
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    showError(error)
                }
            }
        }
    }

    private func carregarDiasLocais() {
        let cicloLocalId = self.atualCiclo.id
        var descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil },
            sortBy: [SortDescriptor(\.data)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.ciclo]
        let diasAtualizados: [DiaSoftex]
        if let context = modelContext {
            do {
                diasAtualizados = (try context.fetch(descriptor))
                    .filter { $0.ciclo?.id == cicloLocalId }
            } catch {
                showError(APIError.serverError(
                    message: "Erro ao buscar dias locais: \(error.localizedDescription)",
                    requestId: "-",
                    statusCode: 500
                ))
                return
            }
        } else {
            diasAtualizados = []
        }
        self.atualCiclo.dias = diasAtualizados
        self.objectWillChange.send()
    }
    
    private func salvarOuAtualizarDiaLocal(_ dia: DiaSoftex, no ciclo: CicloSoftex) {
        if let backendId = dia.backendId {
            let descriptor = FetchDescriptor<DiaSoftex>(
                predicate: #Predicate { $0.backendId == backendId }
            )
            if let existente = try? modelContext?.fetch(descriptor).first {
                existente.data = dia.data
                existente.saldo = dia.saldo
                existente.ciclo = ciclo
                for gasto in dia.gastos {
                    salvarOuAtualizarGastoLocal(gasto, no: existente)
                }
                existente.syncStatus = .synced
                existente.syncError = nil
                return
            }
        }
        dia.syncStatus = .synced
        dia.syncError = nil
        dia.ciclo = ciclo
        modelContext?.insert(dia)
        for gasto in dia.gastos {
            salvarOuAtualizarGastoLocal(gasto, no: dia)
        }
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
                existente.dia = dia
                existente.syncStatus = .synced
                existente.syncError = nil
                return
            }
        }
        gasto.syncStatus = .synced
        gasto.syncError = nil
        gasto.dia = dia
        modelContext?.insert(gasto)
    }
    
    @discardableResult
    private func salvarOuAtualizarCicloLocal(_ ciclo: CicloSoftex) -> CicloSoftex? {
        let userId = currentUser?.id ?? ""
        ciclo.userId = userId

        if let backendId = ciclo.backendId {
            let descriptor = FetchDescriptor<CicloSoftex>(
                predicate: #Predicate { $0.backendId == backendId && $0.userId == userId }
            )
            if let existente = try? modelContext?.fetch(descriptor).first {
                existente.titulo = ciclo.titulo
                existente.valor_total = ciclo.valor_total
                existente.gasto_total = ciclo.gasto_total
                existente.periodo = ciclo.periodo
                existente.diaria = ciclo.diaria
                existente.backendId = backendId
                existente.userId = userId
                existente.syncStatus = .synced
                existente.syncError = nil
                return existente
            }
        }

        let clientId = ciclo.clientId
        let descriptorPorClient = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.clientId == clientId && $0.userId == userId }
        )
        if let existente = try? modelContext?.fetch(descriptorPorClient).first {
            existente.titulo = ciclo.titulo
            existente.valor_total = ciclo.valor_total
            existente.gasto_total = ciclo.gasto_total
            existente.periodo = ciclo.periodo
            existente.diaria = ciclo.diaria
            existente.backendId = ciclo.backendId
            existente.userId = userId
            existente.syncStatus = .synced
            existente.syncError = nil
            return existente
        }

        ciclo.syncStatus = .synced
        ciclo.syncError = nil
        modelContext?.insert(ciclo)
        return ciclo
    }
    
    func createNewCiclo(startDate: Date, endDate: Date, totalValue: Decimal, titulo: String) async throws {
        let dayCount = Calendar.current.datesBetween(startDate, and: endDate)
        let safeDayCount = max(dayCount, 1)

        let saldo = totalValue / Decimal(safeDayCount)
        let periodo = createPeriodoString(from: startDate, to: endDate)

        let newCiclo = CicloSoftex(userId: currentUser?.id ?? "", valor_total: totalValue, gasto_total: Decimal(0), periodo: periodo, diaria: saldo, titulo: titulo, dias: nil)
        let dias: [DiaLoteRequest] = createAllDiasLoteRequest(dayCount: dayCount, startDate: startDate)
        
        try await postToNetwork(newCiclo: newCiclo, dias: dias)
    }
    
    func editCiclo(cicloId: Int, ciclo: CicloSoftex, dias: [DiaLoteRequest]? = nil) async {
        guard let cicloLocal = self.allCiclos.first(where: { $0.backendId == cicloId }) else {
            viewModelLogger.warning("editCiclo: ciclo nao encontrado allCiclos backendId=\(cicloId, privacy: .public)")
            return
        }

        viewModelLogger.info("editCiclo: atualizando cicloLocal backendId=\(cicloId, privacy: .public) titulo=\(ciclo.titulo, privacy: .private)")
        cicloLocal.titulo = ciclo.titulo
        cicloLocal.valor_total = ciclo.valor_total
        cicloLocal.diaria = ciclo.diaria
        cicloLocal.periodo = ciclo.periodo
        cicloLocal.syncStatus = .pending
        cicloLocal.syncError = nil

        if let novasDatas = dias, !novasDatas.isEmpty {
            let cal = Calendar.current
            let datasNovas = novasDatas.map { $0.data }

            if let diasExistentes = cicloLocal.dias {
                for dia in diasExistentes where dia.deletadoEm == nil {
                    if !datasNovas.contains(where: { cal.isDate($0, inSameDayAs: dia.data) }) {
                        dia.deletadoEm = Date()
                        dia.syncStatus = .pending
                        for gasto in dia.gastos where gasto.deletadoEm == nil {
                            gasto.deletadoEm = Date()
                            gasto.syncStatus = .pending
                            cicloLocal.gasto_total -= gasto.valor
                        }
                    }
                }
            }

            let diasVivos = cicloLocal.dias?.filter { $0.deletadoEm == nil } ?? []
            for novo in novasDatas {
                if !diasVivos.contains(where: { cal.isDate($0.data, inSameDayAs: novo.data) }) {
                    let dia = DiaSoftex(
                        clientId: novo.clientId ?? UUID().uuidString,
                        data: novo.data,
                        saldo: cicloLocal.diaria,
                        gastos: []
                    )
                    dia.ciclo = cicloLocal
                    modelContext?.insert(dia)
                    // Não faça append manual em relação inversa: definir dia.ciclo basta.
                }
            }
        }

        if let index = self.allCiclos.firstIndex(where: { $0.backendId == cicloId }) {
            self.allCiclos[index] = cicloLocal
        }

        if self.atualCiclo.backendId == cicloId {
            self.atualCiclo = cicloLocal
        }

        salvarLocal()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func deleteCiclo(ciclo: CicloSoftex) async throws {
        let cicloId = ciclo.id

        if let index = self.allCiclos.firstIndex(where: { $0.id == cicloId }) {
            self.allCiclos.remove(at: index)
        }

        if self.atualCiclo.id == cicloId {
            if let primeiroCiclo = self.allCiclos.first {
                self.atualCiclo = primeiroCiclo
                if let firstIndex = self.allCiclos.firstIndex(of: primeiroCiclo) {
                    self.index = firstIndex
                } else {
                    self.index = 0
                }
            } else {
                self.atualCiclo = CicloSoftex.vazio
                self.index = 0
            }
        }

        if let _ = ciclo.backendId {
            ciclo.deletadoEm = Date()
            ciclo.syncStatus = .pending
            salvarLocal()

            Task {
                await SyncManager.shared.sync(forcar: true)
            }
        } else {
            modelContext?.delete(ciclo)
            salvarLocal()
        }
    }

    @available(*, deprecated, message: "Use deleteCiclo(ciclo:) com o objeto CicloSoftex")
    func deleteCiclo(cicloId: Int) async throws {
        guard let ciclo = self.allCiclos.first(where: { $0.backendId == cicloId }) else { return }
        try await deleteCiclo(ciclo: ciclo)
    }
    
    private func salvarCicloLocal(_ ciclo: CicloSoftex) {
        salvarOuAtualizarCicloLocal(ciclo)
        salvarLocal()
    }
    
    func createAllDiasLoteRequest(dayCount: Int, startDate: Date) -> [DiaLoteRequest] {
        var dias: [DiaLoteRequest] = []
        let calendar = Calendar.current
        let count = max(dayCount, 1)

        for i in 0..<count {
            if let date = calendar.date(byAdding: .day, value: i, to: startDate) {
                dias.append(DiaLoteRequest(clientId: UUID().uuidString, data: date))
            }
        }
        return dias
    }
    
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        return formatter
    }()

    private func createPeriodoString(from: Date, to: Date) -> String {
        let start = Self.shortDateFormatter.string(from: from)
        let end = Self.shortDateFormatter.string(from: to)
        return "\(start) - \(end)"
    }
    
    private func salvarNovoCicloLocal(_ ciclo: CicloSoftex, comDias diasRequests: [DiaLoteRequest]) {
        viewModelLogger.info("salvarNovoCicloLocal: inserindo ciclo id=\(ciclo.id, privacy: .public) clientId=\(ciclo.clientId, privacy: .private) userId=\(ciclo.userId, privacy: .private)")
        ciclo.syncStatus = .pending
        modelContext?.insert(ciclo)

        let dias: [DiaSoftex] = diasRequests.compactMap { req in
            let dia = DiaSoftex(clientId: req.clientId ?? UUID().uuidString, data: req.data, saldo: ciclo.diaria)
            dia.ciclo = ciclo
            dia.syncStatus = .pending
            modelContext?.insert(dia)
            return dia
        }
        ciclo.dias = dias
        salvarLocal()
        viewModelLogger.info("salvarNovoCicloLocal: save concluido, syncStatus=\(ciclo.syncStatus.rawValue, privacy: .public)")
    }
    
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async throws {
        salvarNovoCicloLocal(newCiclo, comDias: dias)

        self.allCiclos.insert(newCiclo, at: 0)
        self.atualCiclo = newCiclo
        self.index = 0

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func createNewGasto(title: String, value: Decimal, dia: DiaSoftex, categoria: Categoria, comprovante: Data? = nil) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }

        guard self.atualCiclo.dias?.contains(where: { $0.id == dia.id }) == true else {
            throw APIError.serverError(message: "Dia selecionado não encontrado no ciclo atual", requestId: "-", statusCode: 404)
        }

        let novoGasto = GastosDia(
            valor: value,
            titulo: title,
            categoria: categoria,
            dia: dia,
            backendId: nil,
            comprovanteUrl: nil,
            comprovanteData: comprovante
        )

        modelContext.insert(novoGasto)

        self.atualCiclo.gasto_total += novoGasto.valor
        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }

        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }

    func anexarComprovante(gastoId: UUID, imageData: Data) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let gasto = encontrarGasto(id: gastoId) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        gasto.comprovanteData = imageData
        gasto.comprovanteParaRemover = false
        gasto.syncStatus = .pending
        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func removerComprovante(gastoId: UUID) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let gasto = encontrarGasto(id: gastoId) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        gasto.comprovanteData = nil
        gasto.comprovanteParaRemover = true
        gasto.syncStatus = .pending
        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    private func encontrarGasto(id: UUID) -> GastosDia? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor).first)
    }
    
    func deleteGasto(gastoID: UUID) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let dias = atualCiclo.dias else {
            throw APIError.serverError(message: "Ciclo atual não possui dias", requestId: "-", statusCode: 404)
        }
        
        var gastoParaDeletar: GastosDia?

        for dia in dias {
            if let gasto = dia.gastos.first(where: { $0.id == gastoID }) {
                gastoParaDeletar = gasto
                break
            }
        }

        guard let gasto = gastoParaDeletar else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }

        self.atualCiclo.gasto_total -= gasto.valor

        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }

        gasto.deletadoEm = Date()
        gasto.syncStatus = .pending
        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func editGasto(gastoId: UUID, novoDia: DiaSoftex, titulo: String, value: Decimal, categoria: Categoria) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let dias = self.atualCiclo.dias else {
            throw APIError.serverError(message: "Ciclo atual não possui dias", requestId: "-", statusCode: 404)
        }
        guard let oldDiaIndex = dias.firstIndex(where: { $0.gastos.contains(where: { $0.id == gastoId }) }) else {
            throw APIError.serverError(message: "Dia do gasto não encontrado", requestId: "-", statusCode: 404)
        }
        guard let oldGastoIndex = dias[oldDiaIndex].gastos.firstIndex(where: { $0.id == gastoId }) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        guard let newDiaIndex = dias.firstIndex(where: { $0.id == novoDia.id }) else {
            throw APIError.serverError(message: "Dia de destino não encontrado", requestId: "-", statusCode: 404)
        }
        guard let gastoLocal = self.atualCiclo.dias?[oldDiaIndex].gastos[oldGastoIndex] else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }

        let gastoAntigoValor = gastoLocal.valor
        let diferenca = value - gastoAntigoValor

        if oldDiaIndex == newDiaIndex {
            guard (self.atualCiclo.dias?[oldDiaIndex].saldo ?? 0) - diferenca >= 0 else {
                throw APIError.serverError(message: "Saldo do dia insuficiente", requestId: "-", statusCode: 400)
            }
        } else {
            guard (self.atualCiclo.dias?[newDiaIndex].saldo ?? 0) - value >= 0 else {
                throw APIError.serverError(message: "Saldo do dia de destino insuficiente", requestId: "-", statusCode: 400)
            }
        }

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
            self.atualCiclo.dias?[newDiaIndex].saldo -= value
            // Apenas alteramos o relacionamento; não manipulamos o array
            // `gastos` manualmente, para evitar duplicatas no SwiftData.
            gastoLocal.dia = self.atualCiclo.dias?[newDiaIndex]
        }

        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }
        
        try modelContext.save()
        
        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
}
