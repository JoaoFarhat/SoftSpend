import Testing
import Foundation
@testable import SoftSpend

/// O servidor devolve `422` com `error` = `total_da_viagem_acima_do_limite`
/// quando um gasto levaria o total da viagem além de R$ 99.999.999,99
/// (PR #165). O `NetworkManager.execute` joga esse código no `message` do
/// `APIError.serverError` e o `SyncActor` grava o `localizedDescription` no
/// `syncError` — sem a tradução, a tela mostrava o código cru.
struct MensagemErroServidorTests {

    /// 422 com o código: a frase em português, não o código.
    @Test func totalAcimaDoLimiteViraFraseClara() {
        let erro = APIError.serverError(
            message: APIError.codigoTotalViagemAcimaDoLimite,
            requestId: "req-1", statusCode: 422)
        #expect(erro.localizedDescription ==
            "O total da viagem passaria de R$ 99.999.999,99. Diminua o valor ou apague outro gasto.")
    }

    /// O mesmo código com outro status não traduz: devolve a `message`.
    @Test func mesmoCodigoComOutroStatusDevolveMessage() {
        let erro = APIError.serverError(
            message: APIError.codigoTotalViagemAcimaDoLimite,
            requestId: "req-1", statusCode: 500)
        #expect(erro.localizedDescription == APIError.codigoTotalViagemAcimaDoLimite)
    }

    /// Outro 422 qualquer continua devolvendo a `message` como hoje.
    @Test func outroQuatrocentosEVinteEDoisDevolveMessage() {
        let erro = APIError.serverError(
            message: "validation error", requestId: "req-1", statusCode: 422)
        #expect(erro.localizedDescription == "validation error")
    }

    /// `assinaturaNecessaria` e `limiteDiarioIA` comparam a `message`, que
    /// não mudou: 403 `subscription_required` e 429 `daily_ai_limit` seguem
    /// iguais — inclusive a descrição, que continua sendo a `message`.
    @Test func assinaturaELimiteDiarioSeguemIguais() {
        let assinatura = APIError.serverError(
            message: APIError.codigoAssinaturaNecessaria,
            requestId: "req-1", statusCode: 403)
        #expect(assinatura.assinaturaNecessaria)
        #expect(assinatura.localizedDescription == APIError.codigoAssinaturaNecessaria)

        let limiteIA = APIError.serverError(
            message: APIError.codigoLimiteDiarioIA,
            requestId: "req-1", statusCode: 429)
        #expect(limiteIA.limiteDiarioIA)
        #expect(limiteIA.localizedDescription == APIError.codigoLimiteDiarioIA)
    }
}
