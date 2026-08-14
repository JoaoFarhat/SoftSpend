//
//  CicloViewModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 27/07/26.
//

import Foundation
import Combine
import SwiftUI

final class CiclosViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex.vazio
    @Published var gastosInfo: GastosDia = GastosDia.example
    @Published var availableInfo: GastosDia = GastosDia.example
    @Published var isLoading: Bool = true
    @Published var selectedTab: Int = 0
    
    var errorManager: ErrorManager?
    
    private var hasLoadedOnce = false
    var index: Int = 0
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    @MainActor
    private func showError(_ error: Error) {
        errorManager?.show(error: error)
    }
    
    @MainActor
    func reset() {
        self.allCiclos = []
        self.atualCiclo = CicloSoftex.vazio
        self.index = 0
        self.isLoading = true
        self.hasLoadedOnce = false
        UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
    }

    @MainActor
    func fetchCiclosResumo() async {
        
        guard currentUser != nil else {
            showError(APIError.serverError(message: "Usuario nao esta logado", requestId: "-", statusCode: 401))
            self.isLoading = false
            return
        }
        
        
        
        if hasLoadedOnce { return }
        
        
        
        
        let cacheData = UserDefaults.standard.data(forKey: "ultimo_ciclo_cache")
        
        if let data = cacheData {
            if let cache = try? JSONDecoder().decode(CicloSoftex.self, from: data)
            {
                self.atualCiclo = cache
            }
        }
        
       
        do {
            let ciclos = try await NetworkManager.shared.fetchCicloResumo()
            
            self.allCiclos = ciclos
            
            self.index = 0
            
            if !self.allCiclos.isEmpty {
                let cicloParaSalvar = self.allCiclos[self.index]
                
                guard let cicloId = cicloParaSalvar.backendId else {
                    return
                }
                
                self.atualCiclo = try await NetworkManager.shared.fetchCicloById(cicloId: cicloId)
                self.salvarNoCache(ciclo: self.atualCiclo)
                
            } else {
                self.atualCiclo = CicloSoftex.vazio
                UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            }
            
            self.isLoading = false
            
            self.hasLoadedOnce = true
            
        } catch {
            showError(error)

            self.allCiclos = []
            self.atualCiclo = CicloSoftex.vazio
            UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            self.isLoading = false
            self.hasLoadedOnce = true
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
    
    @MainActor
    func editCiclo(cicloId: Int, ciclo: CicloSoftex, dias: [DiaLoteRequest]? = nil) async throws {
        var cicloEditado = try await NetworkManager.shared.putCiclo(cicloId: cicloId, cicloEditado: ciclo)
        
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
    
    @MainActor
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
            if let encoded = try? JSONEncoder().encode(ciclo) {
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
    
    @MainActor
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async throws {
        var novoCiclo = try await NetworkManager.shared.postCiclo(newCiclo: newCiclo)
        
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
        
        let gasto = GastosDia(valor: value, titulo: title, categoria: categoria)
        var novoGasto = try await NetworkManager.shared.postGasto(newGasto: gasto, diaId: diaId)
        
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

    @MainActor
    func anexarComprovante(gastoId: Int, imageData: Data) async throws {
        let atualizado = try await NetworkManager.shared.uploadComprovante(gastoId: gastoId, imageData: imageData)
        atualizarComprovanteLocal(gastoId: gastoId, url: atualizado.comprovanteUrl)
    }
    
    @MainActor
    func removerComprovante(gastoId: Int) async throws {
        _ = try await NetworkManager.shared.deleteComprovante(gastoId: gastoId)
        atualizarComprovanteLocal(gastoId: gastoId, url: nil)
    }
    
    @MainActor
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
        
        var gastoEditado = GastosDia(valor: value, titulo: titulo, categoria: categoria)
        gastoEditado.diaId = diaBackendId
        
        var gastoAtualizado = try await NetworkManager.shared.putGasto(gastoId: gastoId, gastoEditado: gastoEditado)
        
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
