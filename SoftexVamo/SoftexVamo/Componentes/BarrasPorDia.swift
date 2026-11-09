import SwiftUI

/// "21 de julho", sempre em português.
nonisolated func diaPorExtenso(_ data: Date, fuso: TimeZone = .current) -> String {
    var estilo = Date.FormatStyle(locale: Locale(identifier: "pt_BR")).day().month(.wide)
    estilo.timeZone = fuso
    return data.formatted(estilo)
}

/// O que o VoiceOver lê numa barra: "21 de julho, passou R$ 38".
func textoAcessivelBarra(_ dia: DiaResumo, fuso: TimeZone = .current) -> String {
    let data = diaPorExtenso(dia.data, fuso: fuso)
    let prefixo = dia.ehHoje ? "Hoje, \(data)" : data
    if dia.futuro { return "\(prefixo), ainda não chegou" }
    if dia.estourou { return "\(prefixo), passou \(formatarBRLCurto(dia.passou))" }
    return "\(prefixo), gastou \(formatarBRLCurto(dia.gasto))"
}

/// Uma barra por dia da viagem; altura = gasto / diária (teto em 125%).
/// Hoje em `marca`, dia que passou em `estouro`, normal em `barraDia`, futuro tracejado.
struct BarrasPorDia: View {
    let dias: [DiaResumo]
    let aoTocar: (DiaResumo) -> Void

    /// Altura que representa 100% da diária.
    @ScaledMetric(relativeTo: .body) private var alturaDiaria: CGFloat = 50

    private var calendario: Calendar { .current }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(dias) { dia in
                Button { aoTocar(dia) } label: { coluna(dia) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(textoAcessivelBarra(dia))
            }
        }
    }

    private func coluna(_ dia: DiaResumo) -> some View {
        VStack(spacing: 6) {
            barra(dia)
                .frame(height: alturaDiaria * 1.25, alignment: .bottom)
            Text("\(calendario.component(.day, from: dia.data))")
                .font(.caption2.weight(dia.ehHoje ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(corRotulo(dia))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func barra(_ dia: DiaResumo) -> some View {
        let forma = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if dia.futuro {
            forma
                .strokeBorder(Tema.barraDia, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(height: alturaDiaria * 0.9)
        } else {
            // Um traço mínimo para o dia sem gasto continuar visível.
            forma
                .fill(corBarra(dia))
                .frame(height: max(alturaDiaria * dia.proporcao, 3))
        }
    }

    private func corBarra(_ dia: DiaResumo) -> Color {
        if dia.ehHoje { return Tema.marca }
        if dia.estourou { return Tema.estouro }
        return Tema.barraDia
    }

    private func corRotulo(_ dia: DiaResumo) -> Color {
        if dia.ehHoje { return Tema.marcaTexto }
        if dia.estourou && !dia.futuro { return Tema.estouro }
        return Tema.textoFraco
    }
}

#if DEBUG
private struct BarrasExemplo: View {
    let resumo = DadosExemplo.compartilhado.resumo()

    var body: some View {
        BarrasPorDia(dias: resumo.dias) { _ in }
            .padding()
            .background(Tema.superficie)
            .padding()
            .background(Tema.fundo)
    }
}

#Preview("Claro") { BarrasExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { BarrasExemplo().preferredColorScheme(.dark) }
#endif
