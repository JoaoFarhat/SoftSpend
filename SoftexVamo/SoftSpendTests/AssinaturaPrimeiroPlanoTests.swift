import Testing
import Foundation
@testable import SoftSpend

/// `voltouAoPrimeiroPlano()` (`.active` da cena): quem pagou com o servidor
/// fora fica com a transação sem `finish()` e ela não volta pelo
/// `Transaction.updates` — o reenvio ao voltar ao primeiro plano destrava a
/// assinatura sem a pessoa precisar reabrir o app.
@MainActor
struct AssinaturaPrimeiroPlanoTests {
    /// Usuário logado trocável pelo teste (o padrão de produção lê o `AuthService`).
    final class Sessao {
        var userId: String? = "usuario-1"
        var sincronizacoes = 0
    }

    let linha: LinhaDoTempo
    let loja: FakeLojaAssinatura
    let api: FakeAssinaturaAPI
    let sessao: Sessao
    let vm: AssinaturaViewModel

    init() {
        let linha = LinhaDoTempo()
        let sessao = Sessao()
        self.linha = linha
        self.sessao = sessao
        loja = FakeLojaAssinatura(linha: linha)
        api = FakeAssinaturaAPI(linha: linha)
        vm = AssinaturaViewModel(
            loja: loja,
            api: api,
            usuarioLogado: { sessao.userId },
            sincronizar: { sessao.sincronizacoes += 1 }
        )
    }

    private func assinante(_ status: String = "active") -> AssinaturaResponse {
        AssinaturaResponse(
            status: status, temAcesso: true, expiraEm: .now.addingTimeInterval(86_400),
            produto: ProdutoAssinatura.mensal, appAccountToken: FakeAssinaturaAPI.token.uuidString
        )
    }

    @Test func comLoginReenviaPendenteEFinaliza() async {
        loja.pendentes = [loja.transacao(id: 50, token: FakeAssinaturaAPI.token)]
        api.depoisDeAceitar = assinante()

        await vm.voltouAoPrimeiroPlano()

        #expect(api.jwsRecebidos == ["jws-50"])
        #expect(linha.passos == ["enviar:jws-50", "finish:50"])
        // Estado relido: uma leitura do `carregarEstado` + outra depois da
        // transação aceita.
        #expect(api.leituras == 2)
        #expect(vm.estado?.status == "active")
        #expect(sessao.sincronizacoes == 1)
    }

    @Test func semLoginNaoLeNemEnvia() async {
        sessao.userId = nil
        loja.pendentes = [loja.transacao(id: 51, token: FakeAssinaturaAPI.token)]

        await vm.voltouAoPrimeiroPlano()

        #expect(api.leituras == 0)
        #expect(api.jwsRecebidos.isEmpty)
        #expect(linha.passos.isEmpty)
    }

    @Test func duasChamadasJuntasEnviamUmaVezSo() async {
        loja.pendentes = [loja.transacao(id: 52, token: FakeAssinaturaAPI.token)]

        async let primeira: Void = vm.voltouAoPrimeiroPlano()
        async let segunda: Void = vm.voltouAoPrimeiroPlano()
        _ = await (primeira, segunda)

        #expect(api.jwsRecebidos == ["jws-52"])
        #expect(linha.passos.contains("finish:52"))
    }

    @Test func servidorForaNaoFinalizaEVoltaNaProximaChamada() async {
        loja.pendentes = [loja.transacao(id: 53, token: FakeAssinaturaAPI.token)]
        api.erroAoEnviar = APIError.serverError(
            message: "Tente de novo em instantes.", requestId: "-", statusCode: 503)

        await vm.voltouAoPrimeiroPlano()

        #expect(api.jwsRecebidos == ["jws-53"])
        #expect(!linha.passos.contains("finish:53"))

        // Servidor de volta (app ativado de novo): envia e finaliza.
        api.erroAoEnviar = nil
        await vm.voltouAoPrimeiroPlano()

        #expect(api.jwsRecebidos == ["jws-53", "jws-53"])
        #expect(linha.passos.last == "finish:53")
    }
}
