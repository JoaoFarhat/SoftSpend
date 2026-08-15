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
    weak var errorManager: ErrorManager?
    
    private var hasLoadedOnce = false
    var index: Int = 0
    private var skip = 0
    private let limit = 5
    
    private var diasSkip = 0
    private let diasLimit = 20
    private var hasMoreDias = true
    var isLoadingDias = false
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    private func showError(_ error: Error) {
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
    
    /// Remove ciclos locais duplicados por backendId E por clientId.
    /// Bug anterior inseria um ciclo "detached" no context a cada abertura,
    /// criando cópias com o mesmo backendId. Também deduplica ciclos offline
    /// (sem backendId) por clientId — quando o sync falha e o app reinicia,
    /// pode haver cópias com o mesmo clientId mas sem backendId.
    /// Mantém o mais antigo (menor criadoEm) e deleta os demais.
    /// Dias/gastos das duplicatas são transferidos para o ciclo original.
    private func deduplicarCiclosLocais() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil },
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

        // Deduplica por backendId (ciclos já sincronizados) OU por clientId
        // (ciclos offline que podem ter sido duplicados por sync parcial).
        // Ciclos com backendId só deduplicam por backendId; ciclos sem
        // backendId (offline) só deduplicam por clientId. Misturar as duas
        // chaves pode marcar um ciclo legítimo como duplicata.
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
            // Encontra o original: prefere por backendId, senão por clientId.
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
    
    private func loadCiclos(append: Bool) async {
        
        guard currentUser != nil else {
            showError(APIError.serverError(message: "Usuario nao esta logado", requestId: "-", statusCode: 401))
            self.isLoading = false
            return
        }
        
        if append, !hasMorePages { return }
        if !append, hasLoadedOnce { return }
        
        isLoading = true
        
        // Deduplica ciclos locais por backendId. Bug anterior (ciclo detached
        // auto-inserido pelo SwiftData) criava duplicatas a cada abertura.
        // Mantém o primeiro (mais antigo) e remove os demais. Dias associados
        // às duplicatas serão re-fetchados pelo loadMoreDias.
        if !append {
            deduplicarCiclosLocais()
        }
        
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
                // Evita duplicar ciclos que já estão no array. O fetch local
                // não é paginado por skip/limit, então retorna TODOS os ciclos
                // a cada chamada. Quando online, o array é substituído depois
                // por ciclosAtualizados; mas quando offline, o return early
                // mantém o append — daí a duplicação.
                let idsExistentes = Set(self.allCiclos.map { $0.id })
                let novos = ciclosLocais.filter { !idsExistentes.contains($0.id) }
                self.allCiclos.append(contentsOf: novos)
            }
            self.isLoading = false
        }

        // Se offline, usa apenas dados locais — não tenta rede (evita
        // congelamento da UI por timeout de 15-30s).
        guard NetworkMonitor.shared.isConnected else {
            if !append, !ciclosLocais.isEmpty {
                // atualCiclo já foi definido como ciclosLocais[0] acima.
                // Carrega dias locais pelo UUID do ciclo — funciona mesmo
                // para ciclos criados offline (sem backendId).
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
                    return
                }
                
                self.atualCiclo = cicloParaSalvar
                self.atualCiclo.dias = []
                self.diasSkip = 0
                self.hasMoreDias = true
                await loadMoreDias(cicloId: cicloId)
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
        guard hasMoreDias, !isLoadingDias else { return }
        isLoadingDias = true
        defer { isLoadingDias = false }

        // Se offline, carrega apenas do banco local — não tenta rede.
        guard NetworkMonitor.shared.isConnected else {
            carregarDiasLocais()
            return
        }

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

            salvarLocal()
            carregarDiasLocais()

        } catch {
            showError(error)
        }
    }

    /// Busca dias do banco local e atualiza atualCiclo.dias.
    /// Usa o UUID local (id) do ciclo atual, não backendId — funciona
    /// mesmo para ciclos criados offline que ainda não têm backendId.
    /// Em caso de erro de fetch, mantém os dias existentes.
    private func carregarDiasLocais() {
        let cicloLocalId = self.atualCiclo.id
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.ciclo?.id == cicloLocalId && $0.deletadoEm == nil },
            sortBy: [SortDescriptor(\.data)]
        )
        let diasAtualizados: [DiaSoftex]
        if let context = modelContext {
            do {
                diasAtualizados = try context.fetch(descriptor)
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
    
    /// Salva ou atualiza um ciclo no DB local. Retorna a instância
    /// context-owned (a que está no ModelContext), seja ela a existente
    /// atualizada ou a recém-inserida. O caller DEVE usar o retorno em vez
    /// do parâmetro para evitar trabalhar com instâncias detached.
    @discardableResult
    private func salvarOuAtualizarCicloLocal(_ ciclo: CicloSoftex) -> CicloSoftex? {
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
                existente.backendId = backendId
                existente.syncStatus = .synced
                existente.syncError = nil
                return existente
            }
        }

        let clientId = ciclo.clientId
        let descriptorPorClient = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.clientId == clientId }
        )
        if let existente = try? modelContext?.fetch(descriptorPorClient).first {
            existente.titulo = ciclo.titulo
            existente.valor_total = ciclo.valor_total
            existente.gasto_total = ciclo.gasto_total
            existente.periodo = ciclo.periodo
            existente.diaria = ciclo.diaria
            existente.backendId = ciclo.backendId
            existente.syncStatus = .synced
            existente.syncError = nil
            return existente
        }

        ciclo.syncStatus = .synced
        ciclo.syncError = nil
        modelContext?.insert(ciclo)
        return ciclo
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
    
    func editCiclo(cicloId: Int, ciclo: CicloSoftex, dias: [DiaLoteRequest]? = nil) async {
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

        salvarLocal()

        // Sync em background — não bloqueia o MainActor.
        // Se offline, o sync falha e marca syncStatus = .failed com backoff.
        // O SyncManager retenta automaticamente quando a conexão volta.
        Task {
            await SyncManager.shared.sync()
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
        
        // Soft delete local
        ciclo.deletadoEm = Date()
        ciclo.syncStatus = .pending
        salvarLocal()
        
        Task {
            await SyncManager.shared.sync()
        }
    }
    
    private func salvarCicloLocal(_ ciclo: CicloSoftex) {
        salvarOuAtualizarCicloLocal(ciclo)
        salvarLocal()
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
        // Insere o ciclo PRIMEIRO para que o relacionamento inverse
        // (dia.ciclo) seja resolvido corretamente pelo SwiftData.
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
    }
    
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async throws {
        salvarNovoCicloLocal(newCiclo, comDias: dias)

        self.allCiclos.insert(newCiclo, at: 0)
        self.atualCiclo = newCiclo
        self.index = 0

        // Sync em background — erros de sync são registrados no próprio model
        // (syncStatus = .failed, syncError) pelo SyncManager, e a UI reage a
        // essas mudanças via @Published/@Query. sync() não é throws.
        Task {
            await SyncManager.shared.sync()
        }
    }
    
    func createNewGasto(title: String, value: Float, dia: DiaSoftex, categoria: Categoria, comprovante: Data? = nil) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }

        // Valida o dia antes de criar o gasto — evita insert órfão se o
        // dia não pertence mais ao ciclo atual (ex: ciclo trocou no meio).
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

        // NÃO fazer append manual em dia.gastos: o init já setou
        // novoGasto.dia = dia, e SwiftData estabelece a relação
        // inversa automaticamente após o insert. O append manual
        // criava uma duplicata na relação, causando crash quando o
        // SyncActor fazia merge do contexto.
        self.atualCiclo.gasto_total += novoGasto.valor
        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }

        try modelContext.save()

        Task {
            await SyncManager.shared.sync()
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

        // Sync em background — não bloqueia o MainActor.
        Task {
            await SyncManager.shared.sync()
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

        // Sync em background — não bloqueia o MainActor.
        Task {
            await SyncManager.shared.sync()
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
        
        for diaIndex in dias.indices {
            if let gastoIndex = dias[diaIndex].gastos.firstIndex(where: { $0.id == gastoID }) {
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
    
    func editGasto(gastoId: UUID, novoDia: DiaSoftex, titulo: String, value: Float, categoria: Categoria) async throws {
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
            self.atualCiclo.dias?[oldDiaIndex].gastos.remove(at: oldGastoIndex)

            self.atualCiclo.dias?[newDiaIndex].saldo -= value
            self.atualCiclo.dias?[newDiaIndex].gastos.append(gastoLocal)
            gastoLocal.dia = self.atualCiclo.dias?[newDiaIndex]
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
