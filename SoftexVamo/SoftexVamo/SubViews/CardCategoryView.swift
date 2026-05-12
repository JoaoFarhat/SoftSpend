//
//  CardCategoryView.swift
//  SoftSpend
//
//  Created by Gabriel fontes on 07/05/26.
//

import SwiftUI

struct CardCategoryView: View {
    let percent: Float
    let category: String
    let systemImage: String
    let totalGasto: Float
    
    let corFundoTela = LinearGradient.appPurple
    
    var progresso: CGFloat {
        return CGFloat(min(max(percent, 0), 1))
    }
    
    var body: some View {
            ZStack{
                RoundedRectangle(cornerRadius: 24)
                    .fill(AnyShapeStyle(corFundoTela))
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .shadow(radius: 10)
                
                VStack{
                    HStack{
                        ZStack {
                            Image(systemName: systemImage)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(14)
                        .padding(.trailing, 10)
                        VStack(alignment: .leading){
                            Text(category)
                                .font(.system(size: 20, weight: .bold))
                            Text(percent, format: .percent.precision(.fractionLength(1)))
                                .foregroundStyle(Color.white.opacity(0.75))
                                .font(.system(size: 12, weight: .bold))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color.white.opacity(0.75))
                            .font(.system(size: 14))
                    }
                    
                    HStack{
                        Text("Total Gasto")
                            .foregroundStyle(Color.white.opacity(0.75))
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text("\(totalGasto, format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")))")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .padding(.top, 10)
                    
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 10)
                            
                            RoundedRectangle(cornerRadius: 10)
                                .fill(AnyShapeStyle(Color(red: 0.4, green: 0.9, blue: 0.5)))
                                .frame(width: geometry.size.width * progresso, height: 10)
                                .animation(.spring(), value: totalGasto)
                        }
                    }
                    .frame(height: 10)
                    
                    
                    
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: 180)
                
            }
            .padding(.horizontal)
        .foregroundColor(.white)
        .padding(.bottom, 10)
    }
}
