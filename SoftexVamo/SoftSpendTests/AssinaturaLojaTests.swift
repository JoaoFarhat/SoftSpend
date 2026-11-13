import Testing
import Foundation
@testable import SoftSpend

/// I1 de docs/assinatura.md §3.2, com loja e servidor falsos (sem StoreKit):
/// compra, restauração, reenvio de compras pendentes e textos da tela.
/// Compra real só no Mac (Xcode) e no TestFlight.
@MainActor
struct AssinaturaLojaTests {
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

    private var mensal: PlanoLoja { loja.planos[0] }

    private func assinante(_ status: String = "active") -> AssinaturaResponse {
        AssinaturaResponse(
            status: status, temAcesso: true, expiraEm: .now.addingTimeInterval(86_400),
            produto: ProdutoAssinatura.mensal, appAccountToken: FakeAssinaturaAPI.token.uuidString
        )
    }

    /// Espera uma condição que depende de uma `Task` em segundo plano.
    private func esperar(_ condicao: () -> Bool) async throws {
        for _ in 0..<200 {
            if condicao() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Comprar

    @Test func compraAprovadaVaiAoServidorEsoDepoisFinaliza() async {
        loja.resultadoCompra = .aprovada(loja.transacao(id: 1, token: FakeAssinaturaAPI.token))
        api.depoisDeAceitar = assinante("trial")

        await vm.comprar(mensal)

        #expect(loja.compras.count == 1)
        #expect(loja.compras.first?.planoId == ProdutoAssinatura.mensal)
        // O token da compra é o `app_account_token` do servidor.
        #expect(loja.compras.first?.token == FakeAssinaturaAPI.token)
        #expect(api.jwsRecebidos == ["jws-1"])
        #expect(linha.passos == ["comprar", "enviar:jws-1", "finish:1"])
        #expect(vm.estado?.status == "trial")
        #expect(vm.mensagem == nil)
        #expect(sessao.sincronizacoes == 1)
        #expect(vm.ocupado == false)
    }

    @Test func servidorForaDepoisDaCompraNaoFinalizaNemCobraDeNovo() async {
        loja.resultadoCompra = .aprovada(loja.transacao(id: 1, token: FakeAssinaturaAPI.token))
        api.erroAoEnviar = APIError.serverError(message: "Tente de novo em instantes.", requestId: "-", statusCode: 503)

        await vm.comprar(mensal)

        #expect(api.jwsRecebidos == ["jws-1"])
        #expect(!linha.passos.contains("finish:1"))
        #expect(vm.mensagem == .confirmandoComServidor)
        #expect(sessao.sincronizacoes == 0)
        #expect(loja.compras.count == 1)
    }

    @Test func compraPendenteMostraAguardandoAprovacao() async {
        loja.resultadoCompra = .pendente
        await vm.comprar(mensal)
        #expect(vm.mensagem == .aguardandoAprovacao)
        #expect(api.jwsRecebidos.isEmpty)
    }

    @Test func compraCanceladaVoltaSemMensagem() async {
        loja.resultadoCompra = .cancelada
        await vm.comprar(mensal)
        #expect(vm.mensagem == nil)
        #expect(api.jwsRecebidos.isEmpty)
    }

    @Test func compraNaoVerificadaNaoDestravaNada() async {
        loja.resultadoCompra = .naoVerificada
        await vm.comprar(mensal)
        #expect(vm.mensagem?.ehFalha == true)
        #expect(api.jwsRecebidos.isEmpty)
        #expect(sessao.sincronizacoes == 0)
    }

    @Test func semEstadoDoServidorNaoAbreACompra() async {
        api.erroAoObter = URLError(.notConnectedToInternet)
        await vm.comprar(mensal)
        #expect(loja.compras.isEmpty)
        #expect(vm.mensagem?.ehFalha == true)
    }

    @Test func compraDeOutraContaNaoFinalizaNemRepete() async {
        let transacao = loja.transacao(id: 7, token: FakeAssinaturaAPI.token)
        loja.resultadoCompra = .aprovada(transacao)
        api.erroAoEnviar = APIError.serverError(
            message: "Esta assinatura pertence a outra conta do SoftSpend.", requestId: "-", statusCode: 409)

        await vm.comprar(mensal)
        #expect(vm.mensagem == .outraConta)

        // A mesma transação de novo (updates/unfinished) não volta ao servidor.
        #expect(await vm.enviar(transacao) == .outraConta)
        #expect(api.jwsRecebidos == ["jws-7"])
        #expect(!linha.passos.contains("finish:7"))
    }

    @Test func transacaoComTokenDeOutraContaNemVaiAoServidor() async {
        await vm.carregarEstado()
        let deOutro = loja.transacao(id: 3, token: UUID())
        #expect(await vm.enviar(deOutro) == .outraConta)
        #expect(api.jwsRecebidos.isEmpty)
        #expect(linha.passos.isEmpty)
    }

    @Test func outroErroDoServidorNaoViraOutraConta() async {
        api.erroAoEnviar = APIError.serverError(message: "Comprovante da compra inválido.", requestId: "-", statusCode: 400)
        let transacao = loja.transacao(id: 4, token: FakeAssinaturaAPI.token)
        #expect(await vm.enviar(transacao) == .falhou)
        // Não fica marcada como recusada: tenta de novo depois.
        api.erroAoEnviar = nil
        #expect(await vm.enviar(transacao) == .aceita)
        #expect(linha.passos.last == "finish:4")
    }

    // MARK: Transaction.updates e pendentes

    @Test func atualizacaoSemLoginEsperaOLoginParaEnviar() async throws {
        sessao.userId = nil
        let transacao = loja.transacao(id: 9, token: FakeAssinaturaAPI.token)
        loja.pendentes = [transacao]
        vm.iniciar()
        loja.emitir(transacao)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(api.jwsRecebidos.isEmpty)
        #expect(linha.passos.isEmpty)

        // Login: relê o estado e reenvia a pendente com a conta logada.
        sessao.userId = "usuario-1"
        api.depoisDeAceitar = assinante()
        await vm.trocouUsuario()

        #expect(api.jwsRecebidos == ["jws-9"])
        #expect(linha.passos == ["enviar:jws-9", "finish:9"])
        #expect(vm.estado?.status == "active")
        #expect(sessao.sincronizacoes == 1)
    }

    @Test func atualizacaoComLoginEnviaEFinaliza() async throws {
        vm.iniciar()
        api.depoisDeAceitar = assinante()
        loja.emitir(loja.transacao(id: 11, token: FakeAssinaturaAPI.token))
        try await esperar { linha.passos.contains("finish:11") }
        let ultimos = Array(linha.passos.suffix(2))
        #expect(ultimos == ["enviar:jws-11", "finish:11"])
        try await esperar { sessao.sincronizacoes == 1 }
        #expect(sessao.sincronizacoes == 1)
    }

    @Test func trocarDeContaEsqueceOEstadoAnterior() async {
        api.estado = assinante()
        await vm.carregarEstado()
        #expect(vm.jaAssina)

        sessao.userId = nil
        await vm.trocouUsuario()
        #expect(vm.estado == nil)
        #expect(vm.jaAssina == false)
    }

    // MARK: Restaurar

    @Test func restaurarReenviaDireitosEPendentesSemDuplicar() async {
        let a = loja.transacao(id: 21, token: FakeAssinaturaAPI.token)
        let b = loja.transacao(id: 22, token: nil)
        loja.direitos = [a]
        loja.pendentes = [a, b]
        api.depoisDeAceitar = assinante()

        await vm.restaurar()

        #expect(loja.sincronizacoes == 1)
        #expect(api.jwsRecebidos == ["jws-21", "jws-22"])
        #expect(vm.mensagem == .restaurada)
        #expect(sessao.sincronizacoes == 1)
    }

    @Test func restaurarSemNadaDizQueNaoEncontrou() async {
        await vm.restaurar()
        #expect(vm.mensagem == .naoEncontrada)
        #expect(sessao.sincronizacoes == 0)
    }

    @Test func restaurarCanceladoNaoMostraNada() async {
        loja.erroAoSincronizar = ErroLoja.cancelado
        loja.direitos = [loja.transacao(id: 30, token: FakeAssinaturaAPI.token)]
        await vm.restaurar()
        #expect(vm.mensagem == nil)
        #expect(api.jwsRecebidos.isEmpty)
    }

    @Test func restaurarDeOutraContaAvisa() async {
        loja.direitos = [loja.transacao(id: 31, token: FakeAssinaturaAPI.token)]
        api.erroAoEnviar = APIError.serverError(message: "-", requestId: "-", statusCode: 409)
        await vm.restaurar()
        #expect(vm.mensagem == .outraConta)
    }

    // MARK: Planos

    @Test func carregaPlanosMensalAntesDoAnual() async {
        await vm.carregarPlanos()
        let periodos: [PeriodoPlano] = vm.planos.map { $0.periodo }
        #expect(periodos == [.mensal, .anual])
        #expect(vm.erroAoCarregarPlanos == nil)
    }

    @Test func lojaSemProdutosOuForaDoArMostraErroDosPlanos() async {
        loja.planos = []
        await vm.carregarPlanos()
        #expect(vm.erroAoCarregarPlanos == AssinaturaViewModel.erroPlanos)

        loja.erroAoCarregar = URLError(.notConnectedToInternet)
        await vm.carregarPlanos()
        #expect(vm.erroAoCarregarPlanos == AssinaturaViewModel.erroPlanos)
    }

    @Test func textosDoTesteGratisVemDaOferta() {
        #expect(OfertaGratis(valor: 2, unidade: .semana).texto == "14 dias")
        #expect(OfertaGratis(valor: 14, unidade: .dia).texto == "14 dias")
        #expect(OfertaGratis(valor: 1, unidade: .mes).texto == "1 mês")
        #expect(OfertaGratis(valor: 3, unidade: .mes).texto == "3 meses")
        #expect(mensal.textoDepoisDoTeste == "Depois, R$ 14,90 por mês")
        #expect(loja.planos[1].textoDepoisDoTeste == "Depois, R$ 144,90 por ano")
        #expect(PeriodoPlano.mensal.duracao == "1 mês")
        #expect(PeriodoPlano.anual.duracao == "1 ano")
    }

    // MARK: Estado na tela

    @Test func estadoDaTelaPorStatus() async {
        #expect(vm.resumo == "Ver planos")

        let casos: [(String, Bool, Bool)] = [
            ("none", false, false), ("trial", true, false), ("active", true, false),
            ("grace", true, true), ("billing_retry", true, true),
            ("expired", false, false), ("revoked", false, false)
        ]
        for (status, jaAssina, falhando) in casos {
            api.estado = assinante(status)
            await vm.carregarEstado()
            let assina = vm.jaAssina
            let pagamento = vm.pagamentoFalhando
            #expect(assina == jaAssina)
            #expect(pagamento == falhando)
        }
        api.estado = assinante("active")
        await vm.carregarEstado()
        #expect(vm.resumo == "Plano mensal")
        #expect(vm.nomeDoPlano == "Mensal")
    }

    @Test func falhaAoLerOEstadoMantemOAnterior() async {
        api.estado = assinante()
        await vm.carregarEstado()
        api.erroAoObter = URLError(.timedOut)
        await vm.carregarEstado()
        #expect(vm.estado?.status == "active")
    }

    @Test func semLoginNaoChamaOServidor() async {
        sessao.userId = nil
        await vm.carregarEstado()
        #expect(api.leituras == 0)
        #expect(await vm.enviar(loja.transacao(id: 40, token: nil)) == .semUsuario)
        #expect(api.jwsRecebidos.isEmpty)
    }

    // MARK: DTO

    @Test func decodificaOCorpoDoServidor() throws {
        let json = """
        {"status": "trial", "tem_acesso": true, "expira_em": "2026-11-27T15:04:05.123000",
         "produto": "br.com.softspend.app.assinatura.anual",
         "app_account_token": "6F9619FF-8B86-D011-B42D-00C04FC964FF"}
        """
        let r = try JSONDecoder().decode(AssinaturaResponse.self, from: Data(json.utf8))
        #expect(r.status == "trial")
        #expect(r.temAcesso)
        #expect(r.produto == ProdutoAssinatura.anual)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let esperado = utc.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 15, minute: 4, second: 5))
        #expect(r.expiraEm == esperado)

        let vazio = """
        {"status": "none", "tem_acesso": true, "expira_em": null, "produto": null,
         "app_account_token": "abc"}
        """
        let n = try JSONDecoder().decode(AssinaturaResponse.self, from: Data(vazio.utf8))
        #expect(n.expiraEm == nil)
        #expect(n.produto == nil)
    }

    @Test func lerDataAceitaComESemFuso() {
        let base = AssinaturaResponse.lerData("2026-11-27T15:04:05")
        #expect(base != nil)
        #expect(AssinaturaResponse.lerData("2026-11-27T15:04:05Z") == base)
        #expect(AssinaturaResponse.lerData("2026-11-27T15:04:05.5+00:00") == base)
        #expect(AssinaturaResponse.lerData("2026-11-27T12:04:05-03:00") == base)
        #expect(AssinaturaResponse.lerData("lixo") == nil)
    }
}
