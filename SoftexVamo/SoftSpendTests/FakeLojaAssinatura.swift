import Foundation
@testable import SoftSpend

/// Linha do tempo compartilhada entre a loja e a API falsas: prova, por
/// exemplo, que o `finish()` só acontece depois de o servidor aceitar.
nonisolated final class LinhaDoTempo: @unchecked Sendable {
    private let lock = NSLock()
    private var _passos: [String] = []

    var passos: [String] { lock.lock(); defer { lock.unlock() }; return _passos }

    func marcar(_ passo: String) {
        lock.lock()
        _passos.append(passo)
        lock.unlock()
    }
}

/// Loja falsa (sem StoreKit) para os testes do `AssinaturaViewModel`.
final class FakeLojaAssinatura: LojaAssinaturaProtocolo {
    let linha: LinhaDoTempo

    var planos: [PlanoLoja] = [
        PlanoLoja(id: ProdutoAssinatura.mensal, periodo: .mensal, preco: "R$ 14,90",
                  testeGratis: OfertaGratis(valor: 2, unidade: .semana)),
        PlanoLoja(id: ProdutoAssinatura.anual, periodo: .anual, preco: "R$ 144,90",
                  testeGratis: nil)
    ]
    var erroAoCarregar: Error?
    var resultadoCompra: ResultadoCompraLoja = .cancelada
    var erroAoComprar: Error?
    var erroAoSincronizar: Error?
    var direitos: [TransacaoLoja] = []
    var pendentes: [TransacaoLoja] = []

    private(set) var compras: [(planoId: String, token: UUID)] = []
    private(set) var sincronizacoes = 0
    private var continuacao: AsyncStream<TransacaoLoja>.Continuation?

    init(linha: LinhaDoTempo = LinhaDoTempo()) {
        self.linha = linha
    }

    /// Transação verificada; `finalizar` marca "finish:<id>" na linha do tempo.
    func transacao(id: UInt64, token: UUID?, produto: String = ProdutoAssinatura.mensal) -> TransacaoLoja {
        let linha = self.linha
        return TransacaoLoja(
            id: id, produtoId: produto, jws: "jws-\(id)", appAccountToken: token,
            finalizar: { linha.marcar("finish:\(id)") }
        )
    }

    /// Simula uma transação chegando por `Transaction.updates`.
    func emitir(_ transacao: TransacaoLoja) {
        continuacao?.yield(transacao)
    }

    func carregarPlanos() async throws -> [PlanoLoja] {
        if let erroAoCarregar { throw erroAoCarregar }
        return planos
    }

    func comprar(planoId: String, appAccountToken: UUID) async throws -> ResultadoCompraLoja {
        compras.append((planoId, appAccountToken))
        linha.marcar("comprar")
        if let erroAoComprar { throw erroAoComprar }
        return resultadoCompra
    }

    func sincronizarComAppStore() async throws {
        sincronizacoes += 1
        if let erroAoSincronizar { throw erroAoSincronizar }
    }

    func direitosAtuais() async -> [TransacaoLoja] { direitos }

    func naoFinalizadas() async -> [TransacaoLoja] { pendentes }

    func atualizacoes() -> AsyncStream<TransacaoLoja> {
        let (fluxo, continuacao) = AsyncStream.makeStream(of: TransacaoLoja.self)
        self.continuacao = continuacao
        return fluxo
    }
}

/// `GET /api/assinatura` e `POST /api/assinatura/transacoes` falsos.
nonisolated final class FakeAssinaturaAPI: AssinaturaAPI, @unchecked Sendable {
    private let lock = NSLock()
    let linha: LinhaDoTempo
    private var _estado: AssinaturaResponse
    private var _depoisDeAceitar: AssinaturaResponse?
    private var _erroAoObter: Error?
    private var _erroAoEnviar: Error?
    private var _jwsRecebidos: [String] = []
    private var _leituras = 0

    static let token = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    init(linha: LinhaDoTempo = LinhaDoTempo(), status: String = "none") {
        self.linha = linha
        _estado = AssinaturaResponse(
            status: status, temAcesso: true, expiraEm: nil, produto: nil,
            appAccountToken: Self.token.uuidString
        )
    }

    var jwsRecebidos: [String] { lock.lock(); defer { lock.unlock() }; return _jwsRecebidos }
    var leituras: Int { lock.lock(); defer { lock.unlock() }; return _leituras }

    var estado: AssinaturaResponse {
        get { lock.lock(); defer { lock.unlock() }; return _estado }
        set { lock.lock(); _estado = newValue; lock.unlock() }
    }
    /// O que o servidor passa a responder depois de aceitar uma transação.
    var depoisDeAceitar: AssinaturaResponse? {
        get { lock.lock(); defer { lock.unlock() }; return _depoisDeAceitar }
        set { lock.lock(); _depoisDeAceitar = newValue; lock.unlock() }
    }
    var erroAoObter: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _erroAoObter }
        set { lock.lock(); _erroAoObter = newValue; lock.unlock() }
    }
    var erroAoEnviar: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _erroAoEnviar }
        set { lock.lock(); _erroAoEnviar = newValue; lock.unlock() }
    }

    func obterAssinatura() async throws -> AssinaturaResponse {
        lock.lock()
        _leituras += 1
        let erro = _erroAoObter
        let estado = _estado
        lock.unlock()
        if let erro { throw erro }
        return estado
    }

    func enviarTransacaoAssinatura(jws: String) async throws -> AssinaturaResponse {
        lock.lock()
        _jwsRecebidos.append(jws)
        let erro = _erroAoEnviar
        lock.unlock()
        linha.marcar("enviar:\(jws)")
        if let erro { throw erro }
        lock.lock()
        if let novo = _depoisDeAceitar { _estado = novo }
        let estado = _estado
        lock.unlock()
        return estado
    }
}
