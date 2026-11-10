import SwiftUI

/// "R$ 450" quando o valor é inteiro, "R$ 147,70" quando tem centavos.
nonisolated func formatarBRLCurto(_ valor: Decimal) -> String {
    var bruto = valor
    var inteiro = Decimal()
    NSDecimalRound(&inteiro, &bruto, 0, .plain)
    return formatarBRL(valor, centavos: inteiro != valor)
}

/// O valor sem o "R$ " ("104,60"), como nas listas de gastos.
nonisolated func formatarValorSemSimbolo(_ valor: Decimal) -> String {
    formatarBRL(valor).replacingOccurrences(of: "R$ ", with: "")
}

/// Dinheiro em pt-BR com algarismos tabulares.
///
/// `destaque` = o valor grande da tela (SF Pro Expanded 38pt bold), um por tela.
/// Sem destaque, herda a fonte de quem usa. A cor vem de quem usa.
struct ValorMonetario: View {
    let valor: Decimal
    let destaque: Bool
    let simbolo: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var tamanhoDestaque: CGFloat = 38

    init(_ valor: Decimal, destaque: Bool = false, simbolo: Bool = true) {
        self.valor = valor
        self.destaque = destaque
        self.simbolo = simbolo
    }

    private var texto: String {
        simbolo ? formatarBRL(valor) : formatarValorSemSimbolo(valor)
    }

    var body: some View {
        Group {
            if destaque {
                Text(texto)
                    .font(.larga(tamanhoDestaque, .bold))
                    .tracking(-0.4)
                    .minimumScaleFactor(0.7)
            } else {
                Text(texto)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityLabel(formatarBRL(valor))
    }
}

#Preview("Claro") {
    VStack(alignment: .leading, spacing: 12) {
        ValorMonetario(Decimal(string: "302.30")!, destaque: true)
        ValorMonetario(Decimal(string: "12345.67")!, destaque: true)
        ValorMonetario(Decimal(string: "104.60")!, simbolo: false)
        ValorMonetario(1183)
    }
    .foregroundStyle(Tema.texto)
    .padding()
    .background(Tema.fundo)
    .preferredColorScheme(.light)
}

#Preview("Escuro") {
    VStack(alignment: .leading, spacing: 12) {
        ValorMonetario(Decimal(string: "302.30")!, destaque: true)
        ValorMonetario(Decimal(string: "12345.67")!, destaque: true)
        ValorMonetario(Decimal(string: "104.60")!, simbolo: false)
        ValorMonetario(1183)
    }
    .foregroundStyle(Tema.texto)
    .padding()
    .background(Tema.fundo)
    .preferredColorScheme(.dark)
}
