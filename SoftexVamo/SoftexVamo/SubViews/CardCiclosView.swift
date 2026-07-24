//
//  CardCiclosView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 06/04/26.
//

import SwiftUI

struct CardCiclosView: View {
    
    @EnvironmentObject var viewModel: CiclosListViewModel
    
    let ciclo : CicloSoftex
    
    @State var presentCiclo = false
    @State private var sheetDetent: PresentationDetent = .height(250)
    
    let corFundoTela = LinearGradient.appPurple
    
    var progresso: CGFloat {
        let percent = ciclo.valor_total > 0 ? ciclo.gasto_total / ciclo.valor_total : 0
        return CGFloat(min(max(percent, 0), 1))
    }
    
    private var isAtual: Bool {
        viewModel.atualCiclo.backendId == ciclo.backendId
    }
    
    @State var isPresented: Bool = false
    
    var body: some View {
        ZStack{
            RoundedRectangle(cornerRadius: 24)
                .fill(isAtual ?
                      AnyShapeStyle(corFundoTela) :
                        AnyShapeStyle(Color("cardBackground")))
                .id(viewModel.atualCiclo.id)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .shadow(radius: 10)
            
            VStack{
                HStack{
                    ZStack {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isAtual ? .white : Color.appPurple)
                    }
                    .frame(width: 40, height: 40)
                    .background(isAtual ? Color.white.opacity(0.15) : Color.appPurple.opacity(0.15))
                    .cornerRadius(14)
                    .padding(.trailing, 10)
                    VStack(alignment: .leading){
                        Text(ciclo.titulo)
                            .font(.system(size: 20, weight: .bold))
                        Text(ciclo.periodo)
                            .foregroundStyle(isAtual ? Color.white.opacity(0.75) : Color("textSecondary"))
                            .font(.system(size: 12, weight: .bold))
                    }
                    
                    Spacer()
                    
                    ZStack{
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isAtual ? .white : Color.appPurple)
                    }
                    .frame(width: 40, height: 40)
                    .background(isAtual ? Color.white.opacity(0.1) : Color.appPurple.opacity(0.1))
                    .cornerRadius(14)
                    .offset(y: -10)
                    .onTapGesture {
                        isPresented = true
                    }
                    
                }
                
                
                HStack{
                    Text("Total Gasto")
                        .foregroundStyle(isAtual ? Color.white.opacity(0.75) : Color("textSecondary"))
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text("\(ciclo.gasto_total, format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")))")
                        .font(.system(size: 20, weight: .bold))
                }
                .padding(.top, 10)
                
                //
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isAtual ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                            .frame(height: 10)
                        
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isAtual ?
                                  AnyShapeStyle(Color(red: 0.4, green: 0.9, blue: 0.5)) : AnyShapeStyle(Color.appPurple))
                            .frame(width: geometry.size.width * progresso, height: 10)
                            .animation(.spring(), value: ciclo.gasto_total)
                    }
                }
                .frame(height: 10)
                
                
                
            }
            .padding()
            .frame(maxWidth: .infinity)
            
        }
        .padding(.horizontal)
        .onTapGesture {
            viewModel.atualCiclo = ciclo
            presentCiclo = true
            viewModel.selectedTab = 0
        }
        //
        .foregroundColor(isAtual ? .white : Color("textPrimary"))
        .padding(.bottom, 10)
        //        .ignoresSafeArea()
        .sheet(isPresented: $isPresented){
            SheetView(deleteAction: {
                guard let cicloId = ciclo.backendId else { return }
                Task {
                    do {
                        try await viewModel.deleteCiclo(cicloId: cicloId)
                    } catch {
                        print("Erro ao excluir ciclo:", error)
                    }
                }
            }, ciclo: ciclo, sheetDetent: $sheetDetent)
            .presentationDetents([.height(250), .large], selection: $sheetDetent)
        }
    }
}

struct SheetView : View {
    
    let deleteAction: () -> Void
    
    @Environment(\.dismiss) var dismiss
    
    let ciclo : CicloSoftex
    
    @Binding var sheetDetent: PresentationDetent
    
    @State private var showEditView = false
    @State var confirmed: Bool = false
    @State private var acaoConfirmada = false
    
    var body: some View {
        if showEditView {
            NewCicloView(ciclo: ciclo, onBack: {
                sheetDetent = .height(250)
                showEditView = false
            })
        } else {
            VStack(alignment: .leading){
                Text(ciclo.titulo)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 20)
                
                Button(action: {
                    sheetDetent = .large
                    showEditView = true
                }) {
                    HStack{
                        ZStack {
                            Image(systemName: "pencil")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.appPurple)
                        }
                        .frame(width: 40, height: 40)
                        .background(Color.appPurple.opacity(0.15))
                        .cornerRadius(14)
                        .padding(.trailing, 10)
                        
                        VStack(alignment: .leading){
                            Text("Editar Ciclo")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                            
                            Text("Alterar nome, datas e orçamento")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                }
                
                Spacer()
                    .frame(height: 20)
                
                Button(action: {
                    confirmed = true
                }) {
                    HStack{
                        ZStack {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.red)
                        }
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(14)
                        .padding(.trailing, 10)
                        
                        VStack(alignment: .leading){
                            Text("Excluir Ciclo")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.red)
                            
                            Text("Remove o ciclo e todos os gastos associados")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                }
                .alert("Atenção", isPresented: $confirmed) {
                    Button("Cancelar", role: .cancel) { }
                    Button("Deletar", role: .destructive) {
                        deleteAction()
                        dismiss()
                    }
                } message: {
                    Text("Tem certeza que deseja apagar este item? Esta ação não pode ser desfeita.")
                }
                
                Spacer()
                    .frame(height: 20)
                
                Button(action: {
                    dismiss()
                }) {
                    HStack{
                        Image(systemName: "xmark")
                        Text("Cancelar")
                    }
                    .foregroundStyle(Color.secondary)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary, lineWidth: 1)
                    )
                    .padding(.horizontal, 10)
                    
                    
                    
                }
                
            }
            .padding()
        }
    }
}

//#Preview {
//    SheetView(ciclo: CicloSoftex.example)
//}

#Preview {
    CardCiclosView(ciclo: CicloSoftex.example)
        .environmentObject(CiclosListViewModel())
}
