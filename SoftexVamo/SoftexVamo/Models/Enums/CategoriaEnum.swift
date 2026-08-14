//
//  CategoriaEnum.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//

import Foundation
import SwiftUI

enum Categoria: String, Codable, CaseIterable, Identifiable {
    case ALIMENTACAO = "ALIMENTACAO"
    case TRANSPORTE = "TRANSPORTE"
    case LAZER = "LAZER"
    case COMPRAS = "COMPRAS"
    case OUTROS = "OUTROS"
    
    
    var id : String {
        self.rawValue
    }
    
    var localizedName: String {
        switch self {
        case .ALIMENTACAO: return "Alimentação"
        case .TRANSPORTE: return "Transporte"
        case .LAZER: return "Lazer"
        case .COMPRAS: return "Compras"
        case .OUTROS: return "Outros"
            
        }
    }
    
    var systemImageName: String {
        switch self {
        case .ALIMENTACAO: return "fork.knife"
        case .TRANSPORTE: return "car.fill"
        case .LAZER: return "gamecontroller.fill"
        case .COMPRAS: return "bag.fill"
        case .OUTROS: return "ellipsis.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .ALIMENTACAO: return Color(red: 1.0, green: 0.45, blue: 0.1)
        case .TRANSPORTE: return Color(red: 0.35, green: 0.65, blue: 0.95)
        case .LAZER: return Color(red: 0.65, green: 0.5, blue: 0.95)
        case .COMPRAS: return Color(red: 0.9, green: 0.25, blue: 0.4)
        case .OUTROS: return Color(red: 0.45, green: 0.75, blue: 0.65)
        }
    }
}

