//
//  EmptyCicloCardView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 02/05/26.
//

import SwiftUI

struct EmptyCicloView: View {
    let action: () -> Void
    
    let corFundoTela = LinearGradient.appPurple
    
    var body: some View {
        VStack{
            RoundedRectangle(cornerRadius: 24)
                .fill(AnyShapeStyle(corFundoTela))
                .frame(maxWidth: 200, maxHeight: 200)
                .overlay(
                    Image(systemName: "wallet.bifold")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                )
                .shadow(color: Color.appPurple.opacity(0.3), radius: 20, x: 0, y: 10)
                .padding()
            
            Text("Comece agora!")
                .font(Font.largeTitle.bold())
            
            Text("Crie seu primeiro ciclo de gastos e tenha controle total das suas finanças.")
                .multilineTextAlignment(.center)
                .padding(5)
            
            Text("É rapido, fácil e 100% gratuito")
                .foregroundStyle(Color("textSecondary"))
            
            Button(action: action) {
                HStack{
                    Image(systemName: "plus")
                    
                    Text("Criar Primeiro Ciclo")
                    
                }
                .foregroundStyle(Color.white)
                .bold()
                .font(.title3)
                .frame(width: 280, height: 60)
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
            
            HStack(spacing: 0){
                
                VStack(spacing: 12){
                    Circle()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(Color.appPurple.opacity(0.15))
                        .overlay(
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundColor(Color.appPurple)
                                .font(.system(size: 20, weight: .semibold))
                        )
                    Text("Controle Total")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color("textSecondary"))
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 12){
                    Circle()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(Color.blue.opacity(0.1))
                        .overlay(
                            Image(systemName: "chart.pie")
                                .foregroundColor(.blue)
                                .font(.system(size: 20, weight: .semibold))
                        )
                    Text("Relatórios")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color("textSecondary"))
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 12){
                    Circle()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(Color.indigo.opacity(0.15))
                        .overlay(
                            Image(systemName: "shield")
                                .foregroundColor(.indigo)
                                .font(.system(size: 20, weight: .semibold))
                        )
                    Text("Seguro")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color("textSecondary"))
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            
        }
        .padding(.horizontal)
        .onTapGesture {
            action()
        }
    }
}

#Preview {
    EmptyCicloView {
        print("Criar ciclo")
    }
}
