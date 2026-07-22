//
//  CiclosListView.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import Combine

struct CiclosListView: View {
    @EnvironmentObject var viewModel: CiclosListViewModel
    @StateObject var authService = AuthService.shared
    @State private var showMenu = false
    let newCicloViewModel = NewCicloViewModel()
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    let corFundoTela = LinearGradient.appPurple
    
    @State var addNewGastoSheet: Bool = false
    @State var addNewCicloSheet: Bool = false
    
    var body: some View {
        NavigationStack{
            VStack(alignment: .leading, spacing: 0) {
                HStack{
                    VStack(alignment: .leading){
                        Text("Controle Financeiro")
                            .foregroundStyle(Color("textSecondary"))
                        Text("Seus Gastos")
                            .bold()
                            .font(.title)
                    }
                    
                    Spacer()
                    
                    ZStack(alignment: .topTrailing) {
                        Button {
                            withAnimation(.spring()) {
                                showMenu.toggle()
                            }
                        } label: {
                            HStack {
                                Text(currentUser?.nome.prefix(2).uppercased() ?? "??")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(Color.appPurple)
                                    .clipShape(Circle())
                                
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .rotationEffect(.degrees(showMenu ? 0 : 180))
                                    .foregroundStyle(Color("textPrimary"))
                            }
                            .padding(8)
                            .background(Color("cardBackground"))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.1), radius: 4)
                            
                        }
                    }
                    
                }.padding(10)
                
                if viewModel.isLoading {
                    CardMainView()
                    
                    CicloGastosView() {
                        addNewGastoSheet.toggle()
                    } deleteAction: { diaId, gastoID in
                        Task { try await viewModel.deleteGasto(gastoID: gastoID) }
                    }
                    .id(viewModel.atualCiclo.id)
                    .environmentObject(CicloGastosViewModel(ciclo: viewModel.atualCiclo))
                } else if viewModel.allCiclos.isEmpty || viewModel.allCiclos.allSatisfy({ $0.backendId == nil }) {
                    EmptyCicloView {
                        addNewCicloSheet.toggle()
                    }
                    
                    Spacer()
                } else {
                    CardMainView()
                    
                    CicloGastosView() {
                        addNewGastoSheet.toggle()
                    } deleteAction: { diaId, gastoID in
                        Task { try await viewModel.deleteGasto(gastoID: gastoID) }
                    }
                    .id(viewModel.atualCiclo.id)
                    .environmentObject(CicloGastosViewModel(ciclo: viewModel.atualCiclo))
                }
                
                Spacer()
            }
            .task {
                await viewModel.fetchCiclosResumo()
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden)
            .background(.backgroundCor)
            .overlay(alignment: .topTrailing) {
                if showMenu {
                    MenuView(showMenu: $showMenu)
                        .environmentObject(viewModel)
                        .offset(x: -16, y: 70)
                }
            }
            .fullScreenCover(isPresented: $addNewCicloSheet) {
                NewCicloView()
                    .environmentObject(newCicloViewModel)
            }
        }
        
    }
}

final class CiclosListViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex.example
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
            
            self.index = max(self.allCiclos.count - 1, 0)
            
            if !self.allCiclos.isEmpty {
                let cicloParaSalvar = self.allCiclos[self.index]
                
                guard let cicloId = cicloParaSalvar.backendId else {
                    return
                }
                
                self.atualCiclo = try await NetworkManager.shared.fetchCicloById(cicloId: cicloId)
                self.salvarNoCache(ciclo: cicloParaSalvar)
                
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
    
    private func salvarNoCache(ciclo: CicloSoftex) {
        if ciclo.backendId != nil {
            if let encoded = try? JSONEncoder().encode(ciclo) {
                UserDefaults.standard.set(encoded, forKey: "ultimo_ciclo_cache")
            }
        }
    }
    
    private func createAllDiasLoteRequest(dayCount: Int, startDate: Date) -> [DiaLoteRequest] {
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
            
            self.allCiclos.append(novoCiclo)
            self.atualCiclo = novoCiclo
            self.index = self.allCiclos.count - 1
            
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

#Preview {
    CiclosListView()
        .environmentObject(CiclosListViewModel())
}
