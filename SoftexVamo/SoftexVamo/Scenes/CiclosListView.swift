//
//  CiclosListView.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import Combine

struct CiclosListView: View {
    @EnvironmentObject var viewModel: CiclosViewModel
    @StateObject var authService = AuthService.shared
    @State private var showMenu = false
    
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
                        .skeleton(RoundedRectangle(cornerRadius: 22), isLoading: viewModel.isLoading)
                    
                    CicloGastosView() {
                        addNewGastoSheet.toggle()
                    } deleteAction: { diaId, gastoID in
                        Task { try await viewModel.deleteGasto(gastoID: gastoID) }
                    }
                    .id(viewModel.atualCiclo.id)
                    .environmentObject(GastosViewModel(ciclo: viewModel.atualCiclo))
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
                    .environmentObject(GastosViewModel(ciclo: viewModel.atualCiclo))
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
            }
        }
        
    }
}

#Preview {
    CiclosListView()
        .environmentObject(CiclosViewModel())
}
