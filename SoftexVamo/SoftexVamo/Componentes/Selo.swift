import SwiftUI

/// Selo de uma linha: categoria (neutro), pendência (alerta) ou confirmado (ok).
struct Selo: View {
    enum Estilo {
        case neutro, alerta, ok
    }

    let texto: String
    let estilo: Estilo

    init(texto: String, estilo: Estilo) {
        self.texto = texto
        self.estilo = estilo
    }

    private var corTexto: Color {
        switch estilo {
        case .neutro: return Tema.textoFraco
        case .alerta: return Tema.alertaTexto
        case .ok: return Tema.ok
        }
    }

    private var corFundo: Color {
        switch estilo {
        case .neutro: return Tema.superficie2
        case .alerta: return Tema.alertaFundo
        case .ok: return Tema.okFundo
        }
    }

    var body: some View {
        Text(texto)
            .font(.caption.weight(.medium))
            .foregroundStyle(corTexto)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(corFundo, in: RoundedRectangle(cornerRadius: Raio.selo, style: .continuous))
    }
}

private struct SelosExemplo: View {
    var body: some View {
        HStack(spacing: 8) {
            Selo(texto: "Alimentação", estilo: .neutro)
            Selo(texto: "Falta a foto", estilo: .alerta)
            Selo(texto: "Anexado", estilo: .ok)
        }
        .padding()
        .background(Tema.superficie)
    }
}

#Preview("Claro") { SelosExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { SelosExemplo().preferredColorScheme(.dark) }
