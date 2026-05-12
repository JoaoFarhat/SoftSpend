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
    
    let corFundoTela = LinearGradient.appPurple
    
    var progresso: CGFloat {
        let percent = ciclo.valor_total > 0 ? ciclo.gasto_total / ciclo.valor_total : 0
        return CGFloat(min(max(percent, 0), 1))
    }
    
    private var isAtual: Bool {
        viewModel.actualCiclo.backendId == ciclo.backendId
    }
    
    var body: some View {
            ZStack{
                RoundedRectangle(cornerRadius: 24)
                    .fill(isAtual ?
                          AnyShapeStyle(corFundoTela) :
                            AnyShapeStyle(Color("cardBackground")))
                    .id(viewModel.actualCiclo.id)
                    .frame(maxWidth: .infinity, maxHeight: 180)
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
                        
                        Image(systemName: "chevron.right")
                            .foregroundStyle(isAtual ? Color.white.opacity(0.75) : Color("textSecondary"))
                            .font(.system(size: 14))
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
                .frame(maxWidth: .infinity, maxHeight: 180)
                
            }
            .padding(.horizontal)
            .onTapGesture {
                viewModel.actualCiclo = ciclo
                presentCiclo = true
                viewModel.selectedTab = 0
            }
        //
        .foregroundColor(isAtual ? .white : Color("textPrimary"))
        .padding(.bottom, 10)
        //        .ignoresSafeArea()
        
    }
}

#Preview {
    CardCiclosView(ciclo: CicloSoftex.example)
        .environmentObject(CiclosListViewModel())
}
