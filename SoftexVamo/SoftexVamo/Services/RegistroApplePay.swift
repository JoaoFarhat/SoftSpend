import Foundation
import SwiftData

/// O que a regra do atalho do Apple Pay responde (§1.4 de
/// `docs/cartao-sem-open-finance.md`).
enum ResultadoRegistro: Equatable {
    case gravado(titulo: String, valor: Decimal, viagem: String, dia: Date)
    /// Sem viagem aberta nem dia local de hoje: foi para a fila (§1.5).
    case guardadoSemViagem(titulo: String, valor: Decimal)
    /// A mesma compra já estava registrada; nada mudou.
    case duplicado
    case recusado(MotivoRecusa)
}

enum MotivoRecusa: Equatable {
    case valorInvalido
    case moedaEstrangeira
    case semUsuario
}

/// Leitura do texto da variável "Valor" que a automação entrega (§1.4).
nonisolated enum ValorDaCompra {
    /// Acima disto é provável erro de leitura da automação.
    static let teto: Decimal = 100_000

    private static let simbolosEstrangeiros = ["€", "£", "¥"]
    /// Códigos ISO 4217 que não são BRL. "R$" e "BRL" passam.
    private static let codigosEstrangeiros = [
        "USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "ARS", "CLP", "COP",
        "MXN", "PEN", "UYU", "PYG", "BOB", "NZD", "SEK", "NOK", "DKK", "INR",
        "CNY", "HKD", "KRW", "ZAR", "ILS", "RUB", "TRY", "AED", "SGD", "THB"
    ]

    /// Texto com símbolo ou código de outra moeda (`US$`, `$` sozinho, `€`,
    /// `£`, `USD`, `EUR`). Só `R$`, `BRL` ou sem símbolo passam: gravar
    /// "10,00" dólares como R$ 10,00 esconderia o erro.
    static func moedaEstrangeira(_ texto: String) -> Bool {
        // Tira o que é real antes de procurar o "$" e os códigos de fora.
        let resto = texto
            .replacingOccurrences(of: "R$", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "BRL", with: "", options: .caseInsensitive)
        if resto.contains("$") { return true }
        if simbolosEstrangeiros.contains(where: { resto.contains($0) }) { return true }
        return resto
            .components(separatedBy: .alphanumerics.inverted)
            .contains { codigosEstrangeiros.contains($0.uppercased()) }
    }

    /// Lê o valor em reais de "R$ 1.234,56", "1.234,56", "1234,56", "12,5",
    /// "12.34" ou "-12,34" (negativo vira positivo: algumas automações entregam
    /// o sinal). Aceita espaços, inclusive o espaço sem quebra. Vírgula é
    /// decimal; ponto seguido de exatamente 3 dígitos e de mais nada é milhar
    /// ("1.234"); ponto seguido de 1 ou 2 dígitos é decimal ("12.34").
    /// Arredonda a 2 casas. `nil` para texto sem número, zero, acima do teto
    /// ou moeda que não é real.
    static func interpretar(_ texto: String) -> Decimal? {
        guard !moedaEstrangeira(texto) else { return nil }

        // Espaços sem quebra que a automação entrega dentro de "R$ 1.234,56".
        let limpo = texto
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")

        // Do primeiro ao último dígito; fora deles ficam "R$", espaços e o "-".
        let digitos = limpo.indices.filter { limpo[$0].isNumber }
        guard let primeiro = digitos.first, let ultimo = digitos.last else { return nil }
        var numero = String(limpo[primeiro...ultimo])

        // No meio só podem dígitos, separadores e espaços ("1 234,56").
        guard numero.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == " " }) else { return nil }
        numero = numero.replacingOccurrences(of: " ", with: "")

        let decimalTexto: String
        if let corte = numero.lastIndex(of: ",") {
            // Vírgula é decimal; os pontos são milhar.
            let inteira = numero[..<corte].replacingOccurrences(of: ".", with: "")
            decimalTexto = "\(inteira).\(numero[numero.index(after: corte)...])"
        } else if let ponto = numero.lastIndex(of: ".") {
            let depois = numero[numero.index(after: ponto)...]
            if depois.count == 3 {
                // Ponto seguido de exatamente 3 dígitos e de mais nada é milhar.
                decimalTexto = numero.replacingOccurrences(of: ".", with: "")
            } else {
                let inteira = numero[..<ponto].replacingOccurrences(of: ".", with: "")
                decimalTexto = "\(inteira).\(depois)"
            }
        } else {
            decimalTexto = numero
        }

        // "12,34,56": a vírgula sobrou no meio — entrada malformada, não valor.
        guard !decimalTexto.contains(","),
              let valor = Decimal(string: decimalTexto), valor != 0 else { return nil }
        var arredondado = Decimal()
        NSDecimalRound(&arredondado, &valor, 2, .plain)
        guard arredondado > 0, arredondado <= teto else { return nil }
        return arredondado
    }
}

/// A regra do atalho "Registrar gasto" do Apple Pay (§1.4), isolada para
/// testar com banco em memória: recebe `ModelContext`, `userId`, `agora` e
/// `calendario`. O `RegistrarGastoIntent` só chama isto.
///
/// A gravação é a mesma do `CiclosViewModel.createNewGasto`, sem passar por
/// ele (ele depende de `atualCiclo`, que é estado de tela): `GastosDia(dia:)` +
/// `insert`, **sem** `dia.gastos.append` (pegadinha 3 do `AGENTS.md`),
/// `ciclo.gasto_total += valor` e `save`. `syncStatus` fica `.pending` e quem
/// sobe é o `SyncManager` de sempre.
enum RegistroApplePay {
    /// Janela da deduplicação: o Atalhos às vezes dispara a mesma compra duas
    /// vezes e a automação do Apple Watch pode repetir. Deslizante em vez de
    /// "mesmo minuto do relógio": 10:04:59 e 10:05:01 são a mesma compra.
    static let janelaDuplicata: TimeInterval = 60

    /// Estabelecimento vazio vira este título.
    static let tituloPadrao = "Compra no cartão"

    static func registrar(
        valorTexto: String,
        estabelecimento: String,
        cartao: String? = nil,
        userId: String?,
        em modelContext: ModelContext,
        agora: Date = .now,
        calendario: Calendar = .current,
        fila: ComprasAguardandoViagem = .compartilhada
    ) throws -> ResultadoRegistro {
        // Sem usuário salvo (nunca logou ou saiu da conta) não grava nada:
        // tudo filtra por userId, então a compra nunca cai na conta errada.
        guard let userId, !userId.isEmpty else { return .recusado(.semUsuario) }

        // Moeda antes do valor: "US$ 10,00" lê um número válido, mas gravá-lo
        // em reais esconderia o erro; a recusa com aviso é honesta.
        guard !ValorDaCompra.moedaEstrangeira(valorTexto) else { return .recusado(.moedaEstrangeira) }
        guard let valor = ValorDaCompra.interpretar(valorTexto) else { return .recusado(.valorInvalido) }

        let titulo = tituloDoGasto(estabelecimento)
        let categoria = InterpretadorComprovante.inferirCategoria(de: [estabelecimento]) ?? .OUTROS

        if ehDuplicata(valor: valor, titulo: titulo, userId: userId,
                       em: modelContext, agora: agora, fila: fila) {
            return .duplicado
        }

        guard let (viagem, dia) = viagemEDiaDeHoje(userId: userId, em: modelContext,
                                                   hoje: agora, calendario: calendario) else {
            // A compra já aconteceu; recusar a perde. Fica na fila "sem
            // viagem" (§1.5) para o usuário decidir depois.
            fila.adicionar(CompraAguardandoViagem(
                id: UUID(), userId: userId, valor: valor, estabelecimento: titulo,
                cartao: cartao, categoria: categoria, recebidaEm: agora
            ))
            return .guardadoSemViagem(titulo: titulo, valor: valor)
        }

        let gasto = GastosDia(valor: valor, titulo: titulo, categoria: categoria, dia: dia)
        modelContext.insert(gasto)
        // `criadoEm` = quando a ação rodou (o `agora` injetável), que é o que a
        // deduplicação compara — em produção é o mesmo `Date.now` do modelo.
        gasto.criadoEm = agora
        viagem.gasto_total += valor
        try modelContext.save()
        return .gravado(titulo: titulo, valor: valor, viagem: nomeCidade(viagem.titulo), dia: dia.data)
    }

    /// Lança um item da fila "sem viagem" no dia escolhido (§1.5). O item sai
    /// da fila só **depois** do `save`: falhou, fica.
    /// Devolve `false` quando o dia não tem viagem (nada é gravado nem tirado).
    @discardableResult
    static func lancar(
        _ compra: CompraAguardandoViagem,
        no dia: DiaSoftex,
        em modelContext: ModelContext,
        agora: Date = .now,
        fila: ComprasAguardandoViagem = .compartilhada
    ) throws -> Bool {
        guard let viagem = dia.ciclo else { return false }
        let gasto = GastosDia(valor: compra.valor, titulo: compra.estabelecimento,
                              categoria: compra.categoria, dia: dia)
        modelContext.insert(gasto)
        gasto.criadoEm = agora
        viagem.gasto_total += compra.valor
        try modelContext.save()
        fila.remover(id: compra.id)
        return true
    }

    /// Mesma compra chegando de novo dentro da janela: gasto vivo do usuário
    /// **ou item na fila** com o mesmo valor e o mesmo estabelecimento (sem
    /// acento, sem maiúsculas, sem espaços repetidos). O `criadoEm` vai no
    /// `#Predicate` (propriedade persistida); valor e título são filtrados em
    /// memória (pegadinha 1 do `AGENTS.md`: nunca `@Transient` no predicado).
    ///
    /// Efeito colateral aceito: um gasto digitado à mão igual no último minuto
    /// também bloqueia o atalho — é o que o usuário quer. E duas compras
    /// iguais de verdade em menos de 1 minuto viram uma só (limite conhecido).
    private static func ehDuplicata(
        valor: Decimal, titulo: String, userId: String,
        em modelContext: ModelContext, agora: Date, fila: ComprasAguardandoViagem
    ) -> Bool {
        let limite = agora.addingTimeInterval(-janelaDuplicata)
        let chave = normalizarParaComparacao(titulo)

        let descritor = FetchDescriptor<GastosDia>(predicate: #Predicate { $0.criadoEm > limite })
        let recentes = (try? modelContext.fetch(descritor)) ?? []
        let gastoIgual = recentes.contains {
            $0.deletadoEm == nil
                && $0.dia?.ciclo?.userId == userId
                && $0.valor == valor
                && normalizarParaComparacao($0.titulo) == chave
        }
        if gastoIgual { return true }

        return fila.itens(do: userId).contains {
            $0.recebidaEm > limite
                && $0.valor == valor
                && normalizarParaComparacao($0.estabelecimento) == chave
        }
    }

    /// Viagem aberta = a do usuário cujo intervalo (`intervaloViagem`, que já
    /// usa os dias locais ou o `periodo`) contém hoje; com mais de uma, a de
    /// primeiro dia mais recente — mesma regra de `cicloDoInicio`, mas **sem**
    /// cair na "próxima" ou na "última encerrada": isso não é viagem aberta.
    /// Devolve também o `DiaSoftex` vivo de hoje, ou `nil` se não houver
    /// (instalação nova que ainda não baixou os dias → fila, nunca dia errado).
    private static func viagemEDiaDeHoje(
        userId: String, em modelContext: ModelContext, hoje: Date, calendario: Calendar
    ) -> (viagem: CicloSoftex, dia: DiaSoftex)? {
        let inicioDoDia = calendario.startOfDay(for: hoje)
        let descritor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId }
        )
        let ciclos = (try? modelContext.fetch(descritor)) ?? []
        let viagem = ciclos
            .compactMap { ciclo -> (CicloSoftex, Date)? in
                guard let intervalo = intervaloViagem(ciclo, calendario: calendario),
                      intervalo.ini <= inicioDoDia, inicioDoDia <= intervalo.fim
                else { return nil }
                return (ciclo, intervalo.ini)
            }
            .max { $0.1 < $1.1 }?.0

        guard let viagem,
              let dia = (viagem.dias ?? []).first(where: {
                  $0.deletadoEm == nil && calendario.isDate($0.data, inSameDayAs: hoje)
              })
        else { return nil }
        return (viagem, dia)
    }

    /// Estabelecimento → título do gasto: sem espaços nas pontas, espaços
    /// repetidos viram um, vazio vira "Compra no cartão", e o nome em
    /// MAIÚSCULAS que o Apple Pay costuma mandar passa por `formatarTitulo`.
    /// Cortado em 60 caracteres.
    static func tituloDoGasto(_ estabelecimento: String) -> String {
        let limpo = colapsarEspacos(estabelecimento)
        let base = limpo.isEmpty ? tituloPadrao : limpo
        return String(InterpretadorComprovante.formatarTitulo(base).prefix(60))
    }

    /// Chave da deduplicação: sem acento, sem maiúsculas e sem espaços repetidos.
    static func normalizarParaComparacao(_ texto: String) -> String {
        colapsarEspacos(InterpretadorComprovante.normalizar(texto))
    }

    /// Espaços (inclusive os sem quebra) viram um só e some das pontas.
    private static func colapsarEspacos(_ texto: String) -> String {
        texto
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
