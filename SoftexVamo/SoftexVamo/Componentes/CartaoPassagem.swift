import SwiftUI

/// "20 a 25 de julho"; "28 de julho a 2 de agosto"; "20 de julho" para um dia só.
nonisolated func periodoPorExtenso(de inicio: Date, ate fim: Date, calendario: Calendar = .current) -> String {
    let fuso = calendario.timeZone
    let diaIni = calendario.component(.day, from: inicio)
    if calendario.isDate(inicio, inSameDayAs: fim) {
        return diaPorExtenso(inicio, fuso: fuso)
    }
    if calendario.isDate(inicio, equalTo: fim, toGranularity: .month) {
        return "\(diaIni) a \(diaPorExtenso(fim, fuso: fuso))"
    }
    return "\(diaPorExtenso(inicio, fuso: fuso)) a \(diaPorExtenso(fim, fuso: fuso))"
}

/// "Cuiabá" a partir de "Cuiabá, MT".
nonisolated func nomeCidade(_ titulo: String) -> String {
    let cidade = titulo.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? titulo
    return cidade.trimmingCharacters(in: .whitespaces)
}

/// A passagem: o único objeto marcado da tela (raio 20, recortes, picote).
struct CartaoPassagem: View {
    let resumo: ResumoViagem
    let origem: String?
    let destino: String
    let periodo: String
    let aoTocarDia: (DiaResumo) -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var tamanhoCodigo: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var tamanhoAviao: CGFloat = 18

    /// Diâmetro dos recortes laterais.
    private let recorte: CGFloat = 20

    init(resumo: ResumoViagem, origem: String?, destino: String, periodo: String,
         aoTocarDia: @escaping (DiaResumo) -> Void = { _ in }) {
        self.resumo = resumo
        self.origem = origem
        self.destino = destino
        self.periodo = periodo
        self.aoTocarDia = aoTocarDia
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rota
                .padding(.horizontal, Espaco.g)
                .padding(.top, Espaco.g)
            HStack {
                Text(periodo)
                Spacer(minLength: Espaco.p)
                Text(textoDias)
            }
            .font(.subheadline)
            .foregroundStyle(Tema.textoFraco)
            .lineLimit(1)
            .padding(.horizontal, Espaco.g)
            .padding(.top, 6)
            .padding(.bottom, Espaco.m)
            .accessibilityElement(children: .combine)

            picote

            estadoBloco
                .padding(.horizontal, Espaco.g)
                .padding(.top, Espaco.m)
                .padding(.bottom, Espaco.g)
        }
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Raio.passagem, style: .continuous))
    }

    // MARK: Rota

    @ViewBuilder
    private var rota: some View {
        if let origem {
            HStack(alignment: .bottom, spacing: Espaco.p) {
                lado(rotulo: nomeCidade(origem), codigo: codigoCidade(origem), alinhamento: .leading)
                Spacer(minLength: 0)
                aviao.padding(.bottom, tamanhoCodigo * 0.45)
                Spacer(minLength: 0)
                lado(rotulo: nomeCidade(destino), codigo: codigoCidade(destino), alinhamento: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("De \(nomeCidade(origem)) para \(nomeCidade(destino))")
        } else {
            // Sem origem: só o lado do destino, com o avião apontando para ele.
            HStack(alignment: .bottom, spacing: Espaco.m) {
                lado(rotulo: "Para \(nomeCidade(destino))", codigo: codigoCidade(destino), alinhamento: .leading)
                aviao.padding(.bottom, tamanhoCodigo * 0.12)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Para \(nomeCidade(destino))")
        }
    }

    private var aviao: some View {
        Image(systemName: "airplane")
            .font(.system(size: tamanhoAviao, weight: .semibold))
            .foregroundStyle(Tema.marca)
            .accessibilityHidden(true)
    }

    private func lado(rotulo: String, codigo: String, alinhamento: HorizontalAlignment) -> some View {
        VStack(alignment: alinhamento, spacing: 2) {
            Text(rotulo)
                .font(.footnote)
                .foregroundStyle(Tema.textoFraco)
                .lineLimit(1)
            Text(codigo)
                .font(.larga(tamanhoCodigo, .heavy))
                .foregroundStyle(Tema.texto)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var textoDias: String {
        switch resumo.estado {
        case .durante(let dia, let de):
            return "\(dia)º de \(de) dias"
        default:
            let n = resumo.dias.count
            return n == 1 ? "1 dia" : "\(n) dias"
        }
    }

    // MARK: Picote

    private var picote: some View {
        ZStack {
            Line()
                .stroke(Tema.borda, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5]))
                .frame(height: 2)
                .padding(.horizontal, recorte / 2 + 6)
            HStack {
                Circle().fill(Tema.fundo).frame(width: recorte, height: recorte)
                    .offset(x: -recorte / 2)
                Spacer()
                Circle().fill(Tema.fundo).frame(width: recorte, height: recorte)
                    .offset(x: recorte / 2)
            }
        }
        .frame(height: recorte)
        .accessibilityHidden(true)
    }

    // MARK: Estado

    @ViewBuilder
    private var estadoBloco: some View {
        switch resumo.estado {
        case .durante:
            VStack(alignment: .leading, spacing: 2) {
                valorDoDia
                Text("Você gastou \(formatarBRL(resumo.gastoHoje)) dos \(formatarBRLCurto(resumo.diaria)) de hoje")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                BarrasPorDia(dias: resumo.dias, aoTocar: aoTocarDia)
                    .padding(.top, Espaco.m + 4)
            }
        case .antes(let faltando):
            VStack(alignment: .leading, spacing: 4) {
                Text(faltando == 1 ? "Começa amanhã" : "Começa em \(faltando) dias")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Tema.texto)
                Text("A diária é de \(formatarBRLCurto(resumo.diaria))")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .encerrada:
            VStack(alignment: .leading, spacing: 4) {
                Text("Viagem encerrada")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Tema.texto)
                Text("Você gastou \(formatarBRL(resumo.gastoTotal)) dos \(formatarBRLCurto(resumo.total))")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .semViagem:
            Text("Nenhuma viagem agora")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Tema.texto)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var valorDoDia: some View {
        let livre = resumo.livreHoje
        if livre >= 0 {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ainda dá para gastar hoje")
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
                ValorMonetario(livre, destaque: true)
                    .foregroundStyle(Tema.texto)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ainda dá para gastar hoje, \(formatarBRL(livre))")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Passou hoje")
                    .font(.subheadline)
                    .foregroundStyle(Tema.estouro)
                ValorMonetario(-livre, destaque: true)
                    .foregroundStyle(Tema.estouro)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Passou \(formatarBRL(-livre)) hoje")
        }
    }
}

/// Linha horizontal no meio do retângulo (para o picote).
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

#if DEBUG
private struct PassagemExemplo: View {
    let dados = DadosExemplo.compartilhado

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CartaoPassagem(resumo: dados.resumo(), origem: "São Paulo",
                               destino: dados.ciclo.titulo, periodo: dados.periodo)
                CartaoPassagem(resumo: dados.resumo(hoje: dados.dia(21)), origem: nil,
                               destino: dados.ciclo.titulo, periodo: dados.periodo)
                CartaoPassagem(resumo: dados.resumo(hoje: dados.dia(15)), origem: "São Paulo",
                               destino: dados.ciclo.titulo, periodo: dados.periodo)
            }
            .padding(12)
        }
        .background(Tema.fundo)
    }
}

#Preview("Claro") { PassagemExemplo().preferredColorScheme(.light) }
#Preview("Escuro") { PassagemExemplo().preferredColorScheme(.dark) }
#endif
