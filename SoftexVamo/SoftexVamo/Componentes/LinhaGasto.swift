import SwiftUI

/// "13:42": hora do gasto (`criadoEm`) em 24h, independente do idioma do aparelho.
nonisolated func horaCurta(_ data: Date, fuso: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = fuso
    let c = cal.dateComponents([.hour, .minute], from: data)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

/// Uma linha da lista de gastos: ícone, título, selo de apoio e valor.
///
/// O apoio segue a tela aprovada: selo neutro com a categoria, ou selo de
/// alerta "Falta a foto"; ao lado, a hora em texto fraco quando couber.
struct LinhaGasto: View {
    let gasto: GastosDia

    @ScaledMetric(relativeTo: .body) private var tamanhoIcone: CGFloat = 36

    private var faltaFoto: Bool {
        gasto.comprovanteUrl == nil && gasto.comprovanteDataCriptografado == nil
    }

    private var hora: String { horaCurta(gasto.criadoEm) }

    private var selo: Selo {
        faltaFoto
            ? Selo(texto: "Falta a foto", estilo: .alerta)
            : Selo(texto: gasto.categoria.localizedName, estilo: .neutro)
    }

    private var rotuloAcessivel: String {
        let apoio = faltaFoto
            ? "\(gasto.categoria.localizedName), \(hora), falta a foto"
            : "\(gasto.categoria.localizedName), \(hora)"
        let envio = EstadoEnvio.de(gasto).rotuloAcessivel.map { ", \($0)" } ?? ""
        return "\(gasto.titulo), \(apoio), \(formatarBRL(gasto.valor))\(envio)"
    }

    var body: some View {
        HStack(spacing: Espaco.m) {
            IconeCategoria(gasto.categoria, tamanho: tamanhoIcone)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(gasto.titulo)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Tema.texto)
                        .lineLimit(1)
                    IconeEstadoEnvio(estado: EstadoEnvio.de(gasto))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        selo
                        Text(hora)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Tema.textoFraco)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    selo
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ValorMonetario(gasto.valor, simbolo: false)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .layoutPriority(1)
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rotuloAcessivel)
    }
}

#if DEBUG
private struct LinhasExemplo: View {
    let gastos = DadosExemplo.compartilhado.gastosDeHoje

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(gastos.enumerated()), id: \.element.id) { indice, gasto in
                if indice > 0 {
                    Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, 64)
                }
                LinhaGasto(gasto: gasto)
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding()
        .frame(maxHeight: .infinity)
        .background(Tema.fundo)
    }
}

#Preview("Claro") { LinhasExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { LinhasExemplo().preferredColorScheme(.dark) }
#endif
