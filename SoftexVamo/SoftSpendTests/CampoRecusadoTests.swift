import Testing
import Foundation
@testable import SoftSpend

/// O 422 de validação traz `campos` com o que o servidor recusou
/// (`Python/middlewares.py`): o item mostra o que editar em vez do genérico
/// "Dados de entrada invalidos". Sem a chave — servidor antigo ou outro 422,
/// como o `total_da_viagem_acima_do_limite` — a mensagem do servidor fica.
struct CampoRecusadoTests {
    @Test func umCampo() {
        #expect(CampoRecusado.mensagem(campos: ["data"])
            == "O servidor não aceitou a data. Edite ou apague este item.")
    }

    @Test func doisCamposComE() {
        #expect(CampoRecusado.mensagem(campos: ["titulo", "valor"])
            == "O servidor não aceitou o nome e o valor. Edite ou apague este item.")
    }

    @Test func tresCamposComVirgulaEE() {
        #expect(CampoRecusado.mensagem(campos: ["data", "diaria", "categoria"])
            == "O servidor não aceitou a data, a diária e a categoria. Edite ou apague este item.")
    }

    @Test func campoDesconhecido() {
        #expect(CampoRecusado.mensagem(campos: ["qualquer"])
            == "O servidor não aceitou um dos dados. Edite ou apague este item.")
    }

    @Test func repetidosAparecemUmaVez() {
        // `valor` e `valor_total` traduzem o mesmo nome; o repetido some.
        #expect(CampoRecusado.mensagem(campos: ["valor", "valor_total", "valor"])
            == "O servidor não aceitou o valor. Edite ou apague este item.")
    }

    @Test func semCamposNadaMuda() {
        #expect(CampoRecusado.mensagem(campos: nil) == nil)
        #expect(CampoRecusado.mensagem(campos: []) == nil)
    }

    @Test func respostaDecodificaComCampos() throws {
        let json = #"{"error": "Dados de entrada invalidos", "request_id": "r-1", "campos": ["data"]}"#
            .data(using: .utf8)!
        let resposta = try JSONDecoder().decode(APIErrorResponse.self, from: json)
        #expect(resposta.error == "Dados de entrada invalidos")
        #expect(resposta.request_id == "r-1")
        #expect(resposta.campos == ["data"])
    }

    @Test func respostaDecodificaSemCampos() throws {
        // Servidor antigo ou outro 422 (ex.: `total_da_viagem_acima_do_limite`):
        // a chave não vem e a decodificação não pode quebrar.
        let json = #"{"error": "total_da_viagem_acima_do_limite", "request_id": "r-2"}"#
            .data(using: .utf8)!
        let resposta = try JSONDecoder().decode(APIErrorResponse.self, from: json)
        #expect(resposta.error == "total_da_viagem_acima_do_limite")
        #expect(resposta.campos == nil)
    }
}
