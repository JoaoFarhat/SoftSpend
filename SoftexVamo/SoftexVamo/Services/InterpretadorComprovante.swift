

import Foundation

struct GastoLocalExtraido {
    var titulo: String?
    var valor: Decimal?
    var categoria: Categoria?

    var temAlgoUtil: Bool {
        titulo != nil || valor != nil
    }
}

enum InterpretadorComprovante {

    static let rotulosDeTotal = [
        "valor total", "total a pagar", "valor pago", "vlr pago",
        "total r$", "total rs", "total"
    ]

    
    static let rotulosProibidos = [
        "subtotal", "sub total", "troco", "desconto", "acrescimo",
        "taxa", "gorjeta", "servico", "dinheiro", "recebido"
    ]

    static let palavrasPorCategoria: [Categoria: [String]] = [
        .ALIMENTACAO: ["restaurante", "lanchonete", "mercado", "supermercado",
                       "padaria", "ifood", "rappi", "acougue", "hortifruti",
                       "pizza", "burger", "lanche", "cafe", "cafeteria",
                       "pizzaria", "hipermercado", "mercadinho", "minimercado",
                       "churrascaria", "hamburgueria", "sorveteria", "doceria"],
        .TRANSPORTE: ["uber", "taxi", "posto", "combustivel", "gasolina",
                      "etanol", "diesel", "ipiranga", "shell", "petrobras",
                      "estacionamento", "pedagio", "metro", "onibus",
                      "autoposto"],
        .LAZER: ["cinema", "cinemark", "teatro", "show", "netflix", "spotify",
                 "parque", "boate", "ingresso"],
        .COMPRAS: ["farmacia", "drogaria", "drogasil", "magazine", "americanas",
                   "renner", "riachuelo", "amazon", "mercado livre",
                   "mercadolivre", "livraria", "perfumaria"]
    ]

    static func interpretar(linhas: [String]) -> GastoLocalExtraido {
        guard !linhas.isEmpty else { return GastoLocalExtraido() }

        return GastoLocalExtraido(
            titulo: encontrarTitulo(em: linhas),
            valor: encontrarValor(em: linhas),
            categoria: inferirCategoria(de: linhas)
        )
    }

    static func encontrarValor(em linhas: [String]) -> Decimal? {
        for rotulo in rotulosDeTotal {
            for (indice, linha) in linhas.enumerated() {
                let normalizada = normalizar(linha)

                guard normalizada.contains(rotulo),
                      rotulosProibidos.allSatisfy({ !normalizada.contains($0) })
                else { continue }

                if let valor = valoresMonetarios(em: linha).max() {
                    return valor
                }

                if indice + 1 < linhas.count,
                   let valor = valoresMonetarios(em: linhas[indice + 1]).max() {
                    return valor
                }
            }
        }

        return linhas.flatMap { valoresMonetarios(em: $0) }.max()
    }

    static func encontrarTitulo(em linhas: [String]) -> String? {
        // Palavra inteira: "rua" não derruba "Restaurante" nem "nota" derruba
        // "Notável". Só URL e abreviatura com ponto seguem casando por pedaço.
        let ruidoPalavra = ["cnpj", "cpf", "cupom", "fiscal", "nota", "extrato",
                            "rua", "avenida", "inscricao"]
        let ruidoPedaco = ["www", "http", "av."]

        for linha in linhas.prefix(8) {
            let limpa = linha.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizada = normalizar(limpa)
            let palavras = palavrasDo(normalizada)

            guard limpa.count >= 4,
                  limpa.contains(where: { $0.isLetter }),
                  ruidoPedaco.allSatisfy({ !normalizada.contains($0) }),
                  ruidoPalavra.allSatisfy({ !palavras.contains($0) }),
                  // Ignora linhas majoritariamente numericas (data, CNPJ, cupom).
                  limpa.filter({ $0.isNumber }).count * 2 < limpa.count
            else { continue }

            return String(formatarTitulo(limpa).prefix(40))
        }

        return nil
    }

    static func inferirCategoria(de linhas: [String]) -> Categoria? {
        let palavras = palavrasDo(normalizar(linhas.joined(separator: " ")))

        // Expressões de várias palavras casam como sequência de palavras e vêm
        // antes das palavras simples de todas as categorias — sem isso
        // "mercado livre" virava Alimentação pelo "mercado".
        for categoria in Categoria.allCases {
            guard let chaves = palavrasPorCategoria[categoria] else { continue }
            for chave in chaves {
                let termos = palavrasDo(normalizar(chave))
                guard termos.count > 1, contemSequencia(termos, em: palavras)
                else { continue }
                return categoria
            }
        }

        // Palavra simples só casa palavra inteira, ou com "s" no fim:
        // "pizza" casa "pizzas", mas "posto" não casa "impostos" nem
        // "uber" casa "uberlandia".
        for categoria in Categoria.allCases {
            guard let chaves = palavrasPorCategoria[categoria] else { continue }
            for chave in chaves where !chave.contains(" ") {
                if palavras.contains(where: { $0 == chave || $0 == chave + "s" }) {
                    return categoria
                }
            }
        }

        return nil
    }

    /// Quebra o texto normalizado em palavras: tudo que não é letra ou número
    /// separa ("MERCADOLIVRE*LOJA" → ["mercadolivre", "loja"]).
    static func palavrasDo(_ texto: String) -> [String] {
        texto.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func contemSequencia(_ termos: [String], em palavras: [String]) -> Bool {
        guard !termos.isEmpty, termos.count <= palavras.count else { return false }
        return (0...(palavras.count - termos.count)).contains { inicio in
            Array(palavras[inicio..<(inicio + termos.count)]) == termos
        }
    }

    static func valoresMonetarios(em linha: String) -> [Decimal] {
        // O valor não pode estar colado a outro dígito nem a ".", "," ou "/"
        // seguido de dígito — senão o CNPJ "12.345.678/0001-90" soltava
        // "12,34" e "5,67". O ponto final de frase ("R$ 12,50.") segue aceito.
        let padrao = #"(?<![\d.,/])(?:\d{1,3}(?:\.\d{3})+,\d{2}|\d+,\d{2}|\d+\.\d{2})(?!\d|[.,/]\d)"#

        guard let regex = try? NSRegularExpression(pattern: padrao) else { return [] }

        let range = NSRange(linha.startIndex..., in: linha)
        return regex.matches(in: linha, range: range).compactMap { match in
            guard let faixa = Range(match.range, in: linha) else { return nil }

            var texto = String(linha[faixa])

            if texto.contains(",") {
                texto = texto.replacingOccurrences(of: ".", with: "")
                texto = texto.replacingOccurrences(of: ",", with: ".")
            }

            guard let valor = Decimal(string: texto), valor > 0 else { return nil }
            return valor
        }
    }

    static func formatarTitulo(_ texto: String) -> String {
        guard texto == texto.uppercased() else { return texto }

        return texto
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func normalizar(_ texto: String) -> String {
        texto.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: Locale(identifier: "pt_BR"))
    }
}
