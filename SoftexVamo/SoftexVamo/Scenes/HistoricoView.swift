//
//  HistoricoView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI

struct HistoricoView: View {
    
    @EnvironmentObject var viewModel: CiclosListViewModel
    @State var navegando = false
    @State private var showingModal = false
    
    let newCicloViewModel = NewCicloViewModel()
    
    var body: some View {
        NavigationStack{
            VStack(alignment: .leading){
                
                VStack(alignment: .leading){
                    Text("Histórico")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Todos os seus ciclos registrados")
                        .foregroundStyle(Color("textSecondary"))
                        .padding(.bottom)
                }
                .padding()
                
                if(viewModel.allCiclos.isEmpty/* || viewModel.allCiclos.allSatisfy({ $0.backendId == nil })*/) {
                    Spacer()
                    EmptyHistoricoView{
                        showingModal.toggle()
                    }
                    Spacer()
                }
                else{
                    ScrollView{
                        VStack(alignment: .leading){
                            
                            ForEach(viewModel.allCiclos){ ciclo in
                                CardCiclosView(ciclo: ciclo)
                                    .environmentObject(viewModel)
                                    .id("\(ciclo.id)-\(viewModel.atualCiclo.id)")
                            }
                            
                            
                            Button{
                                showingModal.toggle()
                            }label: {
                                HStack(alignment: .center, spacing: 12) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Color("textPrimary"))
                                        .frame(width: 40, height: 40)
                                        .background(Color("cinza"))
                                        .cornerRadius(16)
                                    
                                    Text("Criar Novo Ciclo")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(Color("textSecondary"))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 100)
                                .background {
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(
                                            Color.gray.opacity(0.4),
                                            style: StrokeStyle(lineWidth: 2, dash: [3])
                                        )
                                        .background(Color("cardBackground"))
                                        .cornerRadius(18)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 10)
                            }
                            
                        }
//                        .padding(.top, 20)
                        
                    }
                    
                }
            }
            
        }
        .fullScreenCover(isPresented: $showingModal) {
            NewCicloView()
                .environmentObject(newCicloViewModel)
        }
    }
}

#Preview {
    HistoricoView()
        .environmentObject(CiclosListViewModel())
}
