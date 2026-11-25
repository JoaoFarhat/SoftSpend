import Testing
import Foundation
@testable import SoftSpend

/// `URLProtocol` falso: responde na hora com o que o teste enfileirou ou
/// rotou, sem rede, e grava cada pedido — dá para conferir o `Bearer` do
/// reenvio pós-refresh e o `timeoutInterval` do `deleteAccount`.
///
/// O estado fica em `static let` porque é a URL loading system que instancia
/// o protocolo; por isso a suíte roda `.serialized`.
nonisolated final class URLProtocolDeTeste: URLProtocol {

    nonisolated struct Resposta: Sendable {
        let status: Int
        let corpo: Data

        init(_ status: Int, _ corpo: String = "{}") {
            self.status = status
            self.corpo = Data(corpo.utf8)
        }
    }

    /// Caixa com o estado mutável, sempre atrás do `lock` — o `startLoading`
    /// roda na thread da URL loading system, não na do teste.
    nonisolated private final class Estado: @unchecked Sendable {
        let lock = NSLock()
        var pedidos: [URLRequest] = []
        var enfileiradas: [Resposta] = []
        var rota: (@Sendable (URLRequest) -> Resposta)?
    }

    nonisolated private static let estado = Estado()

    nonisolated static var pedidos: [URLRequest] {
        estado.lock.withLock { estado.pedidos }
    }

    nonisolated static func pedidos(para sufixoDeCaminho: String) -> [URLRequest] {
        pedidos.filter { $0.url?.path.hasSuffix(sufixoDeCaminho) == true }
    }

    /// Zera os pedidos gravados e devolve as respostas na ordem, uma por
    /// pedido. Pedido além da fila falha com `badServerResponse`.
    nonisolated static func enfileirar(_ respostas: Resposta...) {
        estado.lock.withLock {
            estado.pedidos = []
            estado.enfileiradas = respostas
            estado.rota = nil
        }
    }

    /// Zera os pedidos gravados e passa a decidir a resposta de cada pedido
    /// pela `rota` (para fluxos em que a ordem das chamadas não é fixa, como
    /// o 401 → refresh → reenvio).
    nonisolated static func rotear(_ rota: @escaping @Sendable (URLRequest) -> Resposta) {
        estado.lock.withLock {
            estado.pedidos = []
            estado.enfileiradas = []
            estado.rota = rota
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let resposta: Resposta
        do {
            resposta = try Self.responder(request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let http = HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost")!,
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

    nonisolated private static func responder(_ pedido: URLRequest) throws -> Resposta {
        let encontrada = estado.lock.withLock { () -> (rota: (@Sendable (URLRequest) -> Resposta)?, enfileirada: Resposta?) in
            estado.pedidos.append(pedido)
            var enfileirada: Resposta?
            if estado.rota == nil, !estado.enfileiradas.isEmpty {
                enfileirada = estado.enfileiradas.removeFirst()
            }
            return (estado.rota, enfileirada)
        }
        if let rota = encontrada.rota { return rota(pedido) }
        if let enfileirada = encontrada.enfileirada { return enfileirada }
        throw URLError(.badServerResponse)
    }
}

/// `CofreDeTokens` em memória: os tokens gravados pelo refresh ficam
/// legíveis depois, sem encostar no Keychain de verdade.
nonisolated private final class CofreEmMemoria: CofreDeTokens, @unchecked Sendable {
    private let lock = NSLock()
    private var _accessToken: String?
    private var _refreshToken: String?

    init(accessToken: String? = nil, refreshToken: String? = nil) {
        _accessToken = accessToken
        _refreshToken = refreshToken
    }

    var accessToken: String? { lock.withLock { _accessToken } }
    var refreshToken: String? { lock.withLock { _refreshToken } }

    func lerAccessToken() -> String? { accessToken }
    func lerRefreshToken() -> String? { refreshToken }
    func gravarAccessToken(_ token: String) { lock.withLock { _accessToken = token } }
    func gravarRefreshToken(_ token: String) { lock.withLock { _refreshToken = token } }
    func apagarTokens() {
        lock.withLock {
            _accessToken = nil
            _refreshToken = nil
        }
    }
}

/// Conta quantas vezes o `aoDeslogar` foi chamado.
nonisolated private final class RegistroDeslogar: @unchecked Sendable {
    private let lock = NSLock()
    private var _chamadas = 0

    var chamadas: Int { lock.withLock { _chamadas } }
    func registrar() { lock.withLock { _chamadas += 1 } }
}

/// Desempacota um `APIError.serverError` para as asserções.
nonisolated private func servidorErro(_ erro: Error) -> (mensagem: String, requestId: String, status: Int)? {
    guard case APIError.serverError(let m, let r, let s) = erro else { return nil }
    return (m, r, s)
}

/// Corpo do pedido como texto. O `URLRequest` que o `URLProtocol` recebe pode
/// trazer o corpo como `httpBodyStream` em vez de `httpBody` — lê os dois.
nonisolated private func corpoDoPedido(_ pedido: URLRequest) -> String {
    if let corpo = pedido.httpBody, let texto = String(data: corpo, encoding: .utf8) {
        return texto
    }
    guard let stream = pedido.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var dados = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let lidos = stream.read(buffer, maxLength: 4096)
        guard lidos > 0 else { break }
        dados.append(buffer, count: lidos)
    }
    return String(data: dados, encoding: .utf8) ?? ""
}

/// Resposta do `POST /auth/refresh` com o par de tokens novos.
nonisolated private let jsonAuthRefresh = #"{"id":"u1","nome":"Teste","username":"u1","email":"u1@x.com","access_token":"token-novo","refresh_token":"refresh-novo","expires_in":3600,"token_type":"bearer"}"#

/// `.serialized` porque o `URLProtocolDeTeste` guarda estado estático —
/// duas execuções em paralelo misturariam as respostas enfileiradas.
@Suite(.serialized)
struct NetworkManagerExecuteTests {

    // MARK: - Fábricas

    nonisolated private func sessaoDeTeste() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolDeTeste.self]
        return URLSession(configuration: config)
    }

    nonisolated private func managerDeTeste(
        cofre: CofreEmMemoria = CofreEmMemoria(accessToken: "token-velho", refreshToken: "refresh-velho"),
        aoDeslogar: @escaping @Sendable () -> Void = {}
    ) -> NetworkManager {
        let sessao = sessaoDeTeste()
        return NetworkManager(
            session: sessao,
            uploadSession: sessao,
            tokens: cofre,
            aoDeslogar: aoDeslogar
        )
    }

    // MARK: - (a) request_id no serverError

    @Test func quatroZeroQuatroComRequestIdDoServidor() async {
        URLProtocolDeTeste.enfileirar(.init(404, #"{"error":"não encontrado","request_id":"abc"}"#))

        await #expect {
            _ = try await managerDeTeste().fetchFeatures()
        } throws: { erro in
            guard let e = servidorErro(erro) else { return false }
            return e.status == 404 && e.requestId == "abc" && e.mensagem == "não encontrado"
        }
    }

    /// O 404 de rota inexistente do FastAPI vem só com `{"detail": "Not
    /// Found"}` — sem `request_id`. É ele que protege o descarte por 404 do
    /// `SyncActor`: `requestId "-"` prova que o corpo não veio da API.
    @Test func quatroZeroQuatroSemRequestIdViraTraco() async {
        URLProtocolDeTeste.enfileirar(.init(404, #"{"detail":"Not Found"}"#))

        await #expect {
            _ = try await managerDeTeste().fetchFeatures()
        } throws: { erro in
            guard let e = servidorErro(erro) else { return false }
            return e.status == 404 && e.requestId == "-" && e.mensagem == "Erro no servidor"
        }
    }

    @Test func erroHtmlViraErroNoServidorComTraco() async {
        URLProtocolDeTeste.enfileirar(.init(502, "<html><body>Bad Gateway</body></html>"))

        await #expect {
            _ = try await managerDeTeste().fetchFeatures()
        } throws: { erro in
            guard let e = servidorErro(erro) else { return false }
            return e.status == 502 && e.requestId == "-" && e.mensagem == "Erro no servidor"
        }
    }

    // MARK: - (b) 422 com campos

    @Test func quatrocentosEVinteEDoisComCamposUsaFraseDoCampoRecusado() async {
        URLProtocolDeTeste.enfileirar(
            .init(422, #"{"error":"Dados de entrada invalidos","request_id":"r1","campos":["valor"]}"#)
        )

        await #expect {
            _ = try await managerDeTeste().fetchFeatures()
        } throws: { erro in
            guard let e = servidorErro(erro) else { return false }
            return e.status == 422
                && e.mensagem == "O servidor não aceitou o valor. Edite ou apague este item."
        }
    }

    // MARK: - (c) 401 → refresh → reenvio

    @Test func refreshRenovaEReenviaComOTokenNovo() async throws {
        URLProtocolDeTeste.rotear { pedido in
            let caminho = pedido.url?.path ?? ""
            if caminho.hasSuffix("/auth/refresh") {
                return .init(200, jsonAuthRefresh)
            }
            if pedido.value(forHTTPHeaderField: "Authorization") == "Bearer token-velho" {
                return .init(401, #"{"error":"expirado","request_id":"r-exp"}"#)
            }
            return .init(200, #"{"open_finance":true}"#)
        }
        let cofre = CofreEmMemoria(accessToken: "token-velho", refreshToken: "refresh-velho")
        let deslogar = RegistroDeslogar()
        let manager = managerDeTeste(cofre: cofre, aoDeslogar: { deslogar.registrar() })

        let features = try await manager.fetchFeatures()

        #expect(features.openFinance)

        let pedidosFeatures = URLProtocolDeTeste.pedidos(para: "/api/features")
        try #require(pedidosFeatures.count == 2)
        #expect(pedidosFeatures[0].value(forHTTPHeaderField: "Authorization") == "Bearer token-velho")
        #expect(pedidosFeatures[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-novo")

        let pedidosRefresh = URLProtocolDeTeste.pedidos(para: "/auth/refresh")
        try #require(pedidosRefresh.count == 1)
        #expect(corpoDoPedido(pedidosRefresh[0]).contains("refresh-velho"))

        // O cofre ficou com o par novo e ninguém deslogou.
        #expect(cofre.accessToken == "token-novo")
        #expect(cofre.refreshToken == "refresh-novo")
        #expect(deslogar.chamadas == 0)
    }

    // MARK: - (d) refresh recusado desloga

    @Test func refreshCom401DeslogaUmaVez() async {
        URLProtocolDeTeste.rotear { _ in
            .init(401, #"{"error":"token inválido","request_id":"r2"}"#)
        }
        let deslogar = RegistroDeslogar()
        let manager = managerDeTeste(aoDeslogar: { deslogar.registrar() })

        await #expect {
            _ = try await manager.fetchFeatures()
        } throws: { erro in
            guard case APIError.authentication = erro else { return false }
            return true
        }
        #expect(deslogar.chamadas == 1)
        #expect(URLProtocolDeTeste.pedidos(para: "/auth/refresh").count == 1)
    }

    // MARK: - (e) reenvio que volta 401 desloga; 500 não

    @Test func reenvioQueVolta401Desloga() async {
        URLProtocolDeTeste.rotear { pedido in
            let caminho = pedido.url?.path ?? ""
            if caminho.hasSuffix("/auth/refresh") {
                return .init(200, jsonAuthRefresh)
            }
            return .init(401, #"{"error":"ainda expirado","request_id":"r3"}"#)
        }
        let deslogar = RegistroDeslogar()
        let manager = managerDeTeste(aoDeslogar: { deslogar.registrar() })

        await #expect {
            _ = try await manager.fetchFeatures()
        } throws: { erro in
            guard case APIError.authentication = erro else { return false }
            return true
        }
        #expect(deslogar.chamadas == 1)
        #expect(URLProtocolDeTeste.pedidos(para: "/api/features").count == 2)
    }

    @Test func reenvioQueVolta500NaoDesloga() async {
        URLProtocolDeTeste.rotear { pedido in
            let caminho = pedido.url?.path ?? ""
            if caminho.hasSuffix("/auth/refresh") {
                return .init(200, jsonAuthRefresh)
            }
            if pedido.value(forHTTPHeaderField: "Authorization") == "Bearer token-velho" {
                return .init(401, #"{"error":"expirado","request_id":"r4"}"#)
            }
            return .init(500, #"{"error":"falha interna","request_id":"r5"}"#)
        }
        let deslogar = RegistroDeslogar()
        let manager = managerDeTeste(aoDeslogar: { deslogar.registrar() })

        await #expect {
            _ = try await manager.fetchFeatures()
        } throws: { erro in
            guard let e = servidorErro(erro) else { return false }
            return e.status == 500
        }
        #expect(deslogar.chamadas == 0)
    }

    // MARK: - (f) 403 de assinatura não renova token

    @Test func assinaturaNecessariaNaoChamaRefresh() async {
        URLProtocolDeTeste.enfileirar(
            .init(403, #"{"error":"subscription_required","request_id":"r9"}"#)
        )
        let deslogar = RegistroDeslogar()
        let manager = managerDeTeste(aoDeslogar: { deslogar.registrar() })

        await #expect {
            _ = try await manager.fetchFeatures()
        } throws: { erro in
            guard case APIError.serverError = erro else { return false }
            return (erro as? APIError)?.assinaturaNecessaria == true
        }
        #expect(URLProtocolDeTeste.pedidos(para: "/auth/refresh").isEmpty)
        #expect(deslogar.chamadas == 0)
    }

    // MARK: - (g) formatos de data

    /// Os três formatos que o servidor manda: com fração, sem fração e UTC
    /// sem o fuso (`yyyy-MM-dd'T'HH:mm:ss`, lido como UTC).
    @Test(arguments: [
        ("2026-11-25T10:30:00.123Z", 123),
        ("2026-11-25T10:30:00Z", 0),
        ("2026-11-25T10:30:00", 0)
    ])
    func datasDecodificam(texto: String, milissegundos: Int) async throws {
        URLProtocolDeTeste.enfileirar(
            .init(200, #"[{"id":1,"client_id":"c1","data":"\#(texto)","saldo":10}]"#)
        )

        let dias = try await managerDeTeste().fetchDias(cicloId: 1)

        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let esperada = try #require(calendario.date(
            from: DateComponents(year: 2026, month: 11, day: 25, hour: 10, minute: 30, second: 0)
        )) + Double(milissegundos) / 1000

        try #require(dias.count == 1)
        #expect(abs(dias[0].data.timeIntervalSince(esperada)) < 0.001)
    }

    @Test func dataInvalidaLanca() async {
        URLProtocolDeTeste.enfileirar(
            .init(200, #"[{"id":1,"data":"25/11/2026","saldo":10}]"#)
        )

        await #expect(throws: DecodingError.self) {
            _ = try await managerDeTeste().fetchDias(cicloId: 1)
        }
    }

    // MARK: - (h) deleteAccount vai pela sessão de 90 s

    /// Apagar a conta pode demorar no servidor: o pedido precisa sair com o
    /// timeout de upload (90 s), não com os 8 s das chamadas comuns — senão o
    /// app mostra erro com o servidor ainda apagando e a limpeza local da
    /// conta (exigência da Apple) não roda.
    @Test func deleteAccountSaiComTimeoutDe90() async throws {
        URLProtocolDeTeste.enfileirar(.init(200))

        try await managerDeTeste().deleteAccount()

        let pedidos = URLProtocolDeTeste.pedidos(para: "/auth/conta")
        try #require(pedidos.count == 1)
        #expect(pedidos[0].httpMethod == "DELETE")
        #expect(pedidos[0].timeoutInterval == 90)
    }
}
