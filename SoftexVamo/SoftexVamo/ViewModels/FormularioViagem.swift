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
/// mudar as datas recalcula a diária a partir do total. O campo que o usuário
/// está digitando nunca é reescrito, só o outro.
struct FormularioViagem: Equatable {
    enum Campo { case total, diaria }

    var destino: String
    private(set) var ida: Date
    private(set) var volta: Date
    private(set) var totalTexto = ""
    private(set) var diariaTexto = ""
    /// Último campo de valor que o usuário editou (`nil` = nenhum ainda).
    private(set) var ultimoEditado: Campo?
    let calendario: Calendar

    init(ida: Date, volta: Date, total: Decimal? = nil, destino: String = "", calendario: Calendar = .current) {
        self.ida = ida
        self.volta = volta
        self.destino = destino
        self.calendario = calendario
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

    /// Primeiro problema que impede salvar; `nil` quando pode salvar.
    var erro: String? {
        if destino.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Informe o destino" }
        if dias < 1 { return "A volta precisa ser no dia da ida ou depois" }
        guard let total, total > 0 else { return "Informe o total ou a diária" }
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

    private mutating func datasMudaram() {
        guard dias > 0 else { return }
        if let total, total > 0 {
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
