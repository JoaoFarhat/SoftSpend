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

    /// Frase do 422 no login e no cadastro: diz o que corrigir, sem falar
    /// de "item" — nessa tela ainda não existe nada gravado. `email` e
    /// `username` viram a mesma frase (o `username` enviado sai do e-mail,
    /// ver `usernameDoEmail`). Vários campos juntam as frases com um
    /// espaço, sem repetir, na ordem recebida; campo desconhecido é
    /// ignorado — sozinho, com `nil` ou vazio, sai o genérico "Confira os
    /// dados digitados.". Sempre devolve frase: o formulário precisa
    /// mostrar algo.
    static func mensagemConta(campos: [String]?) -> String {
        let generica = "Confira os dados digitados."
        guard let campos else { return generica }
        var vistos = Set<String>()
        var frases: [String] = []
        for campo in campos {
            let frase: String
            switch campo {
            case "email", "username":
                frase = "Confira o e-mail digitado."
            case "nome":
                frase = "O nome pode ter até 100 caracteres."
            case "senha":
                frase = "A senha precisa ter de 8 a 128 caracteres, com letra maiúscula, minúscula, número e caractere especial."
            default:
                continue
            }
            if vistos.insert(frase).inserted {
                frases.append(frase)
            }
        }
        return frases.isEmpty ? generica : frases.joined(separator: " ")
    }
}
