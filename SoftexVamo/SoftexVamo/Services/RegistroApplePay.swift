//
//  RegistroApplePay.swift
//  SoftexVamo
//
//  Regra do registro de gasto pelo atalho do Apple Pay (§1.4 de
//  docs/cartao-sem-open-finance.md). Lógica pura e testável: recebe o
//  `ModelContext`, o `userId`, `agora` e `calendario`; a ação só chama isto.
//

import Foundation
import SwiftData
import os

nonisolated enum MotivoRecusa: String, Equatable, Sendable {
    case valorInvalido
    case moedaEstrangeira
    case semUsuario
}

nonisolated enum ResultadoRegistro: Equatable {
    /// Gravou no dia de hoje da viagem aberta.
    case gravado(titulo: String, valor: Decimal, viagem: String, dia: Date)
    /// Sem viagem aberta (ou sem dia local de hoje): foi para a fila (§1.5).
    case guardadoSemViagem(titulo: String, valor: Decimal)
    /// Já registrado (mesma compra chegando duas vezes): nada mudou.
    case duplicado
    case recusado(MotivoRecusa)
}

nonisolated enum ErroRegistro: Error, Equatable {
    /// `lancar` num dia sem viagem ligada (não há `gasto_total` a atualizar).
    case diaSemViagem
}

/// Valor da compra, como texto: "R$ 12,34", "12,34", "12.34", "1.234,56",
/// "1.234" — o que a automação do Atalhos entrega, no idioma do aparelho.
enum ValorDaCompra {
    /// Acima disso é provável erro de leitura; recusa como `.valorInvalido`.
    static let teto: Decimal = 100_000

    /// Devolve o valor em reais, arredondado a 2 casas; `nil` quando o texto
    /// não tem número, é zero ou passa do teto.
    static func interpretar(_ texto: String) -> Decimal? {
        guard var t = limpar(texto) else { return nil }

        // Compra com sinal negativo vira positiva (algumas automações mandam "-12,34").
        t = t.replacingOccurrences(of: "-", with: "")

        if t.contains(",") {
            // Vírgula é decimal; o ponto, quando existe, é milhar.
            t = t.replacingOccurrences(of: ".", with: "")
            t = t.replacingOccurrences(of: ",", with: ".")
        } else if t.contains(".") {
            let partes = t.split(separator: ".", omittingEmptySubsequences: false)
            // Ponto seguido de exatamente 3 dígitos e de mais nada é milhar
            // ("1.234", "12.345.678"); de 1 ou 2 dígitos é decimal ("12.34").
            let ehMilhar = partes.count > 1
                && partes.dropFirst().allSatisfy { $0.count == 3 }
                && partes[0].count >= 1 && partes[0].count <= 3
            if ehMilhar {
                t = t.replacingOccurrences(of: ".", with: "")
            }
        }

        guard let bruto = Decimal(string: t), !bruto.isZero else { return nil }

        var arredondado = Decimal()
        var base = bruto
        NSDecimalRound(&arredondado, &base, 2, .plain)

        guard arredondado <= teto else { return nil }
        return arredondado
    }

    /// Símbolo ou código de outra moeda no texto (`.moedaEstrangeira`): gravar
    /// dólares como reais esconderia o erro; só `R$`, `BRL` ou sem símbolo passam.
    static func temMoedaEstrangeira(_ texto: String) -> Bool {
        let t = texto.uppercased()
        if t.contains("€") || t.contains("£") { return true }
        // "US$" e "$" sozinho recusam; "R$" é a única forma com $ permitida.
        if t.replacingOccurrences(of: "R$", with: "").contains("$") { return true }
        let codigos = ["USD", "EUR", "GBP", "JPY", "ARS", "UYU", "PYG", "CLP",
                       "COP", "MXN", "CAD", "AUD", "CHF", "CNY"]
        return codigos.contains { codigo in
            t.range(of: "\\b\(codigo)\\b", options: .regularExpression) != nil
        }
    }

    /// Tira moeda (`R$`, `BRL`), espaços (inclusive o sem quebra) e valida que
    /// só sobraram dígitos, separadores e sinal. `nil` quando há lixo.
    private static func limpar(_ texto: String) -> String? {
        var t = texto.uppercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        t = t.replacingOccurrences(of: "BRL", with: " ")
        t = t.replacingOccurrences(of: "R$", with: " ")

        let permitidos = CharacterSet(charactersIn: "0123456789.,-").union(.whitespacesAndNewlines)
        guard t.unicodeScalars.allSatisfy({ permitidos.contains($0) }) else { return nil }

        let semEspacos = t.components(separatedBy: .whitespacesAndNewlines).joined()
        return semEspacos.isEmpty ? nil : semEspacos
    }
}

enum RegistroApplePay {
    /// Janela deslizante de duplicata (§1.4): mesma compra chegando duas vezes
    /// em menos de 60 s (o Atalhos às vezes dispara duas vezes, e a automação
    /// do Apple Watch pode repetir).
    static let janelaDuplicata: TimeInterval = 60

    private static let logger = Logger(subsystem: "br.com.softspend", category: "RegistroApplePay")

    /// Registra a compra vinda da automação. Devolve o que aconteceu para a
    /// ação montar o diálogo; só lança erro quando o `save` ou a gravação da
    /// fila falha — a ação responde "lance no app" em vez de "guardado" com a
    /// compra perdida.
    static func registrar(
        valor valorTexto: String,
        estabelecimento: String,
        cartao: String? = nil,
        userId: String?,
        em contexto: ModelContext,
        fila: ComprasAguardandoViagem = .shared,
        agora: Date = .now,
        calendario: Calendar = .current
    ) throws -> ResultadoRegistro {
        guard let userId, !userId.isEmpty else {
            logger.info("Registro recusado: sem usuário salvo")
            return .recusado(.semUsuario)
        }
        guard !ValorDaCompra.temMoedaEstrangeira(valorTexto) else {
            logger.info("Registro recusado: moeda estrangeira")
            return .recusado(.moedaEstrangeira)
        }
        guard let valor = ValorDaCompra.interpretar(valorTexto) else {
            logger.info("Registro recusado: valor inválido")
            return .recusado(.valorInvalido)
        }

        let titulo = tituloDoGasto(estabelecimento)
        let categoria = InterpretadorComprovante.inferirCategoria(de: [estabelecimento]) ?? .OUTROS

        if ehDuplicata(titulo: titulo, valor: valor, userId: userId,
                       em: contexto, fila: fila, agora: agora) {
            logger.info("Registro ignorado: duplicata dentro da janela de 60 s")
            return .duplicado
        }

        if let (ciclo, dia) = viagemEDiaDeHoje(userId: userId, hoje: agora,
                                             calendario: calendario, em: contexto) {
            try gravarGasto(valor: valor, titulo: titulo, categoria: categoria,
                            dia: dia, agora: agora, em: contexto)
            return .gravado(titulo: titulo, valor: valor, viagem: ciclo.titulo, dia: dia.data)
        }

        // Sem viagem aberta ou sem dia local de hoje: guarda na fila (§1.5),
        // nunca num dia errado.
        let cartaoLimpo = cartao?.trimmingCharacters(in: .whitespacesAndNewlines)
        try fila.adicionar(CompraAguardandoViagem(
            id: UUID(), userId: userId, valor: valor, estabelecimento: titulo,
            cartao: cartaoLimpo?.isEmpty == true ? nil : cartaoLimpo,
            categoria: categoria, recebidaEm: agora
        ))
        logger.info("Registro guardado na fila: sem viagem aberta hoje")
        return .guardadoSemViagem(titulo: titulo, valor: valor)
    }

    /// Lança um item da fila "sem viagem" no dia escolhido (§1.5, usado pela
    /// folha do aviso do Início). O item sai da fila só **depois** do `save`:
    /// falhou o save, o item fica. E só grava se o `id` ainda estiver na fila —
    /// a `compras` da folha é uma cópia e um toque duplo em "Lançar" não pode
    /// criar o gasto duas vezes (o segundo toque vira no-op).
    static func lancar(_ compra: CompraAguardandoViagem, em dia: DiaSoftex,
                       contexto: ModelContext,
                       fila: ComprasAguardandoViagem = .shared) throws {
        guard dia.ciclo != nil else { throw ErroRegistro.diaSemViagem }
        guard fila.contem(id: compra.id) else {
            logger.info("Lançar ignorado: a compra \(compra.id, privacy: .public) já saiu da fila")
            return
        }
        // `criadoEm` guarda quando a compra aconteceu, não quando foi lançada.
        try gravarGasto(valor: compra.valor, titulo: compra.estabelecimento,
                        categoria: compra.categoria, dia: dia,
                        agora: compra.recebidaEm, em: contexto)
        fila.remover(id: compra.id)
    }

    /// Viagem do usuário cujo intervalo contém `data` (em sobreposição, a de
    /// primeiro dia mais recente — mesma regra do registro) e o `DiaSoftex`
    /// vivo desse dia. `nil` quando não há onde lançar: a folha "sem viagem"
    /// do Início (§1.5) mostra só "Descartar" nesse caso.
    static func viagemEDia(para data: Date, userId: String, ciclos: [CicloSoftex],
                           calendario: Calendar = .current) -> (ciclo: CicloSoftex, dia: DiaSoftex)? {
        let d = calendario.startOfDay(for: data)
        let contendo = ciclos.compactMap { ciclo -> (CicloSoftex, Date)? in
            guard ciclo.userId == userId, ciclo.deletadoEm == nil,
                  let intervalo = intervaloViagem(ciclo, calendario: calendario),
                  intervalo.ini <= d, d <= intervalo.fim
            else { return nil }
            return (ciclo, intervalo.ini)
        }
        guard let ciclo = contendo.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        guard let dia = (ciclo.dias ?? []).first(where: {
            $0.deletadoEm == nil && calendario.isDate($0.data, inSameDayAs: d)
        }) else { return nil }
        return (ciclo, dia)
    }

    /// Mesma busca de `viagemEDia`, mas lendo os ciclos do `contexto` (como o
    /// registro faz): a folha "sem viagem" usa isto — `allCiclos` do ViewModel
    /// pode ainda não ter carregado e mostraria "Crie a viagem desta data" por
    /// engano.
    static func viagemEDia(para data: Date, userId: String,
                           em contexto: ModelContext,
                           calendario: Calendar = .current) -> (ciclo: CicloSoftex, dia: DiaSoftex)? {
        viagemEDia(para: data, userId: userId,
                   ciclos: ciclosVivos(userId: userId, em: contexto),
                   calendario: calendario)
    }

    // MARK: - Partes da regra

    /// Estabelecimento vira o título: espaços nas pontas e repetidos fora,
    /// MAIÚSCULAS (como o Apple Pay manda) passam por `formatarTitulo`, vazio
    /// vira "Compra no cartão" e corta em 60 caracteres.
    static func tituloDoGasto(_ estabelecimento: String) -> String {
        let limpo = estabelecimento
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let base = limpo.isEmpty ? "Compra no cartão" : InterpretadorComprovante.formatarTitulo(limpo)
        return String(base.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// Comparação de duplicata: sem acento, sem maiúsculas, sem espaços repetidos.
    static func normalizarTitulo(_ texto: String) -> String {
        InterpretadorComprovante.normalizar(texto)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Já existe gasto vivo **ou item na fila** do mesmo usuário com o mesmo
    /// valor e estabelecimento, criado há menos de 60 s.
    private static func ehDuplicata(titulo: String, valor: Decimal, userId: String,
                                    em contexto: ModelContext,
                                    fila: ComprasAguardandoViagem,
                                    agora: Date) -> Bool {
        let limite = agora.addingTimeInterval(-janelaDuplicata)
        let alvo = normalizarTitulo(titulo)

        // `criadoEm` no predicado (persistido); valor e título filtrados em
        // memória (pegadinha 1 do AGENTS.md).
        let desc = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.criadoEm >= limite }
        )
        let recentes = (try? contexto.fetch(desc)) ?? []
        let bateGasto = recentes.contains {
            $0.dia?.ciclo?.userId == userId
                && $0.valor == valor
                && normalizarTitulo($0.titulo) == alvo
        }
        if bateGasto { return true }

        return fila.ler(userId: userId).contains {
            $0.recebidaEm >= limite
                && $0.valor == valor
                && normalizarTitulo($0.estabelecimento) == alvo
        }
    }

    /// Viagem aberta do usuário (intervalo contém hoje; em sobreposição, a de
    /// primeiro dia mais recente — como `cicloDoInicio`, mas sem cair na
    /// "próxima" ou na "última encerrada") e o `DiaSoftex` vivo de hoje nela.
    private static func viagemEDiaDeHoje(userId: String, hoje: Date,
                                         calendario: Calendar,
                                         em contexto: ModelContext) -> (CicloSoftex, DiaSoftex)? {
        viagemEDia(para: hoje, userId: userId, em: contexto, calendario: calendario)
    }

    /// Viagens vivas do usuário, lidas do banco local.
    private static func ciclosVivos(userId: String, em contexto: ModelContext) -> [CicloSoftex] {
        let desc = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.userId == userId && $0.deletadoEm == nil }
        )
        return (try? contexto.fetch(desc)) ?? []
    }

    /// Gravação igual à de `createNewGasto`, sem passar pelo ViewModel (que
    /// depende de `atualCiclo`, estado de tela): `GastosDia` + `insert`, **sem**
    /// `dia.gastos.append` (pegadinha 3 do AGENTS.md), `gasto_total +=` e save.
    /// O `syncStatus` fica `.pending` e o sync sobe como qualquer gasto.
    private static func gravarGasto(valor: Decimal, titulo: String,
                                    categoria: Categoria, dia: DiaSoftex,
                                    agora: Date = .now,
                                    em contexto: ModelContext) throws {
        guard let ciclo = dia.ciclo else { throw ErroRegistro.diaSemViagem }
        let gasto = GastosDia(valor: valor, titulo: titulo, categoria: categoria, dia: dia)
        gasto.criadoEm = agora
        contexto.insert(gasto)
        ciclo.gasto_total += valor
        try contexto.save()
    }
}
