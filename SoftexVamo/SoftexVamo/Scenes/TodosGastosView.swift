import SwiftUI

/// Um dia de "Todos os gastos": o total do dia inteiro contra a diária e os
/// gastos que passam no filtro. Value type: filtrar nunca muta o `@Model`
/// durante o body (`AGENTS.md`, armadilha 2).
struct SecaoGastosDia: Identifiable {
    /// Início do dia.
    let id: Date
    let total: Decimal
    let diaria: Decimal
    let gastos: [GastosDia]

    var data: Date { id }
    var estourou: Bool { diaria > 0 && total > diaria }
    var passou: Decimal { max(0, total - diaria) }
}

extension FiltroGastos {
    func aceita(_ gasto: GastosDia) -> Bool {
        switch self {
        case .todos: return true
        case .semComprovante: return !temComprovanteValido(gasto)
        case .categoria(let categoria): return gasto.categoria == categoria
        }
    }
}

/// Seções da lista, do dia mais recente para o mais antigo; dentro do dia, do
/// gasto mais recente para o mais antigo. Dias sem gasto que passe no filtro
/// (ou na busca, pelo título) ficam de fora.
func secoesTodosGastos(_ ciclo: CicloSoftex?, filtro: FiltroGastos, busca: String,
                       calendario: Calendar = .current) -> [SecaoGastosDia] {
    guard let ciclo else { return [] }
    var porDia: [Date: [GastosDia]] = [:]
    for dia in ciclo.dias ?? [] where dia.deletadoEm == nil {
        porDia[calendario.startOfDay(for: dia.data), default: []] += dia.gastos.filter { $0.deletadoEm == nil }
    }
    let termo = busca.trimmingCharacters(in: .whitespaces)
    return porDia.keys.sorted(by: >).compactMap { inicio in
        let doDia = porDia[inicio] ?? []
        let visiveis = doDia
            .filter { filtro.aceita($0) && (termo.isEmpty || $0.titulo.localizedStandardContains(termo)) }
            .sorted { $0.criadoEm > $1.criadoEm }
        guard !visiveis.isEmpty else { return nil }
        return SecaoGastosDia(id: inicio, total: doDia.reduce(0) { $0 + $1.valor },
                              diaria: ciclo.diaria, gastos: visiveis)
    }
}

/// Quantos gastos válidos do ciclo estão sem comprovante (o número do filtro "Sem foto").
func contagemSemComprovante(_ ciclo: CicloSoftex?) -> Int {
    (ciclo?.dias ?? []).filter { $0.deletadoEm == nil }
        .flatMap(\.gastos)
        .filter { $0.deletadoEm == nil && !temComprovanteValido($0) }
        .count
}

/// "450" ou "147,70": o valor curto, sem "R$".
private func valorCurtoSemSimbolo(_ valor: Decimal) -> String {
    formatarBRLCurto(valor).replacingOccurrences(of: "R$ ", with: "")
}

/// Tela 12: todos os gastos da viagem do início, por dia, com busca e filtros.
struct TodosGastosView: View {
    let cicloId: UUID?
    /// Raiz da aba Gastos: título grande. Aberta a partir de outra tela, título pequeno (10/11).
    let raiz: Bool

    @EnvironmentObject private var viewModel: CiclosViewModel
    @Environment(\.abrirRota) private var abrirRota
    @State private var filtro: FiltroGastos
    @State private var busca = ""
    @FocusState private var buscando: Bool

    @ScaledMetric(relativeTo: .body) private var tamanhoIcone: CGFloat = 36

    init(cicloId: UUID?, filtro: FiltroGastos = .todos, raiz: Bool = false) {
        self.cicloId = cicloId
        self.raiz = raiz
        _filtro = State(initialValue: filtro)
    }

    var body: some View {
        let ciclo = viewModel.ciclo(id: cicloId)
        let secoes = secoesTodosGastos(ciclo, filtro: filtro, busca: busca)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                campoBusca
                filtros(semFoto: contagemSemComprovante(ciclo))
                if secoes.isEmpty {
                    vazio
                } else {
                    ForEach(secoes) { secao in
                        cabecalho(secao)
                        lista(secao)
                    }
                }
            }
            .padding(.bottom, Espaco.g)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Tema.fundo.ignoresSafeArea())
        // Título curto; a viagem vai no subtítulo ("Florianópolis · 10 a 17 de novembro"), para o
        // título não ocupar três linhas nem repetir o nome da aba (10/11).
        .navigationTitle("Gastos")
        .navigationSubtitle(ciclo.map(subtitulo) ?? "")
        .navigationBarTitleDisplayMode(raiz ? .large : .inline)
    }

    private func subtitulo(_ ciclo: CicloSoftex) -> String {
        let cidade = nomeCidade(ciclo.titulo)
        guard let datas = intervaloViagem(ciclo) else { return cidade }
        return "\(cidade) · \(periodoPorExtenso(de: datas.ini, ate: datas.fim))"
    }

    // MARK: Busca e filtros

    private var campoBusca: some View {
        HStack(spacing: Espaco.p) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tema.textoFraco)
                .accessibilityHidden(true)
            TextField("Buscar gasto ou local", text: $busca)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .focused($buscando)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !busca.isEmpty {
                Button { busca = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Tema.textoFraco)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, Espaco.m)
        .padding(.vertical, 10)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.campo, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Raio.campo, style: .continuous)
                .stroke(Tema.borda, lineWidth: 1)
        }
        .padding(.horizontal, Espaco.g + 2)
        .padding(.top, Espaco.p)
    }

    private func filtros(semFoto: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Espaco.p) {
                chip("Todos", selecionado: filtro == .todos, alerta: false) { filtro = .todos }
                chip("Sem foto (\(semFoto))", selecionado: filtro == .semComprovante, alerta: true) {
                    filtro = filtro == .semComprovante ? .todos : .semComprovante
                }
                menuCategoria
            }
            .padding(.horizontal, Espaco.g + 2)
        }
        .padding(.top, Espaco.m)
    }

    private var categoriaEscolhida: Categoria? {
        if case .categoria(let c) = filtro { return c }
        return nil
    }

    private var menuCategoria: some View {
        Menu {
            Button("Todas as categorias") { filtro = .todos }
            ForEach(Categoria.allCases) { categoria in
                Button {
                    filtro = .categoria(categoria)
                } label: {
                    if categoriaEscolhida == categoria {
                        Label(categoria.localizedName, systemImage: "checkmark")
                    } else {
                        Text(categoria.localizedName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(categoriaEscolhida?.localizedName ?? "Categoria")
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 7))
                    .accessibilityHidden(true)
            }
            .modifier(EstiloChip(selecionado: categoriaEscolhida != nil, alerta: false))
        }
        .accessibilityLabel(categoriaEscolhida.map { "Categoria, \($0.localizedName)" } ?? "Filtrar por categoria")
    }

    private func chip(_ titulo: String, selecionado: Bool, alerta: Bool, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Text(titulo).modifier(EstiloChip(selecionado: selecionado, alerta: alerta))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selecionado ? .isSelected : [])
    }

    // MARK: Seções

    private func cabecalho(_ secao: SecaoGastosDia) -> some View {
        let dia = "\(diaDaSemana(secao.data)), \(Calendar.current.component(.day, from: secao.data))"
        let gasto = "\(formatarValorSemSimbolo(secao.total)) de \(valorCurtoSemSimbolo(secao.diaria))"
        let acessivel = secao.estourou
            ? "\(dia): \(formatarBRL(secao.total)) de \(formatarBRLCurto(secao.diaria)), passou \(formatarBRLCurto(secao.passou))"
            : "\(dia): \(formatarBRL(secao.total)) de \(formatarBRLCurto(secao.diaria))"

        return HStack(alignment: .firstTextBaseline) {
            Text(dia)
                .font(.title3.weight(.bold))
                .foregroundStyle(Tema.texto)
                .lineLimit(1)
            Spacer(minLength: Espaco.p)
            HStack(spacing: 6) {
                Text(gasto)
                if secao.estourou {
                    Text("+\(valorCurtoSemSimbolo(secao.passou))")
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(secao.estourou ? Tema.estouro : Tema.textoFraco)
        }
        .padding(.horizontal, Espaco.g + 10)
        .padding(.top, 28)
        .padding(.bottom, Espaco.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(acessivel)
        .accessibilityAddTraits(.isHeader)
    }

    private func lista(_ secao: SecaoGastosDia) -> some View {
        VStack(spacing: 0) {
            ForEach(secao.gastos, id: \.id) { gasto in
                if gasto.id != secao.gastos.first?.id {
                    Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, tamanhoIcone + Espaco.g + Espaco.m)
                }
                Button { abrirRota(.detalheGasto(gasto.id)) } label: {
                    LinhaGastoCompacta(gasto: gasto, tamanhoIcone: tamanhoIcone)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .padding(.horizontal, Espaco.g + 2)
    }

    private var vazio: some View {
        Text(busca.isEmpty ? "Nenhum gasto aqui" : "Nenhum gasto encontrado")
            .font(.body)
            .foregroundStyle(Tema.textoFraco)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Espaco.g)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .padding(.horizontal, Espaco.g + 2)
            .padding(.top, 28)
    }
}

/// Chip de filtro: selecionado em texto sobre fundo invertido; "Sem foto" em cor de pendência.
private struct EstiloChip: ViewModifier {
    let selecionado: Bool
    let alerta: Bool

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selecionado ? Tema.fundo : (alerta ? Tema.alertaTexto : Tema.texto))
            .padding(.horizontal, Espaco.m + 2)
            .padding(.vertical, 7)
            .background(selecionado ? Tema.texto : (alerta ? Tema.alertaFundo : Tema.superficie2), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Linha da lista de todos os gastos (tela 12): ícone, título, ponto laranja
/// quando falta a foto e valor.
private struct LinhaGastoCompacta: View {
    let gasto: GastosDia
    let tamanhoIcone: CGFloat

    var body: some View {
        let faltaFoto = !temComprovanteValido(gasto)
        HStack(spacing: Espaco.m) {
            IconeCategoria(gasto.categoria, tamanho: tamanhoIcone)
            HStack(spacing: 6) {
                Text(gasto.titulo)
                    .font(.body)
                    .foregroundStyle(Tema.texto)
                    .lineLimit(1)
                if faltaFoto {
                    Circle().fill(Tema.alertaTexto).frame(width: 5, height: 5)
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
        .accessibilityLabel(
            "\(gasto.titulo), \(gasto.categoria.localizedName), \(formatarBRL(gasto.valor))\(faltaFoto ? ", falta a foto" : "")"
        )
        .accessibilityAddTraits(.isButton)
    }
}
