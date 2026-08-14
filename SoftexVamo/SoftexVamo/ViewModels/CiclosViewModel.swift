//
//  CicloViewModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 27/07/26.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class CiclosViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex.vazio
    @Published var gastosInfo: GastosDia = GastosDia.example
    @Published var availableInfo: GastosDia = GastosDia.example
    @Published var isLoading: Bool = true
    @Published var selectedTab: Int = 0
    @Published var hasMorePages: Bool = true
    
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
        UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
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
        
        let cacheData = UserDefaults.standard.data(forKey: "ultimo_ciclo_cache")
        
        if !append, let data = cacheData {
            if let cache = try? JSONDecoder().decode(CicloResponse.self, from: data) {
                self.atualCiclo = CicloSoftex(from: cache)
            }
        }
        
        do {
            let ciclos = try await NetworkManager.shared.fetchCicloResumo(skip: skip, limit: limit)
            
            hasMorePages = ciclos.count == limit
            
            if append {
                self.allCiclos.append(contentsOf: ciclos)
            } else {
                self.allCiclos = ciclos
                self.index = 0
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
                self.salvarNoCache(ciclo: self.atualCiclo)
            } else if !append {
                self.atualCiclo = CicloSoftex.vazio
                UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            }
            
            isLoading = false
            hasLoadedOnce = true
            
        } catch {
            showError(error)

            if !append {
                self.allCiclos = []
                self.atualCiclo = CicloSoftex.vazio
                UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
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
            atualCiclo.dias?.append(contentsOf: dias)
            
        } catch {
            showError(error)
        }
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
        let request = CicloUpdateRequest(
            titulo: ciclo.titulo,
            valor_total: ciclo.valor_total,
            diaria: ciclo.diaria,
            periodo: ciclo.periodo
        )
        var cicloEditado = try await NetworkManager.shared.putCiclo(cicloId: cicloId, request: request)
        
        if let dias {
            cicloEditado.dias = try await NetworkManager.shared.syncDiasLote(cicloId: cicloId, dias: dias)
        }
        
        if let index = self.allCiclos.firstIndex(where: { $0.backendId == cicloId }) {
            self.allCiclos[index] = cicloEditado
        }
        
        if self.atualCiclo.backendId == cicloId {
            self.atualCiclo = cicloEditado
            self.salvarNoCache(ciclo: cicloEditado)
        }
    }
    
    func deleteCiclo(cicloId: Int) async throws {
        _ = try await NetworkManager.shared.deleteCiclo(cicloId: cicloId)
        
        if let index = self.allCiclos.firstIndex(where: { $0.backendId == cicloId }){
            self.allCiclos.remove(at: index)
        }
        
        if self.atualCiclo.backendId == cicloId {
            // Tenta pegar o primeiro ciclo da lista
            if let primeiroCiclo = self.allCiclos.first {
                self.atualCiclo = primeiroCiclo
                self.salvarNoCache(ciclo: primeiroCiclo)
            } else {
                self.atualCiclo = CicloSoftex.vazio
                self.index = 0
                UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            }
        }
    }
    
    private func salvarNoCache(ciclo: CicloSoftex) {
        if ciclo.backendId != nil {
            if let encoded = try? JSONEncoder().encode(ciclo.toDTO()) {
                UserDefaults.standard.set(encoded, forKey: "ultimo_ciclo_cache")
            }
        }
    }
    
    func createAllDiasLoteRequest(dayCount: Int, startDate: Date) -> [DiaLoteRequest] {
        var dias: [DiaLoteRequest] = []
        let calendar = Calendar.current
        
        for i in 0..<dayCount {
                if let date = calendar.date(byAdding: .day, value: i, to: startDate) {
                    dias.append(DiaLoteRequest(data: date))
                }
            }
        return dias
    }
    
    private func createPeriodoString(from: Date, to: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM"
        return "\(dateFormatter.string(from: from)) - \(dateFormatter.string(from: to))"
    }
    
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async throws {
        let request = CicloCreateRequest(
            titulo: newCiclo.titulo,
            valor_total: newCiclo.valor_total,
            diaria: newCiclo.diaria,
            periodo: newCiclo.periodo
        )
        var novoCiclo = try await NetworkManager.shared.postCiclo(request: request)
        
        guard let cicloId = novoCiclo.backendId else {
            throw URLError(.cannotParseResponse)
        }
        
        do {
            novoCiclo.dias = try await NetworkManager.shared.postDiasLote(cicloId: cicloId, dias: dias)
        } catch {
            try? await NetworkManager.shared.deleteCiclo(cicloId: cicloId)
            throw error
        }
        
        self.allCiclos.insert(novoCiclo, at: 0)
        self.atualCiclo = novoCiclo
        self.index = 0
        self.salvarNoCache(ciclo: novoCiclo)
    }
    
    func createNewGasto(title: String, value: Float, dia: DiaSoftex, categoria: Categoria, comprovante: Data? = nil) async throws {
        guard let diaId = dia.backendId else { return }
        
        let request = GastoCreateRequest(titulo: title, valor: value, categoria: categoria, dia_id: diaId)
        var novoGasto = try await NetworkManager.shared.postGasto(request: request)
        
        if let comprovante, let gastoId = novoGasto.backendId {
            do {
                let comComprovante = try await NetworkManager.shared.uploadComprovante(gastoId: gastoId, imageData: comprovante)
                novoGasto.comprovanteUrl = comComprovante.comprovanteUrl
            } catch {
                showError(error)
            }
        }
        
        await MainActor.run {
            guard let diaIndex = atualCiclo.dias?.firstIndex(where: { $0.backendId == dia.backendId }) else { return }
            
            self.atualCiclo.dias?[diaIndex].gastos.append(novoGasto)
            self.atualCiclo.gasto_total += novoGasto.valor
            self.allCiclos[index] = self.atualCiclo
            self.salvarNoCache(ciclo: self.atualCiclo)
        }
    }

    func anexarComprovante(gastoId: Int, imageData: Data) async throws {
        let atualizado = try await NetworkManager.shared.uploadComprovante(gastoId: gastoId, imageData: imageData)
        atualizarComprovanteLocal(gastoId: gastoId, url: atualizado.comprovanteUrl)
    }
    
    func removerComprovante(gastoId: Int) async throws {
        _ = try await NetworkManager.shared.deleteComprovante(gastoId: gastoId)
        atualizarComprovanteLocal(gastoId: gastoId, url: nil)
    }
    
    private func atualizarComprovanteLocal(gastoId: Int, url: String?) {
        guard let dias = self.atualCiclo.dias,
              let diaIndex = dias.firstIndex(where: { $0.gastos.contains(where: { $0.backendId == gastoId }) }),
              let gastoIndex = dias[diaIndex].gastos.firstIndex(where: { $0.backendId == gastoId }) else { return }
        
        self.atualCiclo.dias?[diaIndex].gastos[gastoIndex].comprovanteUrl = url
        
        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }
        
        self.salvarNoCache(ciclo: self.atualCiclo)
    }
    
    func deleteGasto(gastoID: Int) async throws{
        guard let dias = atualCiclo.dias else { return }
        
        for diaIndex in dias.indices {
            if let gastoIndex = dias[diaIndex].gastos.firstIndex(where: { $0.backendId == gastoID }) {
                let valorRemovido = dias[diaIndex].gastos[gastoIndex].valor
                await MainActor.run {
                    self.atualCiclo.dias?[diaIndex].gastos.remove(at: gastoIndex)
                    self.atualCiclo.gasto_total -= valorRemovido
                    
                    if self.index < self.allCiclos.count {
                        self.allCiclos[self.index] = self.atualCiclo
                    }
                }
                break
            }
        }
        
            try await NetworkManager.shared.deleteGasto(gastoId: gastoID)
    }
    
    func editGasto(gastoId: Int, novoDia: DiaSoftex, titulo: String, value: Float, categoria: Categoria) async throws {
        guard let diaBackendId = novoDia.backendId else { return }
        
        let request = GastoUpdateRequest(titulo: titulo, valor: value, categoria: categoria)
        var gastoAtualizado = try await NetworkManager.shared.putGasto(gastoId: gastoId, request: request)
        
        await MainActor.run {
            guard let dias = self.atualCiclo.dias,
                  let oldDiaIndex = dias.firstIndex(where: { $0.gastos.contains(where: { $0.backendId == gastoId }) }),
                  let oldGastoIndex = dias[oldDiaIndex].gastos.firstIndex(where: { $0.backendId == gastoId }),
                  let newDiaIndex = dias.firstIndex(where: { $0.backendId == diaBackendId }) else { return }
            
            let gastoAntigo = self.atualCiclo.dias?[oldDiaIndex].gastos[oldGastoIndex]
            let diferenca = value - (gastoAntigo?.valor ?? 0)
            
            // Preserva o id local para evitar recarregamento desnecessário do ForEach
            if let antigoId = gastoAntigo?.id {
                gastoAtualizado.id = antigoId
            }
            
            self.atualCiclo.gasto_total += diferenca
            
            if oldDiaIndex == newDiaIndex {
                self.atualCiclo.dias?[oldDiaIndex].saldo -= diferenca
                self.atualCiclo.dias?[oldDiaIndex].gastos[oldGastoIndex] = gastoAtualizado
            } else {
                self.atualCiclo.dias?[oldDiaIndex].saldo += (gastoAntigo?.valor ?? 0)
                self.atualCiclo.dias?[oldDiaIndex].gastos.remove(at: oldGastoIndex)
                
                self.atualCiclo.dias?[newDiaIndex].saldo -= value
                self.atualCiclo.dias?[newDiaIndex].gastos.append(gastoAtualizado)
            }
            
            if self.index < self.allCiclos.count {
                self.allCiclos[self.index] = self.atualCiclo
            }
            
            self.salvarNoCache(ciclo: self.atualCiclo)
        }
    }
}
