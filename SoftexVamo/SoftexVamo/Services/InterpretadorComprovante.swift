

import Foundation

struct GastoLocalExtraido {
    var titulo: String?
    var valor: Float?
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
                       "pizza", "burger", "lanche", "cafe"],
        .TRANSPORTE: ["uber", "taxi", "posto", "combustivel", "gasolina",
                      "etanol", "diesel", "ipiranga", "shell", "petrobras",
                      "estacionamento", "pedagio", "metro", "onibus"],
        .LAZER: ["cinema", "cinemark", "teatro", "show", "netflix", "spotify",
                 "parque", "boate", "ingresso"],
        .COMPRAS: ["farmacia", "drogaria", "drogasil", "magazine", "americanas",
                   "renner", "riachuelo", "amazon", "mercado livre", "livraria",
                   "perfumaria"]
    ]

    static func interpretar(linhas: [String]) -> GastoLocalExtraido {
        guard !linhas.isEmpty else { return GastoLocalExtraido() }

        return GastoLocalExtraido(
            titulo: encontrarTitulo(em: linhas),
            valor: encontrarValor(em: linhas),
            categoria: inferirCategoria(de: linhas)
        )
    }

    static func encontrarValor(em linhas: [String]) -> Float? {
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
        let ruido = ["cnpj", "cpf", "cupom", "fiscal", "nota", "extrato",
                     "www", "http", "rua", "av.", "avenida", "inscricao"]

        for linha in linhas.prefix(8) {
            let limpa = linha.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizada = normalizar(limpa)

            guard limpa.count >= 4,
                  limpa.contains(where: { $0.isLetter }),
                  ruido.allSatisfy({ !normalizada.contains($0) }),
                  // Ignora linhas majoritariamente numericas (data, CNPJ, cupom).
                  limpa.filter({ $0.isNumber }).count * 2 < limpa.count
            else { continue }

            return String(formatarTitulo(limpa).prefix(40))
        }

        return nil
    }

    static func inferirCategoria(de linhas: [String]) -> Categoria? {
        let texto = normalizar(linhas.joined(separator: " "))

        for categoria in Categoria.allCases {
            guard let palavras = palavrasPorCategoria[categoria] else { continue }
            if palavras.contains(where: { texto.contains($0) }) {
                return categoria
            }
        }

        return nil
    }

    static func valoresMonetarios(em linha: String) -> [Float] {
        let padrao = #"\d{1,3}(?:\.\d{3})+,\d{2}|\d+,\d{2}|\d+\.\d{2}"#

        guard let regex = try? NSRegularExpression(pattern: padrao) else { return [] }

        let range = NSRange(linha.startIndex..., in: linha)
        return regex.matches(in: linha, range: range).compactMap { match in
            guard let faixa = Range(match.range, in: linha) else { return nil }

            var texto = String(linha[faixa])

            if texto.contains(",") {
                texto = texto.replacingOccurrences(of: ".", with: "")
                texto = texto.replacingOccurrences(of: ",", with: ".")
            }

            guard let valor = Float(texto), valor > 0 else { return nil }
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
