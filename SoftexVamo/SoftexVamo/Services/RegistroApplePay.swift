import Foundation
import SwiftData
import os

/// O que a ação "Registrar gasto" responde ao Atalhos (§1.4 de
/// docs/cartao-sem-open-finance.md).
enum ResultadoRegistro: Equatable {
    case gravado(titulo: String, valor: Decimal, viagem: String, dia: Date)
    /// Sem viagem aberta com dia de hoje: a compra foi para a fila (§1.5).
    case guardadoSemViagem(titulo: String, valor: Decimal)
    /// A mesma compra chegando duas vezes em até 60 s: nada mudou.
    case duplicado
    case recusado(MotivoRecusa)
}

enum MotivoRecusa: Equatable {
    case valorInvalido
    case moedaEstrangeira
    case semUsuario
}

/// Valor da compra em texto, como a automação do Atalhos entrega
/// ("R$ 12,34" ou só "12,34"; §1.2/§1.4).
nonisolated enum ValorDaCompra {
    /// Acima disso é provável erro de leitura; a compra é recusada.
    static let teto: Decimal = 100_000

    /// `nil` = sem número, zero ou acima do teto. Símbolo de outra moeda é
    /// recusado antes, por `temMoedaEstrangeira`.
    ///
    /// Aceita `R$ 1.234,56`, `1.234,56`, `1234,56`, `12,5`, `12.34`, com
    /// espaços (inclusive o espaço sem quebra) e sinal de menos (a compra
    /// com sinal negativo vira positiva). Vírgula é decimal; ponto seguido
    /// de exatamente 3 dígitos e de mais nada é milhar (`1.234`); ponto
    /// seguido de 1 ou 2 dígitos é decimal (`12.34`). Arredonda a 2 casas.
    static func interpretar(_ texto: String) -> Decimal? {
        // Compras com sinal negativo viram positivas ("-12,34").
        var s = texto
            .replacingOccurrences(of: "R$", with: "")
            .replacingOccurrences(of: "BRL", with: "")
            .replacingOccurrences(of: "-", with: "")
            .filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        let pontos = s.filter { $0 == "." }.count
        if s.contains(",") {
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if pontos == 1, let ponto = s.firstIndex(of: "."),
                  s.distance(from: ponto, to: s.endIndex) - 1 <= 2 {
            // "12.5" ou "12.34": ponto decimal; "1.234" segue como milhar.
        } else {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard s.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }),
              s.filter({ $0 == "." }).count <= 1,
              s.contains(where: { ("0"..."9").contains($0) }),
              let valor = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        var arredondado = Decimal()
        NSDecimalRound(&arredondado, &valor, 2, .plain)
        let absoluto = abs(arredondado)
        guard absoluto > 0, absoluto <= teto else { return nil }
        return absoluto
    }

    /// Símbolo ou código de moeda que não é real (`US$`, `$` sozinho, `€`,
    /// `£`, `USD`, `EUR`...). Só `R$`, `BRL` ou sem símbolo passam: gravar
    /// "10,00" dólares como `R$ 10,00` esconderia o erro.
    static func temMoedaEstrangeira(_ texto: String) -> Bool {
        let s = texto.uppercased()
        if s.contains("€") || s.contains("£") || s.contains("¥") { return true }
        // "$" sem o "R" na frente pega "US$ 10" e "$ 10", mas não "R$ 10".
        if s.contains("$"), !s.contains("R$") { return true }
        return ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "ARS", "CLP", "COP", "MXN"]
            .contains { s.contains($0) }
    }
}

/// A regra do registro (§1.4), pura e testável: recebe `ModelContext`,
/// `userId`, `agora` e `calendario` — a ação só chama isto.
enum RegistroApplePay {
    /// Janela deslizante da duplicata: duas chegadas a menos de 60 s uma da
    /// outra são a mesma compra (mesmo às 10:04:59 e 10:05:01, que cairiam
    /// em minutos diferentes de um "mesmo minuto do relógio").
    static let janelaDuplicata: TimeInterval = 60
    /// Título quando o Atalhos manda o estabelecimento vazio.
    static let tituloPadrao = "Compra no cartão"
    /// O título do gasto é cortado neste tamanho (§1.3).
    static let tamanhoTitulo = 60

    private static let logger = Logger(subsystem: "br.com.softspend", category: "RegistroApplePay")

    /// Valida e grava a compra no dia de hoje da viagem aberta — ou na fila
    /// "sem viagem" (§1.5) se não há onde lançar. `userId` vem do
    /// `UsuarioSalvo`, sem depender de token; `fila`, `agora` e `calendario`
    /// são injetáveis para teste.
    static func registrar(
        valorTexto: String,
        estabelecimento: String,
        cartao: String? = nil,
        userId: String?,
        em context: ModelContext,
        fila: ComprasAguardandoViagem = .padrao,
        agora: Date = .now,
        calendario: Calendar = .current
    ) -> ResultadoRegistro {
        guard let userId, !userId.isEmpty else { return .recusado(.semUsuario) }
        guard !ValorDaCompra.temMoedaEstrangeira(valorTexto) else { return .recusado(.moedaEstrangeira) }
        guard let valor = ValorDaCompra.interpretar(valorTexto) else { return .recusado(.valorInvalido) }

        let titulo = tituloDoGasto(estabelecimento)
        let categoria = InterpretadorComprovante.inferirCategoria(de: [titulo]) ?? .OUTROS

        if ehDuplicata(valor: valor, estabelecimento: titulo, userId: userId,
                       em: context, fila: fila, agora: agora) {
            return .duplicado
        }

        guard let (ciclo, dia) = diaDeHoje(userId: userId, agora: agora,
                                           calendario: calendario, em: context) else {
            return guardarNaFila(valor: valor, titulo: titulo, categoria: categoria,
                                 cartao: cartao, userId: userId, agora: agora, fila: fila)
        }

        do {
            try gravar(valor: valor, titulo: titulo, categoria: categoria,
                       dia: dia, ciclo: ciclo, em: context)
        } catch {
            // A compra já aconteceu; falhou o save, vai para a fila em vez
            // de se perder (o mesmo motivo da fila existir, §1.5).
            logger.error("Save do gasto do atalho falhou, indo para a fila: \(error.localizedDescription, privacy: .public)")
            return guardarNaFila(valor: valor, titulo: titulo, categoria: categoria,
                                 cartao: cartao, userId: userId, agora: agora, fila: fila)
        }
        return .gravado(titulo: titulo, valor: valor, viagem: ciclo.titulo, dia: dia.data)
    }

    /// Lança um item da fila num dia (§1.5): a mesma gravação de cima, e o
    /// item só sai da fila **depois** do save — falhou, ele fica.
    /// O gasto nasce com o `id` da compra: um lançamento repetido encontra o
    /// gasto já gravado e só limpa a fila, sem criar duplicata.
    @discardableResult
    static func lancar(_ compra: CompraAguardandoViagem, em dia: DiaSoftex,
                     em context: ModelContext,
                     fila: ComprasAguardandoViagem = .padrao) throws -> GastosDia {
        let compraId = compra.id
        let descricao = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.id == compraId }
        )
        if let existente = try context.fetch(descricao).first {
            fila.remover(id: compra.id)
            return existente
        }
        guard let ciclo = dia.ciclo else { throw ErroLancamento.diaSemViagem }
        let gasto = try gravar(valor: compra.valor, titulo: compra.estabelecimento,
                               categoria: compra.categoria, dia: dia, ciclo: ciclo,
                               em: context, id: compra.id)
        fila.remover(id: compra.id)
        return gasto
    }

    enum ErroLancamento: Error {
        /// O dia escolhido não está pendurado em nenhuma viagem.
        case diaSemViagem
    }

    /// Viagem aberta do usuário (intervalo contém hoje) e o `DiaSoftex` vivo
    /// de hoje. Em sobreposição, a de primeiro dia mais recente — o começo da
    /// regra do `cicloDoInicio`, sem cair na "próxima" nem na "última
    /// encerrada": isso não é viagem aberta. `nil` se não há onde lançar.
    static func diaDeHoje(userId: String, agora: Date, calendario: Calendar,
                          em context: ModelContext) -> (ciclo: CicloSoftex, dia: DiaSoftex)? {
        let descricao = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId }
        )
        let ciclos = (try? context.fetch(descricao)) ?? []
        let hoje = calendario.startOfDay(for: agora)
        guard let ciclo = ciclos
            .compactMap { c in intervaloViagem(c, calendario: calendario).map { (c, $0.ini, $0.fim) } }
            .filter { $0.1 <= hoje && hoje <= $0.2 }
            .max(by: { $0.1 < $1.1 })?.0
        else { return nil }
        guard let dia = (ciclo.dias ?? []).first(where: {
            $0.deletadoEm == nil && calendario.isDate($0.data, inSameDayAs: agora)
        }) else { return nil }
        return (ciclo, dia)
    }

    /// Posição do dia dentro da viagem, 1-based — o "dia 3" do diálogo (§1.3).
    static func numeroDia(_ data: Date, ciclo: CicloSoftex, calendario: Calendar) -> Int {
        guard let (ini, _) = intervaloViagem(ciclo, calendario: calendario) else { return 1 }
        let n = calendario.dateComponents([.day], from: ini, to: calendario.startOfDay(for: data)).day ?? 0
        return n + 1
    }

    /// Mesma gravação do `createNewGasto`, sem passar pelo ViewModel (que
    /// depende de `atualCiclo`, estado de tela): `GastosDia(dia:)` + `insert`,
    /// **sem** `dia.gastos.append` (pegadinha 3 do AGENTS.md),
    /// `gasto_total += valor`, `save()`. `syncStatus` fica `.pending`.
    @discardableResult
    static func gravar(valor: Decimal, titulo: String, categoria: Categoria,
                       dia: DiaSoftex, ciclo: CicloSoftex, em context: ModelContext,
                       id: UUID = UUID()) throws -> GastosDia {
        let gasto = GastosDia(id: id, valor: valor, titulo: titulo, categoria: categoria, dia: dia)
        context.insert(gasto)
        ciclo.gasto_total += gasto.valor
        try context.save()
        return gasto
    }

    /// Estabelecimento → título do gasto: espaços nas pontas fora, espaços
    /// repetidos viram um, vazio vira "Compra no cartão". O Apple Pay costuma
    /// mandar MAIÚSCULAS, que passam por `formatarTitulo`; corta em 60.
    static func tituloDoGasto(_ estabelecimento: String) -> String {
        let limpo = estabelecimento
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let base = limpo.isEmpty ? tituloPadrao : limpo
        return String(InterpretadorComprovante.formatarTitulo(base).prefix(tamanhoTitulo))
    }

    /// Duplicata (§1.4): gasto vivo **ou item na fila** do mesmo usuário com
    /// o mesmo valor e o mesmo estabelecimento (sem acento, sem maiúsculas e
    /// sem espaços repetidos), criado há menos de `janelaDuplicata`.
    ///
    /// Busca por `criadoEm` (persistido) no predicado e filtra valor, título
    /// e usuário em memória (pegadinha 1: nunca `@Transient` no predicado).
    /// Um gasto digitado à mão igual também bloqueia o atalho — efeito
    /// colateral aceito na spec. Duas compras iguais de verdade em menos de
    /// 1 minuto viram uma só: limite conhecido e aceito.
    static func ehDuplicata(valor: Decimal, estabelecimento: String, userId: String,
                            em context: ModelContext, fila: ComprasAguardandoViagem,
                            agora: Date) -> Bool {
        let limite = agora.addingTimeInterval(-janelaDuplicata)
        let alvo = normalizarEstabelecimento(estabelecimento)

        let descricao = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.criadoEm > limite }
        )
        let recentes = (try? context.fetch(descricao)) ?? []
        if recentes.contains(where: {
            $0.dia?.ciclo?.userId == userId
                && $0.valor == valor
                && normalizarEstabelecimento($0.titulo) == alvo
        }) { return true }

        return fila.ler(userId: userId).contains {
            $0.recebidaEm > limite
                && $0.valor == valor
                && normalizarEstabelecimento($0.estabelecimento) == alvo
        }
    }

    private static func guardarNaFila(valor: Decimal, titulo: String, categoria: Categoria,
                                      cartao: String?, userId: String, agora: Date,
                                      fila: ComprasAguardandoViagem) -> ResultadoRegistro {
        fila.guardar(CompraAguardandoViagem(
            id: UUID(), userId: userId, valor: valor, estabelecimento: titulo,
            cartao: cartao, categoria: categoria, recebidaEm: agora))
        return .guardadoSemViagem(titulo: titulo, valor: valor)
    }

    /// Estabelecimento para comparar duplicata: sem acento, sem maiúsculas,
    /// espaços repetidos viram um.
    static func normalizarEstabelecimento(_ texto: String) -> String {
        InterpretadorComprovante.normalizar(texto)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
