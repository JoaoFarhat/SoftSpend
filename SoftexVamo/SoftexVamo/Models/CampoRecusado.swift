//
//  CampoRecusado.swift
//  SoftexVamo
//

import Foundation

/// Nome amigável do campo que o servidor recusou no 422 de validação (a
/// chave `campos` do corpo — `Python/middlewares.py`). Com ele o gasto ou o
/// dia que não sobe diz o que editar, em vez do genérico "Dados de entrada
/// invalidos" gravado no `syncError`.
///
/// `nonisolated` e sem estado: o `execute` do `NetworkManager` monta a frase
/// de qualquer isolamento.
nonisolated enum CampoRecusado {
    /// O nome técnico (o `loc` do erro) vira o que a pessoa vê na tela.
    /// Campo que o app não conhece cai no genérico "um dos dados".
    static func nome(_ campo: String) -> String {
        switch campo {
        case "data": "a data"
        case "diaria": "a diária"
        case "valor", "valor_total": "o valor"
        case "titulo": "o nome"
        case "periodo": "o período"
        case "categoria": "a categoria"
        default: "um dos dados"
        }
    }

    /// "O servidor não aceitou <lista>. Edite ou apague este item." — dois ou
    /// mais nomes unidos por vírgula e "e", sem repetir (`valor` e
    /// `valor_total` viram um só "o valor"). `nil`/vazio devolve `nil`: o 422
    /// segue com a mensagem do servidor, como antes — inclusive o
    /// `total_da_viagem_acima_do_limite` (#166), que não traz `campos`.
    static func mensagem(campos: [String]?) -> String? {
        guard let campos, !campos.isEmpty else { return nil }
        var vistos = Set<String>()
        var nomes: [String] = []
        for campo in campos {
            let traduzido = nome(campo)
            if vistos.insert(traduzido).inserted {
                nomes.append(traduzido)
            }
        }
        let lista = nomes.count == 1
            ? nomes[0]
            : nomes.dropLast().joined(separator: ", ") + " e " + nomes.last!
        return "O servidor não aceitou \(lista). Edite ou apague este item."
    }
}
