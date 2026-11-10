import SwiftUI

/// Cores do Design System (Color Sets em Assets.xcassets/Tema, claro e escuro).
enum Tema {
    static let fundo = Color("fundo")
    static let superficie = Color("superficie")
    static let superficie2 = Color("superficie-2")
    static let borda = Color("borda")
    static let texto = Color("texto")
    static let textoFraco = Color("texto-fraco")
    static let barraDia = Color("barra-dia")
    static let marca = Color("marca")
    static let marcaBotao = Color("marca-botao")
    static let marcaTexto = Color("marca-texto")
    static let marcaFundo = Color("marca-fundo")
    static let estouro = Color("estouro")
    static let alertaTexto = Color("alerta-texto")
    static let alertaFundo = Color("alerta-fundo")
    static let alertaBorda = Color("alerta-borda")
    static let ok = Color("ok")
    static let okFundo = Color("ok-fundo")
    static let sobreCor = Color("sobre-cor")
}

enum Espaco {
    static let p: CGFloat = 8
    static let m: CGFloat = 12
    static let g: CGFloat = 16
}

enum Raio {
    static let selo: CGFloat = 6
    static let campo: CGFloat = 10
    static let lista: CGFloat = 12
    static let passagem: CGFloat = 20
}

extension Font {
    /// SF Pro Expanded: só para códigos da passagem e valor de destaque.
    static func larga(_ tamanho: CGFloat, _ peso: Font.Weight) -> Font {
        .system(size: tamanho, weight: peso).width(.expanded)
    }
}

extension Categoria {
    var cor: Color {
        switch self {
        case .ALIMENTACAO: return Color("cat-alimentacao")
        case .TRANSPORTE: return Color("cat-transporte")
        case .LAZER: return Color("cat-lazer")
        case .COMPRAS: return Color("cat-compras")
        case .OUTROS: return Color("cat-outros")
        }
    }
}

/// Dinheiro sempre em pt-BR ("R$ 1.183,00"), independente do idioma do aparelho.
nonisolated func formatarBRL(_ valor: Decimal, centavos: Bool = true) -> String {
    let casas = centavos ? 2 : 0
    let estilo = Decimal.FormatStyle.Currency(code: "BRL", locale: Locale(identifier: "pt_BR"))
        .precision(.fractionLength(casas))
    return valor.formatted(estilo)
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{202F}", with: " ")
}

/// Tema escolhido em Perfil e ajustes. Aplicado na raiz do app com
/// `.preferredColorScheme`; `automatico` segue o iPhone.
enum PreferenciaTema: String, CaseIterable, Identifiable {
    case automatico, claro, escuro

    static let chave = "temaApp"

    var id: String { rawValue }

    var nome: String {
        switch self {
        case .automatico: return "Automático"
        case .claro: return "Claro"
        case .escuro: return "Escuro"
        }
    }

    var esquema: ColorScheme? {
        switch self {
        case .automatico: return nil
        case .claro: return .light
        case .escuro: return .dark
        }
    }
}
