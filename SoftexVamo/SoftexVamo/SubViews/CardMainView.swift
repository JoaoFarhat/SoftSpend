//
//  CardMainView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 07/04/26.
//

import SwiftUI

struct CardMainView: View {
    @EnvironmentObject var viewModel: CiclosListViewModel
    
    @State var presentCiclo = false
    
    let corFundoTela = LinearGradient.appPurple
    
    var progresso: CGFloat {
        // Evita divisão por zero e garante que não passe de 100%
        let percent = viewModel.actualCiclo.valor_total > 0 ? viewModel.actualCiclo.gasto_total / viewModel.actualCiclo.valor_total : 0
        return CGFloat(min(max(percent, 0), 1))
    }
    
    var body: some View {
        ZStack{
            RoundedRectangle(cornerRadius: 24)
                .fill(AnyShapeStyle(corFundoTela))
                .frame(maxWidth: .infinity, maxHeight: 250)
                .shadow(radius: 10)
            
            VStack(alignment: .leading){
                HStack{
                    Text("CICLO ATUAL")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.25))
                        .cornerRadius(12)
                    Spacer()
                    Text(viewModel.actualCiclo.titulo)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.75))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.75))
                    
                }
                Spacer()
                Text("Total Gasto")
                    .foregroundStyle(Color.white.opacity(0.75))
                    .font(.system(size: 16, weight: .bold))
                
                Text(viewModel.actualCiclo.gasto_total, format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")))
                    .font(.system(size: 36, weight: .heavy))

                Spacer()
                HStack{
                    Text("Limite: \(viewModel.actualCiclo.valor_total, format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")))")
                        .foregroundStyle(Color.white.opacity(0.75))
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("Dísponivel: \(viewModel.actualCiclo.valor_total - viewModel.actualCiclo.gasto_total, format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")))")
                        .foregroundStyle(Color.white.opacity(0.75))
                        .font(.system(size: 13, weight: .bold))
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: 0.22, green: 0.15, blue: 0.54))
                            .frame(height: 10)
                        
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                AnyShapeStyle(Color(red: 0.4, green: 0.9, blue: 0.5)))
                            .frame(width: geometry.size.width * progresso, height: 10)
                            .animation(.spring(), value: viewModel.actualCiclo.gasto_total)
                    }
                }
                .frame(height: 10)
                
                
                
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: 250)
            
        }
        .skeleton(RoundedRectangle(cornerRadius: 24), isLoading: viewModel.isLoading)
        .foregroundStyle(.white)
        .padding(.horizontal)
        .onTapGesture {
            presentCiclo = true
            viewModel.selectedTab = 1
        }
    }
}

#Preview {
    CardMainView()
        .environmentObject(CiclosListViewModel())
}
