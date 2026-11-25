import Testing
import Foundation
import Security
@testable import SoftSpend

// MARK: - Apoio

/// Estado do `ProtocoloComRota`: os pedidos que chegaram e a rota que decide
/// a resposta de cada um.
nonisolated final class EstadoComRota: @unchecked Sendable {
    private let lock = NSLock()
    private var _pedidos: [URLRequest] = []
    private var _rota: @Sendable (URLRequest) -> (status: Int, corpo: String) = { _ in (200, "{}") }

    var pedidos: [URLRequest] { lock.withLock { _pedidos } }

    func pedidos(para sufixoDeCaminho: String) -> [URLRequest] {
        pedidos.filter { $0.url?.path.hasSuffix(sufixoDeCaminho) == true }
    }

    func zerar(rota: @escaping @Sendable (URLRequest) -> (status: Int, corpo: String)) {
        lock.withLock {
            _pedidos = []
            _rota = rota
        }
    }

    func responder(_ pedido: URLRequest) -> (status: Int, corpo: String) {
        lock.withLock {
            _pedidos.append(pedido)
            return _rota(pedido)
        }
    }
}

/// `URLProtocol` com rota por pedido — próprio desta suíte: o estado é
/// `static`, então outras suítes que rodam em paralelo não o dividem.
nonisolated final class ProtocoloComRota: URLProtocol {
    nonisolated static let estado = EstadoComRota()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, corpo) = Self.estado.responder(request)
        let url = request.url ?? URL(string: "https://teste.invalid")!
        let resposta = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resposta, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(corpo.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Resposta do `POST /auth/refresh` com o par de tokens novos.
nonisolated private let jsonAuthRenovado = #"{"id":"u1","nome":"Teste","username":"u1","email":"u1@x.com","access_token":"token-novo","refresh_token":"refresh-novo","expires_in":3600,"token_type":"bearer"}"#

/// `AuthResponse` para as costuras de entrada do `AuthService`.
nonisolated private let respostaAuth = AuthResponse(
    id: "u1", nome: "Teste", username: "u1", email: "u1@x.com",
    accessToken: "access-teste", refreshToken: "refresh-teste",
    expiresIn: 3600, tokenType: "bearer"
)

/// A falha do Keychain no login (docs/keychain-login.md): gravação recusada
/// na renovação manda o par novo para a memória e na entrada fecha o acesso;
/// leitura que o desbloqueio não resolve vira `.ilegivel` e logout local.
///
/// `.serialized`: o `ProtocoloComRota` guarda o estado num `static`.
@Suite(.serialized)
struct FalhaDoKeychainLoginTests {

    // MARK: - Fábricas

    nonisolated private func sessaoDeTeste() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProtocoloComRota.self]
        return URLSession(configuration: config)
    }

    nonisolated private func redeDeTeste(
        cofre: CofreDeTokensFalso,
        registro: RegistroDeLogout
    ) -> NetworkManager {
        let sessao = sessaoDeTeste()
        return NetworkManager(
            session: sessao,
            uploadSession: sessao,
            tokens: cofre,
            aoDeslogar: { registro.deslogar() }
        )
    }

    /// Rota clássica 401 → refresh → 200: o `access-vencido` leva 401, o
    /// `/auth/refresh` devolve o par novo, qualquer outro token passa.
    nonisolated private func rotear401AteRenovar() {
        ProtocoloComRota.estado.zerar { pedido in
            let caminho = pedido.url?.path ?? ""
            if caminho.hasSuffix("/auth/refresh") {
                return (200, jsonAuthRenovado)
            }
            if pedido.value(forHTTPHeaderField: "Authorization") == "Bearer access-vencido" {
                return (401, #"{"error":"expirado","request_id":"r-exp"}"#)
            }
            return (200, #"{"open_finance":true}"#)
        }
    }

    // MARK: - §4.1: statusEsperaDesbloqueio

    @Test func statusQueEsperamDesbloqueio() {
        // §2.1: só os dois status de espera viram `.indisponivel` —
        // -25308 (trancado) e -25291 (antes do primeiro desbloqueio).
        #expect(statusEsperaDesbloqueio(-25308))
        #expect(statusEsperaDesbloqueio(-25291))
        // Todos os outros são `.ilegivel`: -34018 (missing entitlement),
        // -26275 (decode), -50 (param), -108 (allocate) e 0 (success).
        for status: OSStatus in [-34018, -26275, -50, -108, 0] {
            #expect(!statusEsperaDesbloqueio(status))
        }
    }

    // MARK: - §4.2: `.indisponivel` com o iPhone destrancado vira `.ilegivel`

    @Test func indisponivelComIPhoneDestrancadoViraIlegivel() {
        #expect(
            ajustarLeituraAoEstadoDoIPhone(
                .indisponivel(-25308),
                iPhoneProvavelmenteTrancado: false
            ) == .ilegivel(-25308)
        )
        // Com o iPhone provavelmente trancado, a espera segue.
        #expect(
            ajustarLeituraAoEstadoDoIPhone(
                .indisponivel(-25308),
                iPhoneProvavelmenteTrancado: true
            ) == .indisponivel(-25308)
        )
        // Os outros resultados passam como estão.
        #expect(ajustarLeituraAoEstadoDoIPhone(.achou("t"), iPhoneProvavelmenteTrancado: false) == .achou("t"))
        #expect(ajustarLeituraAoEstadoDoIPhone(.naoExiste, iPhoneProvavelmenteTrancado: false) == .naoExiste)
        #expect(ajustarLeituraAoEstadoDoIPhone(.ilegivel(-34018), iPhoneProvavelmenteTrancado: false) == .ilegivel(-34018))
    }

    // MARK: - §4.3: renovação com gravação do refresh recusada

    @Test func renovacaoComGravacaoRecusadaGuardaParEmMemoria() async throws {
        rotear401AteRenovar()
        let cofre = CofreDeTokensFalso(access: "access-vencido", refresh: "refresh-1")
        cofre.recusarGravacaoRefresh = errSecInteractionNotAllowed
        let registro = RegistroDeLogout()
        let rede = redeDeTeste(cofre: cofre, registro: registro)

        // O pedido dá certo com o token novo: a renovação vingou mesmo com
        // o Keychain recusando a gravação (§1.1, regra 2).
        _ = try await rede.fetchFeatures()

        // O cofre não recebeu o access — o refresh recusou, então o access
        // nem tenta (regra 1).
        #expect(cofre.tentativasAccess == 0)
        #expect(cofre.access == "access-vencido")
        #expect(cofre.refresh == "refresh-1")
        #expect(registro.vezes == 0)

        // O par novo ficou em memória...
        #expect(rede.parDeTokensPendente == ParDeTokensPendente(
            refreshToken: "refresh-novo",
            accessToken: "token-novo"
        ))

        // ...e o pedido seguinte o usa (a retentativa de gravação ainda é
        // recusada e o par segue pendente).
        _ = try await rede.fetchFeatures()
        let pedidosFeatures = ProtocoloComRota.estado.pedidos(para: "/api/features")
        try #require(pedidosFeatures.count == 2)
        #expect(pedidosFeatures[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-novo")

        // Nenhum pedido de renovação reenviou o refresh antigo: uma só
        // chamada a `/auth/refresh`.
        #expect(ProtocoloComRota.estado.pedidos(para: "/auth/refresh").count == 1)
    }

    // MARK: - §4.4: retentativa grava os dois na ordem e o pendente some

    @Test func retentativaGravaOsDoisNaOrdemEDescartaOPendente() async throws {
        rotear401AteRenovar()
        let cofre = CofreDeTokensFalso(access: "access-vencido", refresh: "refresh-1")
        cofre.recusarGravacaoRefresh = errSecInteractionNotAllowed
        let registro = RegistroDeLogout()
        let rede = redeDeTeste(cofre: cofre, registro: registro)

        _ = try await rede.fetchFeatures()
        try #require(rede.parDeTokensPendente != nil)

        // O Keychain voltou a gravar: o pedido seguinte tenta de novo
        // (regra 4) — refresh antes do access, e o pendente some.
        cofre.recusarGravacaoRefresh = nil
        _ = try await rede.fetchFeatures()

        #expect(cofre.ordemGravacoes == ["refresh:refresh-novo", "access:token-novo"])
        #expect(rede.parDeTokensPendente == nil)
        #expect(cofre.access == "token-novo")
        #expect(cofre.refresh == "refresh-novo")
    }

    // MARK: - §4.5: logout, troca de conta e deleteAccount descartam o pendente

    @Test func saidaDeSessaoDescartaOParPendenteDaRede() async throws {
        rotear401AteRenovar()
        let cofre = CofreDeTokensFalso(access: "access-vencido", refresh: "refresh-1")
        cofre.recusarGravacaoRefresh = errSecInteractionNotAllowed
        let registro = RegistroDeLogout()
        let rede = redeDeTeste(cofre: cofre, registro: registro)

        _ = try await rede.fetchFeatures()
        try #require(rede.parDeTokensPendente != nil)

        // Descartado, as leituras voltam a olhar o cofre (regra 5).
        rede.descartarParDeTokensPendente()
        #expect(rede.parDeTokensPendente == nil)
        #expect(rede.buscarRefreshToken() == .achou("refresh-1"))
    }

    @MainActor
    @Test func logoutEDeleteAccountDescartamTokensEmMemoria() async {
        let auth = AuthService()
        var descartadas = 0
        auth.descartarTokensEmMemoria = { descartadas += 1 }
        auth.apagarTokensDoKeychain = {}
        auth.lerRefreshTokenParaRevogar = { nil }

        // Logout normal...
        auth.logout()
        #expect(descartadas == 1)

        // ...troca de conta (o logout de A)...
        auth.logout(revogandoNoServidor: false)
        #expect(descartadas == 2)

        // ...e deleteAccount, que passa pelo mesmo logout (§1.3).
        auth.deletarContaNoServidor = {}
        auth.apagarDadosLocais = { _ in }
        await auth.deleteAccount()
        #expect(descartadas == 3)
    }

    // MARK: - §4.6: `.ilegivel` no access

    @Test func acessoIlegivelNaoSaiEDeslogaUmaVezSo() async throws {
        ProtocoloComRota.estado.zerar { _ in (200, #"{"open_finance":true}"#) }
        let cofre = CofreDeTokensFalso(access: "access-1", refresh: "refresh-1")
        cofre.accessIlegivel = true
        let registro = RegistroDeLogout()
        let rede = redeDeTeste(cofre: cofre, registro: registro)

        // Vários pedidos em voo com o mesmo erro: nenhum sai, todos dão
        // `loginIlegivel` e o logout local roda uma vez só (§2.2).
        var comLoginIlegivel = 0
        await withTaskGroup(of: Bool.self) { grupo in
            for _ in 0..<3 {
                grupo.addTask {
                    do {
                        _ = try await rede.fetchFeatures()
                        return false
                    } catch {
                        if case APIError.loginIlegivel = error { return true }
                        return false
                    }
                }
            }
            for await resultado in grupo {
                if resultado { comLoginIlegivel += 1 }
            }
        }
        #expect(comLoginIlegivel == 3)
        #expect(registro.vezes == 1)
        #expect(ProtocoloComRota.estado.pedidos.isEmpty)
    }

    /// `.ilegivel` no refresh num pedido que saiu e voltou 401: mesmo efeito
    /// — logout local uma vez, sem revogar, e `loginIlegivel` para quem chamou.
    @Test func refreshIlegivelNo401DeslogaUmaVez() async {
        ProtocoloComRota.estado.zerar { _ in (401, #"{"error":"expirado","request_id":"r"}"#) }
        let cofre = CofreDeTokensFalso(access: "access-1", refresh: "refresh-1")
        cofre.refreshIlegivel = true
        let registro = RegistroDeLogout()
        let rede = redeDeTeste(cofre: cofre, registro: registro)

        await #expect {
            _ = try await rede.fetchFeatures()
        } throws: { erro in
            if case APIError.loginIlegivel = erro { return true }
            return false
        }
        #expect(registro.vezes == 1)
    }

    // MARK: - §4.7: `saveUser` fail-closed

    @MainActor
    @Test func loginComGravacaoRecusadaFechaOAcesso() async {
        let auth = AuthService()
        var apagadas = 0
        var revogadas: [String] = []
        auth.entrarNoServidor = { _ in respostaAuth }
        auth.gravarParDeTokens = { _, _ in .recusou(errSecInteractionNotAllowed) }
        auth.apagarTokensDoKeychain = { apagadas += 1 }
        auth.revogarSessaoNoServidor = { revogadas.append($0) }
        UserDefaults.standard.removeObject(forKey: "user_data")

        await auth.login(email: "u1@x.com", senha: "senha")

        // Fail-closed (§1.2): não entra, `user_data` não é gravado, o que foi
        // gravado sai e a sessão nova é revogada em segundo plano.
        #expect(auth.isAuthenticated == false)
        #expect(auth.currentUser == nil)
        #expect(UserDefaults.standard.data(forKey: "user_data") == nil)
        #expect(apagadas == 1)
        #expect(revogadas == ["refresh-teste"])
        #expect(auth.errorMessage == "Não foi possível guardar seu login neste iPhone. Reinicie o iPhone e tente de novo.")
    }

    /// Idem para o cadastro, com a mensagem própria (§1.2 e §4.7).
    @MainActor
    @Test func cadastroComGravacaoRecusadaFechaOAcessoComMensagemPropria() async {
        let auth = AuthService()
        var apagadas = 0
        var revogadas: [String] = []
        auth.registrarNoServidor = { _ in respostaAuth }
        auth.gravarParDeTokens = { _, _ in .recusou(errSecInteractionNotAllowed) }
        auth.apagarTokensDoKeychain = { apagadas += 1 }
        auth.revogarSessaoNoServidor = { revogadas.append($0) }
        UserDefaults.standard.removeObject(forKey: "user_data")

        await auth.register(nome: "Teste", username: "u1", email: "u1@x.com", senha: "senha")

        #expect(auth.isAuthenticated == false)
        #expect(auth.currentUser == nil)
        #expect(UserDefaults.standard.data(forKey: "user_data") == nil)
        #expect(apagadas == 1)
        #expect(revogadas == ["refresh-teste"])
        #expect(auth.errorMessage == "Sua conta foi criada, mas não foi possível guardar o login neste iPhone. Reinicie o iPhone e entre com seu e-mail e senha.")
    }
}
