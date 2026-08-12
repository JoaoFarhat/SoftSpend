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
    let editAction: (GastosDia, DiaSoftex) -> Void
    let deleteAction: (Int, Int) -> Void
    
    var body: some View {
        VStack{
                VStack(alignment: .leading) {
                    
                    HStack{
                        Text("Gastos registrados")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color("textPrimary"))
                        
                        Spacer()
                    }
                    HStack{
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            TextField("Buscar gasto, loja, categoria...", text: $gastosViewModel.searchGastoText)
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
                                    VStack(spacing: 0) {
                                        ForEach(Array(dia.gastos.enumerated()), id: \.element.id) { index, gasto in
                                            createGastoCell(gasto: gasto, dia: dia)
                                            
                                            if index < dia.gastos.count - 1 {
                                                Divider()
                                                    .background(Color("textPrimary").opacity(0.08))
                                                    .padding(.horizontal, 16)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    .background(Color("cinza"))
                                    .cornerRadius(18)
                                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                                    .skeleton(isLoading: ciclosViewModel.isLoading)
                                }
                                
                            }
                        }
                    }
                }
                
                
            }
            .padding(10)
            .padding(.bottom, 80)
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
    
    @ViewBuilder func createGastoCell(gasto: GastosDia, dia: DiaSoftex) -> some View {
        HStack(spacing: 14) {
            Image(systemName: gasto.categoria.systemImageName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(gasto.categoria.color)
                .cornerRadius(12)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(gasto.titulo)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color("textPrimary"))
                
                Text(gasto.categoria.localizedName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(gasto.categoria.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(gasto.categoria.color.opacity(0.15))
                    .cornerRadius(6)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Text(gasto.valor, format: .currency(code: "BRL"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color("textPrimary"))
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color("textSecondary"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            editAction(gasto, dia)
        }
    }
}

#Preview {
    CicloGastosView() {
        print("ok")
    } editAction: { _, _ in
        print("edit")
    } deleteAction: { _,_ in
        print("")
    }
    .environmentObject(GastosViewModel(ciclo: CicloSoftex.example))
    .environmentObject(CiclosViewModel())
}


