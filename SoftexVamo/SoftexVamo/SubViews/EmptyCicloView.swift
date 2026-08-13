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
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                
                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(AnyShapeStyle(corFundoTela))
                        .frame(maxWidth: 200, maxHeight: 200)
                        .overlay(
                            Image(systemName: "wallet.bifold")
                                .font(.system(size: 60))
                                .foregroundColor(.white)
                        )
                        .shadow(color: Color.appPurple.opacity(0.3), radius: 20, x: 0, y: 10)
                        .padding(.bottom, 8)
                    
                    Text("Comece agora!")
                        .font(Font.largeTitle.bold())
                    
                    Text("Crie seu primeiro ciclo de gastos e tenha controle total das suas finanças.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 5)
                    
                    Text("É rapido, fácil e 100% gratuito")
                        .foregroundStyle(Color("textSecondary"))
                    
                    Button(action: action) {
                        HStack {
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
                    .padding(.vertical, 8)
                    
                    HStack(spacing: 0) {
                        featureItem(
                            icon: "chart.line.uptrend.xyaxis",
                            title: "Controle Total",
                            color: Color.appPurple,
                            backgroundOpacity: 0.15
                        )
                        
                        featureItem(
                            icon: "chart.pie",
                            title: "Relatórios",
                            color: .blue,
                            backgroundOpacity: 0.1
                        )
                        
                        featureItem(
                            icon: "shield",
                            title: "Seguro",
                            color: .indigo,
                            backgroundOpacity: 0.15
                        )
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal)
                .onTapGesture {
                    action()
                }
                
                Spacer(minLength: 0)
            }
            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
        }
    }
    
    private func featureItem(icon: String, title: String, color: Color, backgroundOpacity: Double) -> some View {
        VStack(spacing: 12) {
            Circle()
                .frame(width: 56, height: 56)
                .foregroundStyle(color.opacity(backgroundOpacity))
                .overlay(
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.system(size: 20, weight: .semibold))
                )
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color("textSecondary"))
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    EmptyCicloView {
        print("Criar ciclo")
    }
}
