#if DEBUG
import SwiftUI
import SwiftData

/// Vitrine dos componentes base com a viagem de exemplo, para verificação visual.
///
/// Abre no lugar do app quando lançado com `-vitrine [inicio|estados|pecas]`:
/// `xcrun simctl launch <udid> br.com.softspend.app -vitrine estados`.
struct VitrineView: View {
    enum Pagina: String {
        case inicio, estados, pecas
    }

    static var ativa: Bool { CommandLine.arguments.contains("-vitrine") }

    static var paginaPedida: Pagina {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-vitrine"), i + 1 < args.count else { return .inicio }
        return Pagina(rawValue: args[i + 1]) ?? .inicio
    }

    var pagina: Pagina = VitrineView.paginaPedida
    private let dados = DadosExemplo.compartilhado

    var body: some View {
        Group {
            switch pagina {
            case .inicio: inicio
            case .estados: estados
            case .pecas: pecas
            }
        }
        .background(Tema.fundo.ignoresSafeArea())
        .modelContainer(dados.container)
    }

    // MARK: Início (compara com a tela 6)

    private var inicio: some View {
        let resumo = dados.resumo()
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "ticket.fill").foregroundStyle(Tema.marca)
                        Text("SoftSpend").font(.title3.weight(.bold)).foregroundStyle(Tema.texto)
                    }
                    Spacer()
                    Text("JO")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Tema.texto)
                        .frame(width: 40, height: 40)
                        .background(Tema.superficie, in: Circle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                CartaoPassagem(resumo: resumo, origem: "São Paulo", destino: dados.ciclo.titulo,
                               periodo: dados.periodo)
                    .padding(.horizontal, Espaco.g)

                AlertaPendencia(quantidade: resumo.semComprovante.count) {}
                    .padding(.horizontal, Espaco.g)
                    .padding(.top, Espaco.m)

                cabecalho("Hoje", link: "Todos os gastos")
                lista(dados.gastosDeHoje)
            }
            .padding(.bottom, 100)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Espaco.p) {
                BotaoPrincipal("Fotografar comprovante") {}
                BotaoSecundario(simbolo: "plus", rotulo: "Lançar sem foto") {}
            }
            .padding(.horizontal, Espaco.g)
            .padding(.vertical, Espaco.p)
            .background(Tema.fundo)
        }
    }

    // MARK: Estados da passagem

    private var estados: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espaco.g) {
                rotulo("Sem origem, passou da diária (hoje = 21/07)")
                CartaoPassagem(resumo: dados.resumo(hoje: dados.dia(21)), origem: nil,
                               destino: dados.ciclo.titulo, periodo: dados.periodo)
                rotulo("Antes (hoje = 15/07)")
                CartaoPassagem(resumo: dados.resumo(hoje: dados.dia(15)), origem: "São Paulo",
                               destino: dados.ciclo.titulo, periodo: dados.periodo)
                rotulo("Encerrada (hoje = 30/07)")
                CartaoPassagem(resumo: dados.resumo(hoje: dados.dia(30)), origem: "São Paulo",
                               destino: dados.ciclo.titulo, periodo: dados.periodo)
            }
            .padding(Espaco.g)
        }
    }

    // MARK: Peças soltas

    private var pecas: some View {
        let resumo = dados.resumo()
        return ScrollView {
            VStack(alignment: .leading, spacing: Espaco.g) {
                rotulo("Selos")
                HStack(spacing: Espaco.p) {
                    Selo(texto: "Alimentação", estilo: .neutro)
                    Selo(texto: "Falta a foto", estilo: .alerta)
                    Selo(texto: "Anexado", estilo: .ok)
                }
                rotulo("Ícones de categoria")
                HStack(spacing: Espaco.m) {
                    ForEach(Categoria.allCases) { IconeCategoria($0) }
                    ForEach(Categoria.allCases.prefix(2)) { IconeCategoria($0, tamanho: 40) }
                }
                rotulo("Valores")
                ValorMonetario(Decimal(string: "302.30")!, destaque: true).foregroundStyle(Tema.texto)
                HStack {
                    ValorMonetario(Decimal(string: "1183")!).foregroundStyle(Tema.texto)
                    Spacer()
                    ValorMonetario(Decimal(string: "104.60")!, simbolo: false).foregroundStyle(Tema.texto)
                }
                rotulo("Alerta")
                AlertaPendencia(quantidade: 1) {}
                rotulo("Barras sozinhas")
                BarrasPorDia(dias: resumo.dias) { _ in }
                    .padding(Espaco.g)
                    .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
                rotulo("Botões")
                BotaoPrincipal("Salvar gasto") {}
                BotaoSecundario("Editar viagem") {}
                rotulo("Todos os gastos de 22/07")
                lista(gastos(do: 22))
                    .padding(.horizontal, -Espaco.g)
            }
            .padding(Espaco.g)
        }
    }

    // MARK: Apoio

    private func gastos(do n: Int) -> [GastosDia] {
        let alvo = Calendar.current.startOfDay(for: dados.dia(n))
        let dia = (dados.ciclo.dias ?? []).first { Calendar.current.startOfDay(for: $0.data) == alvo }
        return (dia?.gastos ?? []).sorted { $0.criadoEm > $1.criadoEm }
    }

    private func rotulo(_ texto: String) -> some View {
        Text(texto).font(.footnote).foregroundStyle(Tema.textoFraco)
    }

    private func cabecalho(_ titulo: String, link: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titulo).font(.headline).foregroundStyle(Tema.texto)
            Spacer()
            Text(link).font(.subheadline).foregroundStyle(Tema.marcaTexto)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, Espaco.p)
    }

    private func lista(_ gastos: [GastosDia]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(gastos.enumerated()), id: \.element.id) { indice, gasto in
                if indice > 0 {
                    Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, 64)
                }
                LinhaGasto(gasto: gasto)
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g)
    }
}

#Preview("Início claro") { VitrineView(pagina: .inicio).preferredColorScheme(.light) }
#Preview("Início escuro") { VitrineView(pagina: .inicio).preferredColorScheme(.dark) }
#Preview("Estados") { VitrineView(pagina: .estados) }
#Preview("Peças") { VitrineView(pagina: .pecas) }
#endif
