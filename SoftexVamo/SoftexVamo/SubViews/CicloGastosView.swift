//
//  CicloGastosView.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import Combine

struct CicloGastosView: View {
    @EnvironmentObject var gastosViewModel: GastosViewModel
    @EnvironmentObject var ciclosViewModel: CiclosViewModel
    
    let action: () -> Void
    let deleteAction: (Int, Int) -> Void
    
    func removerGastoEspecifico(dia: DiaSoftex, index: Int) {
        let indexSet = IndexSet(integer: index)
        
        guard let gastoID = gastosViewModel.deleteGasto(dia: dia, offsets: indexSet) else { return }
        
        deleteAction(dia.id, gastoID)
    }
    
    var body: some View {
        ScrollView(showsIndicators: false){
            VStack{
                VStack(alignment: .leading) {
                    
                    HStack{
                        Text("Gastos Registrados")
                            .font(.system(size: 20, weight: .bold))
                        
                        Spacer()
                    }
                    HStack{
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            TextField("Procurar gasto...", text: $gastosViewModel.searchGastoText)
                                .textFieldStyle(PlainTextFieldStyle())
                        }
                        .padding(12)
                        .background(Color("cinza"))
                        .cornerRadius(15)
                        .shadow(
                            color: Color.black.opacity(0.1),
                            radius: 10,
                        )
                        .overlay{
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(.gray, lineWidth: 0.2)
                        }
                        
                        
                        Menu {
                            Button {
                                gastosViewModel.categoriaFiltro = nil
                            } label: {
                                HStack {
                                    Text("Todas as categorias")
                                    if gastosViewModel.categoriaFiltro == nil {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            
                            Divider()
                            
                            ForEach(Categoria.allCases) { categoria in
                                Button {
                                    gastosViewModel.categoriaFiltro = categoria
                                } label: {
                                    HStack {
                                        Image(systemName: categoria.systemImageName)
                                        Text(categoria.localizedName)
                                        if gastosViewModel.categoriaFiltro == categoria {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            ZStack {
                                Image(systemName: "line.3.horizontal.decrease")
                                    .foregroundStyle(gastosViewModel.categoriaFiltro != nil ? Color.white : Color("textPrimary"))
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, 12)
                                    .background(gastosViewModel.categoriaFiltro != nil ? Color.appPurple : Color("cinza"))
                                    .cornerRadius(15)
                                    .shadow(color: Color.black.opacity(0.1), radius: 10)
                                    .overlay{
                                        RoundedRectangle(cornerRadius: 15)
                                            .stroke(.gray, lineWidth: 0.2)
                                    }
                            }
                        }
                    }
                }
                if ciclosViewModel.atualCiclo.dias?.allSatisfy({ $0.gastos.isEmpty }) ?? true {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: "receipt")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.appPurple.opacity(0.5))
                        
                        Text("Nenhum gasto registrado")
                            .font(.system(size: 20, weight: .bold))
                        
                        Text("Toque no + para adicionar seu primeiro gasto")
                            .font(.system(size: 14))
                            .foregroundStyle(Color("textSecondary"))
                            .multilineTextAlignment(.center)
                    }
                    //                    .frame(width: .infinity)
                    .padding(60)
                } else {
                    if gastosViewModel.secoesExibidas.isEmpty && !gastosViewModel.searchGastoText.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.appPurple.opacity(0.5))
                            
                            Text("Nenhum resultado para \"\(gastosViewModel.searchGastoText)\"")
                                .font(.system(size: 16, weight: .bold))
                            
                            Text("Tente buscar por outro termo")
                                .font(.system(size: 14))
                                .foregroundStyle(Color("textSecondary"))
                        }
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(gastosViewModel.secoesExibidas.reversed()) { dia in
                            if(dia.gastos.count != 0){
                                Section(header: createSectionHeader(dia: dia)) {
                                    ZStack{
                                        RoundedRectangle(cornerRadius: 8)
                                            .foregroundStyle(Color("cinza"))
                                        
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        
                                            .shadow(radius: 2)
                                        
                                        VStack{
                                            ForEach(Array(dia.gastos.enumerated()), id: \.element.id) { index, gasto in
                                                createGastoCell(gasto: gasto) {
                                                    removerGastoEspecifico(dia: dia, index: index)
                                                }
                                                .padding(.horizontal)
                                                .padding(.vertical, 8)
                                                
                                                if index < dia.gastos.count - 1 {
                                                    Divider()
                                                        .background(Color.gray.opacity(0.2))
                                                        .padding(.horizontal, -10)
                                                }
                                            }
                                        }
                                        .skeleton(isLoading: ciclosViewModel.isLoading)
                                        
                                        //                            .padding()
                                    }
                                    //                            .background(Color("cinza"))
                                    //                            .background(Color.cardBackground)
                                }
                                
                            }
                        }
                    }
                }
                
                
            }
            .padding(10)
            .padding(.bottom, 80)
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    @ViewBuilder func createSectionHeader(dia: DiaSoftex) -> some View {
        HStack {
            if Calendar.current.isDateInToday(dia.data) {
                Text("HOJE")
                    .frame(width: 90)
                    .skeleton(isLoading: ciclosViewModel.isLoading)
                
                
            } else if Calendar.current.isDateInYesterday(dia.data) {
                Text("ONTEM")
                    .frame(width: 90)
                    .skeleton(isLoading: ciclosViewModel.isLoading)
                
            } else {
                Text(gastosViewModel.dateToString(date: dia.data))
                    .frame(width: 90)
                    .skeleton(isLoading: ciclosViewModel.isLoading)
            }
            
            Spacer()
        }
        .padding(.top)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Color("textSecondary"))
        
    }
    
    @ViewBuilder func createGastoCell(gasto: GastosDia, onDelete: @escaping () -> Void) -> some View {
        HStack {
            
            Image(systemName: gasto.categoria.systemImageName)
                .font(.system(size: 25, weight: .bold))
                .frame(width: 30, height: 30)
                .padding()
                .foregroundStyle(Color.white)
                .background(gasto.categoria.color)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            
            
            VStack(alignment: .leading){
                Text(gasto.titulo)
                    .font(.system(size: 18, weight: .bold))
                    .padding(.bottom, 10)
                
                Text(gasto.categoria.localizedName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color("textSecondary").opacity(0.7))
            }
            .padding(6)
            
            Spacer()
            VStack(alignment:.trailing){
                Text(gasto.valor, format: .currency(code: "BRL"))
                    .font(.system(size: 18, weight: .bold))
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .light))
                    
                        .frame(width: 20, height: 20)
                        .padding(2)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(10)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color("cinza"))
        
        .frame(maxWidth: .infinity, maxHeight: 70)
        //
        
        
    }
}

#Preview {
    CicloGastosView() {
        print("ok")
    } deleteAction: { _,_ in
        print("")
    }
    .environmentObject(GastosViewModel(ciclo: CicloSoftex.example))
    .environmentObject(CiclosViewModel())
}


