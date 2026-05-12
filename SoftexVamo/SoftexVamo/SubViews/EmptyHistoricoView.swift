//
//  EmptyHistoricoView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 02/05/26.
//

import SwiftUI

struct EmptyHistoricoView: View {
    let action: () -> Void
    
    let corFundoTela = LinearGradient.appPurple
    
    var body: some View {
        VStack{
            
            Circle()
                .fill(AnyShapeStyle(corFundoTela))
                .frame(maxWidth: 150, maxHeight: 150)
                .overlay(
                    Image(systemName: "clock")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                )
                .shadow(color: Color.appPurple.opacity(0.3), radius: 20, x: 0, y: 10)
                .padding()
            
            Text("Nenhum ciclo ainda")
                .font(Font.title.bold())
                .padding(.top)
            
            Text("Seu histórico aparecerá aqui assim que você criar seu primeiro ciclo")
                .foregroundStyle(Color("textSecondary"))
                .multilineTextAlignment(.center)
                .padding(.vertical, 5)
            
            Button(action: action) {
                HStack{
                    Image(systemName: "plus")
                    
                    Text("Criar Ciclo")
                    
                }
                .foregroundStyle(Color.white)
                .bold()
                .font(.title3)
                .frame(width: 200, height: 60)
                .background(
                    LinearGradient(
                        colors: [.appPurple, .appPurpleDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: Color.appPurpleDark.opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .padding()
            
        }
        .padding()
    }
}

#Preview {
    EmptyHistoricoView{
        print("Criar ciclo")
    }
}
