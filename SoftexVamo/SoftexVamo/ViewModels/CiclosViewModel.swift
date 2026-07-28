//
//  CicloViewModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 27/07/26.
//

import Foundation
import Combine

final class CiclosViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "30/04 - 30/04", diaria: 0, titulo: "", dias: [])
    @Published var gastosInfo: GastosDia = GastosDia.example
    @Published var availableInfo: GastosDia = GastosDia.example
    @Published var isLoading: Bool = true
    @Published var selectedTab: Int = 0
    
    private var hasLoadedOnce = false
    var index: Int = 0
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    @MainActor
    func reset() {
        self.allCiclos = []
        self.atualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
        self.index = 0
        self.isLoading = true
        self.hasLoadedOnce = false
        UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
    }

    @MainActor
    func fetchCiclosResumo() async {
        
        guard currentUser != nil else {
            print("Erro: Usuário não está logado")
//            self.isLoading = false
            return
        }
        
        
        
        if hasLoadedOnce { return }
        
        
        
        
        let cacheData = UserDefaults.standard.data(forKey: "ultimo_ciclo_cache")
        
        if let data = cacheData {
            if let cache = try? JSONDecoder().decode(CicloSoftex.self, from: data)
            {
                self.atualCiclo = cache
                print("Cache carregado em background")
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
                self.atualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
                UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            }
            
            self.isLoading = false
            
            self.hasLoadedOnce = true
            
        } catch {
            print("Erro ao buscar ciclos:", error)
            
            self.allCiclos = []
            self.atualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
            UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            self.isLoading = false
            self.hasLoadedOnce = true
        }
    }
    
    func createNewCiclo(startDate: Date, endDate: Date, totalValue: Float, titulo: String) async {
        let dayCount = Calendar.current.datesBetween(startDate, and: endDate)
        let safeDayCount = max(dayCount, 1)
        
        let saldo = totalValue / Float(safeDayCount)
        let periodo = createPeriodoString(from: startDate, to: endDate)
        
        let newCiclo = CicloSoftex(valor_total: totalValue, gasto_total: 0, periodo: periodo, diaria: saldo, titulo: titulo, dias: nil)
        let dias: [DiaLoteRequest] = createAllDiasLoteRequest(dayCount: dayCount, startDate: startDate)
        
        await postToNetwork(newCiclo: newCiclo, dias: dias)
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
                self.atualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
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
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async {
        do {
            var novoCiclo = try await NetworkManager.shared.postCiclo(newCiclo: newCiclo)
            
            guard let cicloId = novoCiclo.backendId else {
                print("Erro: ciclo criado sem backendId")
                return
            }
            
            novoCiclo.dias = try await NetworkManager.shared.postDiasLote(cicloId: cicloId, dias: dias)
            
            self.allCiclos.insert(novoCiclo, at: 0)
            self.atualCiclo = novoCiclo
            self.index = 0
            
        } catch {
            print("Erro ao criar o ciclo:", error)
        }
    }
    
    func createNewGasto(title: String, value: Float, dia: DiaSoftex, categoria: Categoria) async throws {
        guard let diaId = dia.backendId else { return }
        
        let gasto = GastosDia(valor: value, titulo: title, categoria: categoria)
        let novoGasto = try await NetworkManager.shared.postGasto(newGasto: gasto, diaId: diaId)
        
        await MainActor.run {
            guard let diaIndex = atualCiclo.dias?.firstIndex(where: { $0.backendId == dia.backendId }) else { return }
            
            self.atualCiclo.dias?[diaIndex].gastos.append(novoGasto)
            self.atualCiclo.gasto_total += novoGasto.valor
            self.allCiclos[index] = self.atualCiclo
        }
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
}
