//
//  TabView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI

struct MainView: View {
    
    @EnvironmentObject var viewModel: CiclosListViewModel
    let newCicloViewModel = NewCicloViewModel()
    @State var sheetview = false
    @State private var isExpanded = true

    
    var canAddGasto: Bool {
        viewModel.actualCiclo.backendId != nil
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if viewModel.selectedTab == 0 {
                    CiclosListView()
                } else {
                    HistoricoView()
                }
            }
            .environmentObject(viewModel)
            
            HStack {
                Button(action: {
                    viewModel.selectedTab = 0
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: viewModel.selectedTab == 0 ? "house.fill" : "house")
                            .font(.system(size: 22))
                        Text("Início")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(viewModel.selectedTab == 0 ? .appPurple : .gray)
                }
                .frame(maxWidth: .infinity)
                
                Button(action: {
                    if canAddGasto {
                        sheetview.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundColor(.white)
                        if isExpanded {
                            Text("Adicionar gasto")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, isExpanded ? 20 : 17)
                    .frame(height: 64)
                    .fixedSize()
                    .background(
                        Capsule()
                            .fill(canAddGasto ? .appPurple : Color.gray.opacity(0.5))
                            .shadow(color: (canAddGasto ? Color.appPurple : Color.gray).opacity(0.4), radius: 10, x: 0, y: 5)
                    )
                }
                .zIndex(1)
                .disabled(!canAddGasto)
                .fullScreenCover(isPresented: $sheetview){
                    AddNewGastoSheetView(dias: viewModel.actualCiclo.dias ?? [])
                        .environmentObject(viewModel)
                }
                .offset(y: -24)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                            isExpanded = false
                        }
                    }
                }

                
                
                Button(action: {
                    viewModel.selectedTab = 1
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 22))
                        Text("Histórico")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(viewModel.selectedTab == 1 ? .appPurple : .gray)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(Color("surfaceBackground"))
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: -5)
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }
}

#Preview {
        MainView()
            .environmentObject(CiclosListViewModel())
}
