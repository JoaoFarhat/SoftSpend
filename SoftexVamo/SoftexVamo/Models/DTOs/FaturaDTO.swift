//
//  FaturaDTO.swift
//  SoftSpend
//
//  DTOs da fatura importada por arquivo (§2.4–2.6 de
//  docs/cartao-sem-open-finance.md). `POST /api/faturas/ler` devolve a prévia
//  `FaturaLida`; o corpo de `POST /api/faturas` é a mesma `FaturaLida`, já sem
//  as compras que a pessoa tirou da conferência.
//
//  Atenção à data: o backend serializa `date` como "2026-07-21" (dia inteiro,
//  sem hora nem fuso) e o `JSONDecoder` compartilhado só aceita ISO com hora.
//  Por isso `data`, `fechamento` e `vencimento` têm codificação própria, como
//  início do dia no fuso do aparelho — assim `Calendar.isDate(_:inSameDayAs:)`
//  casa com os `DiaSoftex` locais.
//

import Foundation

/// "2026-07-21" ⇄ `Date` no fuso local.
nonisolated private let formatoDiaFatura: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// Vínculo sugerido na prévia: ainda não é um match gravado (não tem id);
/// o `gasto_id` é o backendId do gasto que bateu.
nonisolated struct MatchPreviaFatura: Codable, Sendable, Equatable {
    let gastoId: Int
    let score: Int
    let status: String

    var matchStatus: OpenFinanceMatchStatus? {
        OpenFinanceMatchStatus(rawValue: status)
    }

    enum CodingKeys: String, CodingKey {
        case gastoId = "gasto_id"
        case score
        case status
    }
}

nonisolated enum TipoCompraFatura: String, Codable, Sendable {
    case compra = "COMPRA"
    case estorno = "ESTORNO"
    case encargo = "ENCARGO"

    var rotulo: String {
        switch self {
        case .compra: return "Compra"
        case .estorno: return "Estorno"
        case .encargo: return "Encargo"
        }
    }
}

nonisolated struct CompraLida: Sendable, Identifiable {
    let indice: Int
    let data: Date
    let descricao: String
    let valor: Decimal
    let parcelaAtual: Int?
    let parcelaTotal: Int?
    let tipo: TipoCompraFatura
    let categoria: Categoria
    let valorOriginal: String?
    var dentroDaViagem: Bool
    let diaId: Int?
    var match: MatchPreviaFatura?

    var id: Int { indice }

    /// "parcela 2 de 5", como a conferência mostra (§2.5).
    var textoParcela: String? {
        guard let parcelaAtual, let parcelaTotal, parcelaTotal > 1 else { return nil }
        return "parcela \(parcelaAtual) de \(parcelaTotal)"
    }

    init(
        indice: Int,
        data: Date,
        descricao: String,
        valor: Decimal,
        parcelaAtual: Int? = nil,
        parcelaTotal: Int? = nil,
        tipo: TipoCompraFatura = .compra,
        categoria: Categoria = .OUTROS,
        valorOriginal: String? = nil,
        dentroDaViagem: Bool = false,
        diaId: Int? = nil,
        match: MatchPreviaFatura? = nil
    ) {
        self.indice = indice
        self.data = data
        self.descricao = descricao
        self.valor = valor
        self.parcelaAtual = parcelaAtual
        self.parcelaTotal = parcelaTotal
        self.tipo = tipo
        self.categoria = categoria
        self.valorOriginal = valorOriginal
        self.dentroDaViagem = dentroDaViagem
        self.diaId = diaId
        self.match = match
    }
}

extension CompraLida: Codable {
    enum CodingKeys: String, CodingKey {
        case indice, data, descricao, valor, categoria, match, tipo
        case parcelaAtual = "parcela_atual"
        case parcelaTotal = "parcela_total"
        case valorOriginal = "valor_original"
        case dentroDaViagem = "dentro_da_viagem"
        case diaId = "dia_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        indice = try c.decode(Int.self, forKey: .indice)
        let textoData = try c.decode(String.self, forKey: .data)
        guard let d = formatoDiaFatura.date(from: textoData) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data, in: c,
                debugDescription: "Data inválida: \(textoData)"
            )
        }
        data = d
        descricao = try c.decode(String.self, forKey: .descricao)
        valor = try c.decode(Decimal.self, forKey: .valor)
        parcelaAtual = try c.decodeIfPresent(Int.self, forKey: .parcelaAtual)
        parcelaTotal = try c.decodeIfPresent(Int.self, forKey: .parcelaTotal)
        tipo = try c.decodeIfPresent(TipoCompraFatura.self, forKey: .tipo) ?? .compra
        categoria = try c.decodeIfPresent(Categoria.self, forKey: .categoria) ?? .OUTROS
        valorOriginal = try c.decodeIfPresent(String.self, forKey: .valorOriginal)
        dentroDaViagem = try c.decodeIfPresent(Bool.self, forKey: .dentroDaViagem) ?? false
        diaId = try c.decodeIfPresent(Int.self, forKey: .diaId)
        match = try c.decodeIfPresent(MatchPreviaFatura.self, forKey: .match)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(indice, forKey: .indice)
        try c.encode(formatoDiaFatura.string(from: data), forKey: .data)
        try c.encode(descricao, forKey: .descricao)
        try c.encode(valor, forKey: .valor)
        try c.encodeIfPresent(parcelaAtual, forKey: .parcelaAtual)
        try c.encodeIfPresent(parcelaTotal, forKey: .parcelaTotal)
        try c.encode(tipo, forKey: .tipo)
        try c.encode(categoria, forKey: .categoria)
        try c.encodeIfPresent(valorOriginal, forKey: .valorOriginal)
        try c.encode(dentroDaViagem, forKey: .dentroDaViagem)
        try c.encodeIfPresent(diaId, forKey: .diaId)
        try c.encodeIfPresent(match, forKey: .match)
    }
}

/// Prévia devolvida por `POST /api/faturas/ler` e enviada (filtrada) a
/// `POST /api/faturas`. Nada disto é gravado pelo `ler` (§2.1).
nonisolated struct FaturaLida: Sendable {
    let emissor: String?
    let finalCartao: String?
    let fechamento: Date?
    /// `var`: o "Importar" preenche com a data informada na conferência
    /// quando o arquivo não trouxe o vencimento (sem ela o POST dá 422).
    var vencimento: Date?
    let totalFatura: Decimal?
    let moeda: String
    let somaConfere: Bool?
    let diferenca: Decimal?
    let avisos: [String]
    var compras: [CompraLida]

    init(
        emissor: String? = nil,
        finalCartao: String? = nil,
        fechamento: Date? = nil,
        vencimento: Date? = nil,
        totalFatura: Decimal? = nil,
        moeda: String = "BRL",
        somaConfere: Bool? = nil,
        diferenca: Decimal? = nil,
        avisos: [String] = [],
        compras: [CompraLida] = []
    ) {
        self.emissor = emissor
        self.finalCartao = finalCartao
        self.fechamento = fechamento
        self.vencimento = vencimento
        self.totalFatura = totalFatura
        self.moeda = moeda
        self.somaConfere = somaConfere
        self.diferenca = diferenca
        self.avisos = avisos
        self.compras = compras
    }
}

extension FaturaLida: Codable {
    enum CodingKeys: String, CodingKey {
        case emissor, moeda, avisos, compras
        case finalCartao = "final_cartao"
        case fechamento, vencimento
        case totalFatura = "total_fatura"
        case somaConfere = "soma_confere"
        case diferenca
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emissor = try c.decodeIfPresent(String.self, forKey: .emissor)
        finalCartao = try c.decodeIfPresent(String.self, forKey: .finalCartao)
        fechamento = try Self.dia(c, chave: .fechamento)
        vencimento = try Self.dia(c, chave: .vencimento)
        totalFatura = try c.decodeIfPresent(Decimal.self, forKey: .totalFatura)
        moeda = try c.decodeIfPresent(String.self, forKey: .moeda) ?? "BRL"
        somaConfere = try c.decodeIfPresent(Bool.self, forKey: .somaConfere)
        diferenca = try c.decodeIfPresent(Decimal.self, forKey: .diferenca)
        avisos = try c.decodeIfPresent([String].self, forKey: .avisos) ?? []
        compras = try c.decodeIfPresent([CompraLida].self, forKey: .compras) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(emissor, forKey: .emissor)
        try c.encodeIfPresent(finalCartao, forKey: .finalCartao)
        try c.encodeIfPresent(fechamento.map(formatoDiaFatura.string), forKey: .fechamento)
        try c.encodeIfPresent(vencimento.map(formatoDiaFatura.string), forKey: .vencimento)
        try c.encodeIfPresent(totalFatura, forKey: .totalFatura)
        try c.encode(moeda, forKey: .moeda)
        try c.encodeIfPresent(somaConfere, forKey: .somaConfere)
        try c.encodeIfPresent(diferenca, forKey: .diferenca)
        try c.encode(avisos, forKey: .avisos)
        try c.encode(compras, forKey: .compras)
    }

    private static func dia(
        _ c: KeyedDecodingContainer<CodingKeys>, chave: CodingKeys
    ) throws -> Date? {
        guard let texto = try c.decodeIfPresent(String.self, forKey: chave) else { return nil }
        guard let d = formatoDiaFatura.date(from: texto) else {
            throw DecodingError.dataCorruptedError(
                forKey: chave, in: c,
                debugDescription: "Data inválida: \(texto)"
            )
        }
        return d
    }
}
