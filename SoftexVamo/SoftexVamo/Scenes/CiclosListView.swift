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
    //    @StateObject var user = AuthService.shared.currentUser!
    
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
                    
                }.padding()
                
                if viewModel.isLoading {
                    CardMainView()
                    
                    CicloGastosView() {
                        addNewGastoSheet.toggle()
                    } deleteAction: { diaId, gastoID in
                        Task { try await viewModel.deleteGasto(gastoID: gastoID) }
                    }
                    .id(viewModel.actualCiclo.id)
                    .environmentObject(CicloGastosViewModel(ciclo: viewModel.actualCiclo))
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
                    .id(viewModel.actualCiclo.id)
                    .environmentObject(CicloGastosViewModel(ciclo: viewModel.actualCiclo))
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
    @Published var actualCiclo: CicloSoftex = CicloSoftex.example
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
        self.actualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
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
                self.actualCiclo = cache
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
                
                self.actualCiclo = try await NetworkManager.shared.fetchCicloById(cicloId: cicloId)
                self.salvarNoCache(ciclo: cicloParaSalvar)
                
            } else {
                self.actualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
                UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            }
            
            self.isLoading = false
            
            self.hasLoadedOnce = true
            
        } catch {
            print("Erro ao buscar ciclos:", error)
            
            self.allCiclos = []
            self.actualCiclo = CicloSoftex(valor_total: 0, gasto_total: 0, periodo: "", diaria: 0, titulo: "", dias: [])
            UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
            self.isLoading = false
            self.hasLoadedOnce = true
        }
    }
    
    func createNewCiclo(startDate: Date, endDate: Date, totalValue: Float, titulo: String) async {
        let dayCount = Calendar.current.datesBetween(startDate, and: endDate)
        let saldo = totalValue / Float(dayCount)
        let days: [DiaSoftex] = createAllDays(dayCount: dayCount, startDate: startDate, saldo: saldo)
        let periodo = createPeriodoString(from: startDate, to: endDate)
        
        let newCiclo = CicloSoftex(valor_total: totalValue, gasto_total: 0, periodo: periodo, diaria: saldo, titulo: titulo, dias: days)
        
        await postToNetwork(newCiclo: newCiclo, daysCount: dayCount)
    }
    
    private func salvarNoCache(ciclo: CicloSoftex) {
        if ciclo.backendId != nil {
            if let encoded = try? JSONEncoder().encode(ciclo) {
                UserDefaults.standard.set(encoded, forKey: "ultimo_ciclo_cache")
            }
        }
    }
    
    private func createAllDays(dayCount: Int, startDate: Date, saldo: Float) -> [DiaSoftex] {
        var days: [DiaSoftex] = []
        for i in 0...dayCount - 1 {
            let time = 86400 * i
            let date = startDate.addingTimeInterval(TimeInterval(time))
            days.append(DiaSoftex(gastos: [], data: date, saldo: saldo))
        }
        return days
    }
    
    private func createPeriodoString(from: Date, to: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM"
        return "\(dateFormatter.string(from: from)) - \(dateFormatter.string(from: to))"
    }
    
    private func postToNetwork(newCiclo: CicloSoftex, daysCount: Int) async {
        do {
            let novoCiclo = try await NetworkManager.shared.postCiclo(newCiclo: newCiclo)
            self.allCiclos.append(novoCiclo)
            self.actualCiclo = novoCiclo
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
            guard let diaIndex = actualCiclo.dias?.firstIndex(where: { $0.backendId == dia.backendId }) else { return }
            
            self.actualCiclo.dias?[diaIndex].gastos.append(novoGasto)
            self.actualCiclo.gasto_total += novoGasto.valor
            self.allCiclos[index] = self.actualCiclo
        }
    }
    
    func deleteGasto(gastoID: Int) async throws{
        guard let dias = actualCiclo.dias else { return }
        
        for diaIndex in dias.indices {
            if let gastoIndex = dias[diaIndex].gastos.firstIndex(where: { $0.backendId == gastoID }) {
                let valorRemovido = dias[diaIndex].gastos[gastoIndex].valor
                await MainActor.run {
                    self.actualCiclo.dias?[diaIndex].gastos.remove(at: gastoIndex)
                    self.actualCiclo.gasto_total -= valorRemovido
                    
                    if self.index < self.allCiclos.count {
                        self.allCiclos[self.index] = self.actualCiclo
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
