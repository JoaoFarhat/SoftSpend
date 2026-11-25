import Testing
import Foundation
@testable import SoftSpend

// Um pedido de uma conta nunca é reenviado com o login de outra nem derruba
// o login dela (AGENTS.md, "Troca de conta no meio do envio").
//
// O `URLProtocol` e o cofre são próprios deste arquivo: o estado estático do
// `URLProtocolDeTeste` é de outra suíte, e suítes diferentes rodam em
// paralelo. A "troca de conta no meio" acontece dentro da `rota`, que roda
// quando o pedido chega e antes da resposta sair — é o mesmo que segurar a
// resposta, trocar o cofre e soltar, sem depender de espera.

/// `URLProtocol` falso desta suíte: cada pedido é gravado e respondido pela
/// `rota` (que pode mexer no cofre antes de responder).
nonisolated final class URLProtocolSessaoTrocada: URLProtocol {

    nonisolated struct Resposta: Sendable {
        let status: Int
        let corpo: Data

        init(_ status: Int, _ corpo: String = "{}") {
            self.status = status
            self.corpo = Data(corpo.utf8)
        }
    }

    nonisolated private final class Estado: @unchecked Sendable {
        let lock = NSLock()
        var pedidos: [URLRequest] = []
        var rota: (@Sendable (URLRequest) -> Resposta)?
    }

    nonisolated private static let estado = Estado()

    nonisolated static func pedidos(para sufixoDeCaminho: String) -> [URLRequest] {
        estado.lock.withLock { estado.pedidos }
            .filter { $0.url?.path.hasSuffix(sufixoDeCaminho) == true }
    }

    /// Zera os pedidos gravados e passa a responder pela `rota`.
    nonisolated static func rotear(_ rota: @escaping @Sendable (URLRequest) -> Resposta) {
        estado.lock.withLock {
            estado.pedidos = []
            estado.rota = rota
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rota = Self.estado.lock.withLock { () -> (@Sendable (URLRequest) -> Resposta)? in
            Self.estado.pedidos.append(request)
            return Self.estado.rota
        }
        guard let rota,
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let resposta = rota(request)
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: resposta.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resposta.corpo)
        client?.urlProtocol(self, didFinishLoading: self)
    }

    override func stopLoading() {}
}

/// Cofre em memória que grava a ordem das gravações e deixa o teste trocar a
/// conta (`trocar`, que não entra no registro de gravações).
nonisolated private final class CofreQueTroca: CofreDeTokens, @unchecked Sendable {
    private let lock = NSLock()
    private var _accessToken: String?
    private var _refreshToken: String?
    private var _gravacoes: [String] = []

    init(accessToken: String?, refreshToken: String?) {
        _accessToken = accessToken
        _refreshToken = refreshToken
    }

    var accessToken: String? { lock.withLock { _accessToken } }
    var refreshToken: String? { lock.withLock { _refreshToken } }
    /// "refresh:<token>" e "access:<token>", na ordem em que foram gravados.
    var gravacoes: [String] { lock.withLock { _gravacoes } }

    /// A outra conta entrou (ou outra renovação gravou): troca o par inteiro.
    func trocar(accessToken: String?, refreshToken: String?) {
        lock.withLock {
            _accessToken = accessToken
            _refreshToken = refreshToken
        }
    }

    func lerAccessToken() -> String? { accessToken }
    func lerRefreshToken() -> String? { refreshToken }
    func gravarAccessToken(_ token: String) {
        lock.withLock {
            _accessToken = token
            _gravacoes.append("access:\(token)")
        }
    }
    func gravarRefreshToken(_ token: String) {
        lock.withLock {
            _refreshToken = token
            _gravacoes.append("refresh:\(token)")
        }
    }
    func apagarTokens() {
        lock.withLock {
            _accessToken = nil
            _refreshToken = nil
        }
    }
}

nonisolated private final class ContadorDeslogar: @unchecked Sendable {
    private let lock = NSLock()
    private var _chamadas = 0

    var chamadas: Int { lock.withLock { _chamadas } }
    func registrar() { lock.withLock { _chamadas += 1 } }
}

/// JWT falso (cabeçalho.payload.assinatura) com o `sub` pedido. `n` deixa
/// dois tokens da mesma conta diferentes entre si. A assinatura é lixo: o
/// app não a confere.
nonisolated private func jwtFalso(sub: String, n: Int) -> String {
    func base64url(_ texto: String) -> String {
        Data(texto.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let cabecalho = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
    let payload = base64url(#"{"sub":"\#(sub)","n":\#(n),"exp":4102444800}"#)
    return "\(cabecalho).\(payload).assinatura-falsa"
}

nonisolated private let accessA1 = jwtFalso(sub: "A", n: 1)
nonisolated private let accessA2 = jwtFalso(sub: "A", n: 2)
nonisolated private let accessB1 = jwtFalso(sub: "B", n: 1)

nonisolated private func bearer(_ token: String) -> String { "Bearer \(token)" }

/// Corpo do `POST /auth/refresh` com o par novo de A.
nonisolated private let jsonRefreshA2 = #"{"id":"A","nome":"A","username":"a","email":"a@x.com","access_token":"\#(accessA2)","refresh_token":"refresh-A2","expires_in":3600,"token_type":"bearer"}"#

nonisolated private let jsonFeatures = #"{"open_finance":true}"#

nonisolated private func ehSessaoTrocada(_ erro: Error) -> Bool {
    guard case APIError.sessaoTrocada = erro else { return false }
    return true
}

@Suite(.serialized)
struct SessaoTrocadaRedeTests {

    nonisolated private func manager(
        cofre: CofreQueTroca,
        deslogar: ContadorDeslogar
    ) -> NetworkManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolSessaoTrocada.self]
        let sessao = URLSession(configuration: config)
        return NetworkManager(
            session: sessao,
            uploadSession: sessao,
            tokens: cofre,
            aoDeslogar: { deslogar.registrar() }
        )
    }

    // MARK: - (i) pedido de A volta 401 com B já no cofre

    @Test func quatrocentosEUmComOutraContaNoCofreNaoRenovaNemReenvia() async {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { pedido in
            if pedido.url?.path.hasSuffix("/auth/refresh") == true {
                return .init(200, jsonRefreshA2)
            }
            // A saiu (o logout revogou a sessão) e B entrou com o pedido
            // de A ainda em voo.
            cofre.trocar(accessToken: accessB1, refreshToken: "refresh-B1")
            return .init(401, #"{"error":"sessão revogada","request_id":"r1"}"#)
        }

        await #expect {
            _ = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()
        } throws: { ehSessaoTrocada($0) }

        #expect(URLProtocolSessaoTrocada.pedidos(para: "/auth/refresh").isEmpty)
        #expect(URLProtocolSessaoTrocada.pedidos(para: "/api/features").count == 1)
        #expect(deslogar.chamadas == 0)
        #expect(cofre.accessToken == accessB1)
        #expect(cofre.refreshToken == "refresh-B1")
        #expect(cofre.gravacoes.isEmpty)
    }

    // MARK: - (ii) outra renovação de A já trocou o token

    @Test func tokenTrocadoPorOutroDaMesmaContaReenviaSemRenovar() async throws {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { pedido in
            if pedido.url?.path.hasSuffix("/auth/refresh") == true {
                return .init(200, jsonRefreshA2)
            }
            if pedido.value(forHTTPHeaderField: "Authorization") == bearer(accessA1) {
                // Outro pedido de A renovou enquanto este estava fora.
                cofre.trocar(accessToken: accessA2, refreshToken: "refresh-A2")
                return .init(401, #"{"error":"expirado","request_id":"r2"}"#)
            }
            return .init(200, jsonFeatures)
        }

        let features = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()

        #expect(features.openFinance)
        #expect(URLProtocolSessaoTrocada.pedidos(para: "/auth/refresh").isEmpty)
        let pedidos = URLProtocolSessaoTrocada.pedidos(para: "/api/features")
        try #require(pedidos.count == 2)
        #expect(pedidos[0].value(forHTTPHeaderField: "Authorization") == bearer(accessA1))
        #expect(pedidos[1].value(forHTTPHeaderField: "Authorization") == bearer(accessA2))
        #expect(deslogar.chamadas == 0)
    }

    /// O reenvio com o token atual volta 401 e, nesse meio, B entrou: o 401
    /// é da sessão de A e não desloga B.
    @Test func quatrocentosEUmDoReenvioComOutraContaNoCofreNaoDesloga() async {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { pedido in
            if pedido.url?.path.hasSuffix("/auth/refresh") == true {
                return .init(200, jsonRefreshA2)
            }
            if pedido.value(forHTTPHeaderField: "Authorization") == bearer(accessA1) {
                cofre.trocar(accessToken: accessA2, refreshToken: "refresh-A2")
            } else {
                cofre.trocar(accessToken: accessB1, refreshToken: "refresh-B1")
            }
            return .init(401, #"{"error":"expirado","request_id":"r3"}"#)
        }

        await #expect {
            _ = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()
        } throws: { ehSessaoTrocada($0) }

        #expect(URLProtocolSessaoTrocada.pedidos(para: "/api/features").count == 2)
        #expect(deslogar.chamadas == 0)
        #expect(cofre.accessToken == accessB1)
    }

    // MARK: - (iii) renovação de A volta depois de B entrar

    @Test func renovacaoDeAQueVoltaDepoisDeBEntrarNaoGrava() async {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { pedido in
            if pedido.url?.path.hasSuffix("/auth/refresh") == true {
                // A renovação de A estava fora; A saiu e B entrou antes
                // da resposta chegar.
                cofre.trocar(accessToken: accessB1, refreshToken: "refresh-B1")
                return .init(200, jsonRefreshA2)
            }
            return .init(401, #"{"error":"expirado","request_id":"r4"}"#)
        }

        await #expect {
            _ = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()
        } throws: { ehSessaoTrocada($0) }

        #expect(cofre.accessToken == accessB1)
        #expect(cofre.refreshToken == "refresh-B1")
        #expect(cofre.gravacoes.isEmpty)
        // O pedido de A não sai de novo (nem com o token de A, nem com o de B).
        #expect(URLProtocolSessaoTrocada.pedidos(para: "/api/features").count == 1)
        #expect(deslogar.chamadas == 0)
    }

    // MARK: - (iv) renovação de A falha depois de B entrar

    @Test func renovacaoDeAQueFalhaDepoisDeBEntrarNaoDeslogaB() async {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { pedido in
            if pedido.url?.path.hasSuffix("/auth/refresh") == true {
                cofre.trocar(accessToken: accessB1, refreshToken: "refresh-B1")
                return .init(401, #"{"error":"refresh revogado","request_id":"r5"}"#)
            }
            return .init(401, #"{"error":"expirado","request_id":"r6"}"#)
        }

        await #expect {
            _ = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()
        } throws: { ehSessaoTrocada($0) }

        #expect(deslogar.chamadas == 0)
        #expect(cofre.accessToken == accessB1)
        #expect(cofre.refreshToken == "refresh-B1")
    }

    /// Sem troca de conta, a renovação recusada continua deslogando.
    @Test func renovacaoRecusadaSemTrocaDesloga() async {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { _ in
            .init(401, #"{"error":"refresh revogado","request_id":"r7"}"#)
        }

        await #expect {
            _ = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()
        } throws: { erro in
            guard case APIError.authentication = erro else { return false }
            return true
        }

        #expect(deslogar.chamadas == 1)
    }

    // MARK: - (v) refresh gravado antes do access

    @Test func renovacaoGravaRefreshAntesDoAccess() async throws {
        let cofre = CofreQueTroca(accessToken: accessA1, refreshToken: "refresh-A1")
        let deslogar = ContadorDeslogar()
        URLProtocolSessaoTrocada.rotear { pedido in
            if pedido.url?.path.hasSuffix("/auth/refresh") == true {
                return .init(200, jsonRefreshA2)
            }
            if pedido.value(forHTTPHeaderField: "Authorization") == bearer(accessA1) {
                return .init(401, #"{"error":"expirado","request_id":"r8"}"#)
            }
            return .init(200, jsonFeatures)
        }

        _ = try await manager(cofre: cofre, deslogar: deslogar).fetchFeatures()

        #expect(cofre.gravacoes == ["refresh:refresh-A2", "access:\(accessA2)"])
        let pedidos = URLProtocolSessaoTrocada.pedidos(para: "/api/features")
        try #require(pedidos.count == 2)
        #expect(pedidos[1].value(forHTTPHeaderField: "Authorization") == bearer(accessA2))
        #expect(deslogar.chamadas == 0)
    }

    // MARK: - Regras puras

    @Test func subDoJWTLeSoOPayload() {
        #expect(subDoJWT(accessA1) == "A")
        #expect(subDoJWT(accessB1) == "B")
        #expect(subDoJWT("token-velho") == nil)
        #expect(subDoJWT("a.b") == nil)
        #expect(subDoJWT("a.!!!.c") == nil)
        #expect(subDoJWT(jwtFalso(sub: "", n: 1)) == nil)
    }

    @Test func decisaoApos401() {
        #expect(decidirApos401(tokenEnviado: accessA1, tokenAtual: accessA1) == .renovar)
        #expect(decidirApos401(tokenEnviado: nil, tokenAtual: nil) == .renovar)
        #expect(decidirApos401(tokenEnviado: accessA1, tokenAtual: accessA2) == .reenviarCom(accessA2))
        #expect(decidirApos401(tokenEnviado: accessA1, tokenAtual: accessB1) == .sessaoTrocada)
        #expect(decidirApos401(tokenEnviado: accessA1, tokenAtual: nil) == .sessaoTrocada)
        #expect(decidirApos401(tokenEnviado: nil, tokenAtual: accessA1) == .sessaoTrocada)
        #expect(decidirApos401(tokenEnviado: "token-velho", tokenAtual: "token-novo") == .sessaoTrocada)
    }

    @Test func sessaoTrocadaNaoDesloga() {
        #expect(!deveDeslogarAposFalhaDeRefresh(APIError.sessaoTrocada))
        #expect(!ehFalhaTransitoriaDeRefresh(APIError.sessaoTrocada))
        #expect(APIError.sessaoTrocada.errorDescription == "Sua conta mudou durante o envio. Tente de novo.")
    }

    @Test func tokenDoCabecalhoTiraOBearer() {
        #expect(tokenDoCabecalho("Bearer abc") == "abc")
        #expect(tokenDoCabecalho(nil) == nil)
        #expect(tokenDoCabecalho("Basic abc") == nil)
    }
}
