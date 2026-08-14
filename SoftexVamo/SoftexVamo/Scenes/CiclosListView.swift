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
    @StateObject var gastosViewModel = GastosViewModel(dias: [])
    @State private var showMenu = false
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    let corFundoTela = LinearGradient.appPurple
    
    @State var addNewGastoSheet: Bool = false
    @State private var gastoToEdit: GastosDia? = nil
    @State private var diaDoGasto: DiaSoftex? = nil
    @State var addNewCicloSheet: Bool = false
    
    private var saudacao: String {
        let nome = authService.currentUser?.nome ?? ""
        let saudacao: String
        let hora = Calendar.current.component(.hour, from: Date())
        
        switch hora {
        case 5..<12:
            saudacao = "Bom dia"
        case 12..<18:
            saudacao = "Boa tarde"
        default:
            saudacao = "Boa noite"
        }
        
        return nome.isEmpty ? saudacao : "\(saudacao), \(nome)"
    }
    
    private var infoPeriodo: String {
        let dias = viewModel.atualCiclo.dias?.count ?? 0
        let hoje = Calendar.current.startOfDay(for: Date())
        let diaAtual = viewModel.atualCiclo.dias?.firstIndex(where: {
            Calendar.current.isDate(Calendar.current.startOfDay(for: $0.data), inSameDayAs: hoje)
        }).map { $0 + 1 }
        
        if let diaAtual = diaAtual, dias > 0 {
            return "\(viewModel.atualCiclo.periodo) · Dia \(diaAtual) de \(dias)"
        }
        return viewModel.atualCiclo.periodo
    }
    
    private var resumoDiaSection: some View {
        let hoje = Calendar.current.startOfDay(for: Date())
        let diaHoje = viewModel.atualCiclo.dias?.first(where: {
            Calendar.current.isDate(Calendar.current.startOfDay(for: $0.data), inSameDayAs: hoje)
        })
        let gastoHoje = diaHoje?.gastos.reduce(0) { $0 + $1.valor } ?? 0
        let orcamentoDiario = viewModel.atualCiclo.diaria
        let restanteHoje = orcamentoDiario - gastoHoje
        
        return HStack(spacing: 8) {
            resumoItem(icon: "wallet.bifold", title: "Orçamento diário", value: orcamentoDiario, color: .appPurple)
            resumoItem(icon: "arrow.down", title: "Gasto hoje", value: gastoHoje, color: .green)
            resumoItem(icon: "chart.line.uptrend.xyaxis", title: "Restam hoje", value: restanteHoje, color: .appPurple)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }
    
    private func resumoItem(icon: String, title: String, value: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.15))
                    .cornerRadius(8)
                Spacer()
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color("textSecondary"))
            Text(value, format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color("textPrimary"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("cardBackground"))
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color("textPrimary").opacity(0.08), lineWidth: 1)
        )
    }
    
    private var isEmpty: Bool {
        viewModel.allCiclos.isEmpty || viewModel.allCiclos.allSatisfy({ $0.backendId == nil })
    }

    private func header(showTitle: Bool = true, isLoading: Bool = false) -> some View {
        HStack(alignment: showTitle ? .center : .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(saudacao)
                    .foregroundStyle(Color("textSecondary"))
                    .font(.system(size: 14))
                    .skeleton(isLoading: isLoading)
                if showTitle {
                    Text(viewModel.atualCiclo.titulo.isEmpty ? "Viagem" : viewModel.atualCiclo.titulo)
                        .bold()
                        .font(.title)
                        .skeleton(isLoading: isLoading)
                    Text(infoPeriodo)
                        .foregroundStyle(Color("textSecondary"))
                        .font(.system(size: 13))
                        .skeleton(isLoading: isLoading)
                }
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

        }.padding(.horizontal, 10)
    }

    var body: some View {
        
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isLoading || !isEmpty {
                ScrollView() {
                    header(isLoading: viewModel.isLoading)
                    
                    if viewModel.isLoading {
                        CardMainView()
                            .skeleton(RoundedRectangle(cornerRadius: 22), isLoading: viewModel.isLoading)
                        
                        CicloGastosView() {
                            addNewGastoSheet.toggle()
                        } editAction: { gasto, dia in
                            gastoToEdit = gasto
                            diaDoGasto = dia
                            addNewGastoSheet.toggle()
                        } deleteAction: { diaId, gastoID in
                            Task { try await viewModel.deleteGasto(gastoID: gastoID) }
                        }
                        .id(viewModel.atualCiclo.id)
                        .environmentObject(gastosViewModel)
                    } else {
                        CardMainView()
                        
                        resumoDiaSection
                        
                        CicloGastosView() {
                            addNewGastoSheet.toggle()
                        } editAction: { gasto, dia in
                            gastoToEdit = gasto
                            diaDoGasto = dia
                            addNewGastoSheet.toggle()
                        } deleteAction: { diaId, gastoID in
                            Task { try await viewModel.deleteGasto(gastoID: gastoID) }
                        }
                        .id(viewModel.atualCiclo.id)
                        .environmentObject(gastosViewModel)
                    }
                }
            } else {
                header(showTitle: false)
                EmptyCicloView {
                    addNewCicloSheet.toggle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.bottom, viewModel.isLoading || !isEmpty ? 30 : 100)
        .task {
            await viewModel.fetchCiclosResumo()
        }
        .onChange(of: viewModel.atualCiclo.dias) { _, newDias in
            gastosViewModel.dias = newDias ?? []
        }
        .background(.backgroundCor)
        .overlay(alignment: .topTrailing) {
            if showMenu {
                MenuView(showMenu: $showMenu)
                    .environmentObject(viewModel)
                    .offset(x: -16, y: 70)
            }
        }
        .fullScreenCover(isPresented: $addNewGastoSheet, onDismiss: {
            gastoToEdit = nil
            diaDoGasto = nil
        }) {
            AddNewGastoSheetView(
                dias: viewModel.atualCiclo.dias ?? [],
                gastoToEdit: gastoToEdit,
                diaDoGasto: diaDoGasto
            )
            .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: $addNewCicloSheet) {
            NewCicloView()
        }
    }
}

#Preview {
    let viewModel = CiclosViewModel()
    var ciclo = CicloSoftex.example
    ciclo.backendId = 1
    viewModel.atualCiclo = ciclo
    viewModel.allCiclos = [ciclo]
    viewModel.isLoading = false

    return CiclosListView()
        .environmentObject(viewModel)
}
