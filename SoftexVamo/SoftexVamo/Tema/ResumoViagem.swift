import Foundation

/// Um dia da viagem, já com os valores derivados para as barras.
struct DiaResumo: Identifiable {
    /// Início do dia no calendário usado no cálculo.
    let id: Date
    let data: Date
    let gasto: Decimal
    let diaria: Decimal
    let ehHoje: Bool
    let futuro: Bool

    var passou: Decimal { max(0, gasto - diaria) }
    /// Sem diária (0) não há estouro, como em `SecaoGastosDia`.
    var estourou: Bool { diaria > 0 && gasto > diaria }

    /// gasto / diária, limitado a 0...1.25. Vale 0 quando a diária é zero.
    var proporcao: Double {
        guard diaria > 0 else { return 0 }
        let p = NSDecimalNumber(decimal: gasto / diaria).doubleValue
        return min(max(p, 0), 1.25)
    }
}

enum EstadoViagem: Equatable {
    case semViagem
    case antes(diasFaltando: Int)
    case durante(dia: Int, de: Int)
    case encerrada
}

/// Intervalo (início de dia) do primeiro ao último dia do ciclo.
private func intervalo(_ ciclo: CicloSoftex, _ cal: Calendar) -> (ini: Date, fim: Date)? {
    let datas = (ciclo.dias ?? []).filter { $0.deletadoEm == nil }.map { cal.startOfDay(for: $0.data) }
    guard let ini = datas.min(), let fim = datas.max() else { return nil }
    return (ini, fim)
}

struct ResumoViagem {
    let estado: EstadoViagem
    let dias: [DiaResumo]
    let diaria: Decimal
    let total: Decimal
    let gastoTotal: Decimal
    let gastoHoje: Decimal
    let semComprovante: [GastosDia]
    let diasEstourados: Int

    var livreHoje: Decimal { diaria - gastoHoje }

    init(ciclo: CicloSoftex?, hoje: Date, calendario: Calendar = .current) {
        guard let ciclo, let (ini, fim) = intervalo(ciclo, calendario) else {
            estado = .semViagem; dias = []; diaria = 0; total = 0
            gastoTotal = 0; gastoHoje = 0; semComprovante = []; diasEstourados = 0
            return
        }
        let hojeInicio = calendario.startOfDay(for: hoje)
        let diariaCiclo = ciclo.diaria

        // Gastos válidos agrupados pelo dia do DiaSoftex a que pertencem.
        var porDia: [Date: [GastosDia]] = [:]
        for dia in ciclo.dias ?? [] where dia.deletadoEm == nil {
            let validos = dia.gastos.filter { $0.deletadoEm == nil }
            porDia[calendario.startOfDay(for: dia.data), default: []] += validos
        }

        var lista: [DiaResumo] = []
        var cursor = ini
        while cursor <= fim {
            let gastos = porDia[cursor] ?? []
            lista.append(DiaResumo(
                id: cursor, data: cursor,
                gasto: gastos.reduce(0) { $0 + $1.valor },
                diaria: diariaCiclo,
                ehHoje: cursor == hojeInicio,
                futuro: cursor > hojeInicio
            ))
            guard let prox = calendario.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = calendario.startOfDay(for: prox)
        }

        if hojeInicio < ini {
            let faltam = calendario.dateComponents([.day], from: hojeInicio, to: ini).day ?? 0
            estado = .antes(diasFaltando: faltam)
        } else if hojeInicio > fim {
            estado = .encerrada
        } else {
            let n = calendario.dateComponents([.day], from: ini, to: hojeInicio).day ?? 0
            estado = .durante(dia: n + 1, de: lista.count)
        }

        dias = lista
        diaria = diariaCiclo
        total = ciclo.valor_total
        gastoTotal = lista.reduce(0) { $0 + $1.gasto }
        gastoHoje = lista.first(where: \.ehHoje)?.gasto ?? 0
        diasEstourados = lista.filter(\.estourou).count
        // Mesma regra de Todos os gastos e Fechar viagem (remoção pendente conta).
        semComprovante = porDia.keys.sorted().flatMap { porDia[$0] ?? [] }.filter { !temComprovanteValido($0) }
    }
}

/// Primeiro e último dia da viagem: pelos dias do ciclo; sem dias carregados,
/// pelo `periodo` ("dd/MM - dd/MM"), no ano em que o ciclo foi criado.
func intervaloViagem(_ ciclo: CicloSoftex, calendario: Calendar = .current) -> (ini: Date, fim: Date)? {
    if let dias = intervalo(ciclo, calendario) { return dias }

    let partes = ciclo.periodo.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
    guard partes.count == 2 else { return nil }
    let ano = calendario.component(.year, from: ciclo.criadoEm)
    func data(_ texto: String, ano: Int) -> Date? {
        let p = texto.split(separator: "/").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return calendario.date(from: DateComponents(year: ano, month: p[1], day: p[0]))
    }
    guard let ini = data(partes[0], ano: ano), var fim = data(partes[1], ano: ano) else { return nil }
    if fim < ini, let virada = data(partes[1], ano: ano + 1) { fim = virada }
    return (ini, fim)
}

/// Ciclo que o início deve mostrar: o que contém hoje (em sobreposição, o de
/// primeiro dia mais recente); senão o próximo futuro; senão o último encerrado.
/// Ciclo ainda sem dias locais (instalação nova) conta pelo `periodo`.
func cicloDoInicio(_ ciclos: [CicloSoftex], hoje: Date, calendario: Calendar = .current) -> CicloSoftex? {
    let h = calendario.startOfDay(for: hoje)
    let comIntervalo = ciclos.compactMap { c in intervaloViagem(c, calendario: calendario).map { (c, $0.ini, $0.fim) } }

    if let atual = comIntervalo.filter({ $0.1 <= h && h <= $0.2 }).max(by: { $0.1 < $1.1 }) {
        return atual.0
    }
    if let proximo = comIntervalo.filter({ $0.1 > h }).min(by: { $0.1 < $1.1 }) {
        return proximo.0
    }
    return comIntervalo.max(by: { $0.2 < $1.2 })?.0
}

enum ValoresViagem {
    /// Diária = total / dias, arredondada a 2 casas (`.plain`). `dias <= 0` devolve 0.
    nonisolated static func diaria(total: Decimal, dias: Int) -> Decimal {
        guard dias > 0 else { return 0 }
        var bruto = total / Decimal(dias)
        var arredondado = Decimal()
        NSDecimalRound(&arredondado, &bruto, 2, .plain)
        return arredondado
    }

    nonisolated static func total(diaria: Decimal, dias: Int) -> Decimal {
        guard dias > 0 else { return 0 }
        return diaria * Decimal(dias)
    }
}

/// Código de 3 letras da cidade: sem acento, maiúsculas, ignorando ", UF".
nonisolated func codigoCidade(_ titulo: String) -> String {
    let cidade = titulo.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
    let letras = cidade
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
        .filter { $0.isLetter }
        .uppercased()
    guard !letras.isEmpty else { return "---" }
    return String(letras.prefix(3))
}
