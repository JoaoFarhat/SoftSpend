import SwiftUI

/// Pílula que escurece um pouco ao ser tocada.
private struct EstiloPilula: ButtonStyle {
    let fundo: Color
    let texto: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(texto)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(fundo, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Botão principal: pílula em `Tema.marcaBotao`, um por tela.
struct BotaoPrincipal: View {
    let titulo: String
    let acao: () -> Void

    init(_ titulo: String, acao: @escaping () -> Void) {
        self.titulo = titulo
        self.acao = acao
    }

    var body: some View {
        Button(titulo, action: acao)
            .buttonStyle(EstiloPilula(fundo: Tema.marcaBotao, texto: Tema.sobreCor))
    }
}

/// Botão secundário: pílula em `Tema.superficie`. Com `simbolo`, vira o botão
/// redondo só com ícone (ex.: "plus" para lançar sem foto).
struct BotaoSecundario: View {
    private enum Conteudo {
        case titulo(String)
        case simbolo(String, rotulo: String)
    }

    private let conteudo: Conteudo
    private let acao: () -> Void
    @ScaledMetric(relativeTo: .body) private var lado: CGFloat = 52

    init(_ titulo: String, acao: @escaping () -> Void) {
        self.conteudo = .titulo(titulo)
        self.acao = acao
    }

    init(simbolo: String, rotulo: String, acao: @escaping () -> Void) {
        self.conteudo = .simbolo(simbolo, rotulo: rotulo)
        self.acao = acao
    }

    var body: some View {
        switch conteudo {
        case .titulo(let titulo):
            Button(titulo, action: acao)
                .buttonStyle(EstiloPilula(fundo: Tema.superficie, texto: Tema.texto))
        case .simbolo(let simbolo, let rotulo):
            Button(action: acao) {
                Image(systemName: simbolo)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Tema.texto)
                    .frame(width: lado, height: lado)
                    .background(Tema.superficie, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rotulo)
        }
    }
}

private struct BotoesExemplo: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                BotaoPrincipal("Fotografar comprovante") {}
                BotaoSecundario(simbolo: "plus", rotulo: "Lançar sem foto") {}
            }
            BotaoPrincipal("Salvar gasto") {}
            BotaoSecundario("Editar viagem") {}
        }
        .padding()
        .background(Tema.fundo)
    }
}

#Preview("Claro") { BotoesExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { BotoesExemplo().preferredColorScheme(.dark) }
