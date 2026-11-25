import Foundation

/// Lê um valor em reais digitado em pt-BR ("2.700,00", "R$ 1.183", "450"),
/// independente do idioma do aparelho. Aceita também o ponto decimal do teclado
/// de aparelhos em inglês ("450.50"). Arredonda a 2 casas. `nil` se não for número.
nonisolated func lerValorDigitado(_ texto: String) -> Decimal? {
    var s = texto.replacingOccurrences(of: "R$", with: "").filter { !$0.isWhitespace }
    guard !s.isEmpty else { return nil }
    let pontos = s.filter { $0 == "." }.count
    if s.contains(",") {
        s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
    } else if pontos == 1, let ponto = s.firstIndex(of: "."),
              s.distance(from: ponto, to: s.endIndex) - 1 <= 2 {
        // "450.5" ou "450.50": ponto decimal; "2.700" segue como milhar.
    } else {
        s = s.replacingOccurrences(of: ".", with: "")
    }
    guard s.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }),
          s.filter({ $0 == "." }).count <= 1,
          s.contains(where: { ("0"..."9").contains($0) }),
          var valor = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    var arredondado = Decimal()
    NSDecimalRound(&arredondado, &valor, 2, .plain)
    return arredondado
}

/// Estado do formulário de Nova viagem (tela 4): destino, datas e os campos
/// ligados total ⇅ diária. Editar um recalcula o outro com `ValoresViagem`;
/// mudar as datas mantém o campo digitado por último e recalcula o outro (sem
/// nenhum digitado, como ao editar viagem antiga, vale o total). O campo que o
/// usuário está digitando nunca é reescrito, só o outro.
struct FormularioViagem: Equatable {
    enum Campo { case total, diaria }

    /// Janela de anos aceita no formulário: 1 ano de folga sobre os 5 que o
    /// servidor permite (hoje ± 5 em `data_dentro_do_limite`), porque a
    /// viagem pode subir dias depois de criada.
    static let anosPermitidos = 4

    var destino: String
    private(set) var ida: Date
    private(set) var volta: Date
    private(set) var totalTexto = ""
    private(set) var diariaTexto = ""
    /// Último campo de valor que o usuário editou (`nil` = nenhum ainda).
    private(set) var ultimoEditado: Campo?
    let calendario: Calendar
    /// Referência da janela de datas; injetável para os testes.
    let hoje: Date

    init(ida: Date, volta: Date, total: Decimal? = nil, destino: String = "", calendario: Calendar = .current, hoje: Date = Date()) {
        self.ida = ida
        self.volta = volta
        self.destino = destino
        self.calendario = calendario
        self.hoje = hoje
        if let total, total > 0 {
            totalTexto = formatarValorSemSimbolo(total)
            diariaTexto = dias > 0 ? formatarValorSemSimbolo(ValoresViagem.diaria(total: total, dias: dias)) : ""
        }
    }

    /// Dias da viagem contando a ida e a volta; 0 se a volta é antes da ida.
    var dias: Int {
        let n = calendario.dateComponents([.day], from: calendario.startOfDay(for: ida),
                                          to: calendario.startOfDay(for: volta)).day ?? 0
        return max(0, n + 1)
    }

    var total: Decimal? { lerValorDigitado(totalTexto) }
    var diaria: Decimal? { lerValorDigitado(diariaTexto) }

    /// Janela de datas do formulário (início de dia nos dois limites):
    /// `anosPermitidos` anos antes e depois de `hoje`.
    var intervaloDatas: ClosedRange<Date> {
        let base = calendario.startOfDay(for: hoje)
        let ini = calendario.date(byAdding: .year, value: -Self.anosPermitidos, to: base) ?? base
        let fim = calendario.date(byAdding: .year, value: Self.anosPermitidos, to: base) ?? base
        return ini...fim
    }

    /// Primeiro problema que impede salvar; `nil` quando pode salvar.
    var erro: String? {
        if destino.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Informe o destino" }
        if dias < 1 { return "A volta precisa ser no dia da ida ou depois" }
        guard let total, total > 0 else { return "Informe o total ou a diária" }
        // Acima do teto o servidor devolve 422 e a viagem inteira ficava
        // tentando subir para sempre. A diária digitada vira o total
        // (`diaria × dias`), então basta conferir os dois campos como lidos.
        if total > LimiteValor.maximo || (diaria ?? 0) > LimiteValor.maximo {
            return LimiteValor.mensagem
        }
        // Ano digitado errado (2062): o servidor recusa dia fora de hoje ± 5
        // anos e a viagem, com dias e gastos, ficava tentando subir para sempre.
        let janela = intervaloDatas
        if !janela.contains(calendario.startOfDay(for: ida))
            || !janela.contains(calendario.startOfDay(for: volta)) {
            return "Escolha datas até \(Self.anosPermitidos) anos antes ou depois de hoje"
        }
        // Diária que arredonda a 0,00 o servidor recusa (`gt=0`): R$ 1 para
        // 201 dias ficava retentando para sempre. O `Decimal(string:)` é
        // exato — o literal 0.01 viria de Double e seria maior que 0,01.
        if ValoresViagem.diaria(total: total, dias: dias) < Decimal(string: "0.01")! {
            return "A diária ficaria abaixo de R$ 0,01. Aumente o total ou encurte a viagem"
        }
        return nil
    }

    mutating func editarTotal(_ texto: String) {
        totalTexto = Self.limpar(texto)
        ultimoEditado = .total
        recalcularDiaria()
    }

    mutating func editarDiaria(_ texto: String) {
        diariaTexto = Self.limpar(texto)
        ultimoEditado = .diaria
        guard dias > 0 else { return }
        if let diaria {
            totalTexto = formatarValorSemSimbolo(ValoresViagem.total(diaria: diaria, dias: dias))
        } else {
            totalTexto = ""
        }
    }

    /// Muda a ida; se passar da volta, a volta acompanha.
    mutating func mudarIda(_ data: Date) {
        ida = data
        if calendario.startOfDay(for: volta) < calendario.startOfDay(for: ida) { volta = ida }
        datasMudaram()
    }

    mutating func mudarVolta(_ data: Date) {
        volta = data
        datasMudaram()
    }

    /// Reescreve os dois campos no formato "2.700,00" (ao sair do campo).
    mutating func formatarCampos() {
        if let total { totalTexto = formatarValorSemSimbolo(total) }
        if let diaria { diariaTexto = formatarValorSemSimbolo(diaria) }
    }

    // MARK: Privado

    /// O campo que a pessoa digitou por último fica e o outro acompanha as datas: quem tem diária
    /// fixa (R$ 450/dia) quer ver o total subir ao ganhar um dia, não a diária cair (decisão do João, 09/11).
    private mutating func datasMudaram() {
        guard dias > 0 else { return }
        if ultimoEditado == .diaria, let diaria, diaria > 0 {
            totalTexto = formatarValorSemSimbolo(ValoresViagem.total(diaria: diaria, dias: dias))
        } else if let total, total > 0 {
            recalcularDiaria()
        } else if let diaria, diaria > 0 {
            totalTexto = formatarValorSemSimbolo(ValoresViagem.total(diaria: diaria, dias: dias))
        }
    }

    private mutating func recalcularDiaria() {
        guard dias > 0 else { return }
        if let total {
            diariaTexto = formatarValorSemSimbolo(ValoresViagem.diaria(total: total, dias: dias))
        } else {
            diariaTexto = ""
        }
    }

    /// Só algarismos, vírgula e ponto (o que o teclado decimal digita ou se cola).
    private static func limpar(_ texto: String) -> String {
        String(texto.filter { ("0"..."9").contains($0) || $0 == "," || $0 == "." })
    }
}
