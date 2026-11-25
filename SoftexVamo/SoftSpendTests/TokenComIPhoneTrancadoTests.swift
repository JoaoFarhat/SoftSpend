import Testing
import Foundation
import Security
import SwiftData
@testable import SoftSpend

// MARK: - Apoio

/// Cofre de tokens em memória. `accessTrancado`/`refreshTrancado` simulam o
/// iPhone trancado (`errSecInteractionNotAllowed`): o token continua guardado,
/// só não é entregue. `accessIlegivel`/`refreshIlegivel` simulam a leitura
/// que o desbloqueio não resolve (`.ilegivel`); `recusarGravacaoAccess`/
/// `recusarGravacaoRefresh` fazem a gravação devolver `.recusou` sob comando,
/// sem guardar nada.
nonisolated final class CofreDeTokensFalso: CofreDeTokens, @unchecked Sendable {
    private let lock = NSLock()
    private var _access: String?
    private var _refresh: String?
    private var _accessTrancado = false
    private var _refreshTrancado = false
    private var _accessIlegivel = false
    private var _refreshIlegivel = false
    private var _recusarGravacaoAccess: OSStatus?
    private var _recusarGravacaoRefresh: OSStatus?
    private var _gravacoes = 0
    private var _apagadas = 0
    private var _ordemGravacoes: [String] = []
    private var _tentativasAccess = 0

    init(access: String?, refresh: String?) {
        _access = access
        _refresh = refresh
    }

    var gravacoes: Int { lock.withLock { _gravacoes } }
    var apagadas: Int { lock.withLock { _apagadas } }
    /// "refresh:<token>" e "access:<token>", na ordem em que foram gravados.
    var ordemGravacoes: [String] { lock.withLock { _ordemGravacoes } }
    /// Chamadas ao `gravarAccessToken` — com a recusa do refresh o access nem
    /// tenta (§1.1, regra 1), então o teste conta as tentativas.
    var tentativasAccess: Int { lock.withLock { _tentativasAccess } }

    var accessTrancado: Bool {
        get { lock.withLock { _accessTrancado } }
        set { lock.withLock { _accessTrancado = newValue } }
    }

    var refreshTrancado: Bool {
        get { lock.withLock { _refreshTrancado } }
        set { lock.withLock { _refreshTrancado = newValue } }
    }

    var accessIlegivel: Bool {
        get { lock.withLock { _accessIlegivel } }
        set { lock.withLock { _accessIlegivel = newValue } }
    }

    var refreshIlegivel: Bool {
        get { lock.withLock { _refreshIlegivel } }
        set { lock.withLock { _refreshIlegivel = newValue } }
    }

    /// `nil` grava normal; com um `OSStatus` a gravação devolve `.recusou`
    /// sem guardar nada — como um Keychain que nega a escrita.
    var recusarGravacaoAccess: OSStatus? {
        get { lock.withLock { _recusarGravacaoAccess } }
        set { lock.withLock { _recusarGravacaoAccess = newValue } }
    }

    var recusarGravacaoRefresh: OSStatus? {
        get { lock.withLock { _recusarGravacaoRefresh } }
        set { lock.withLock { _recusarGravacaoRefresh = newValue } }
    }

    var access: String? { lock.withLock { _access } }
    var refresh: String? { lock.withLock { _refresh } }

    func buscarAccessToken() -> ResultadoLeituraToken {
        lock.withLock { Self.ler(_access, trancado: _accessTrancado, ilegivel: _accessIlegivel) }
    }

    func buscarRefreshToken() -> ResultadoLeituraToken {
        lock.withLock { Self.ler(_refresh, trancado: _refreshTrancado, ilegivel: _refreshIlegivel) }
    }

    /// Como o Keychain: trancado, devolve `nil` (sem dizer por quê).
    func lerAccessToken() -> String? { buscarAccessToken().token }
    func lerRefreshToken() -> String? { buscarRefreshToken().token }

    func gravarAccessToken(_ token: String) -> ResultadoGravacaoToken {
        lock.withLock {
            _tentativasAccess += 1
            if let recusa = _recusarGravacaoAccess { return .recusou(recusa) }
            _gravacoes += 1
            _access = token
            _ordemGravacoes.append("access:\(token)")
            return .gravou
        }
    }

    func gravarRefreshToken(_ token: String) -> ResultadoGravacaoToken {
        lock.withLock {
            if let recusa = _recusarGravacaoRefresh { return .recusou(recusa) }
            _gravacoes += 1
            _refresh = token
            _ordemGravacoes.append("refresh:\(token)")
            return .gravou
        }
    }

    func apagarTokens() {
        lock.withLock {
            _apagadas += 1
            _access = nil
            _refresh = nil
        }
    }

    private static func ler(_ token: String?, trancado: Bool, ilegivel: Bool) -> ResultadoLeituraToken {
        if ilegivel { return .ilegivel(errSecParam) }
        if trancado { return .indisponivel(errSecInteractionNotAllowed) }
        guard let token else { return .naoExiste }
        return .achou(token)
    }
}

/// Estado do `ProtocoloFalso`: os pedidos que chegaram e o status a responder.
nonisolated final class EstadoProtocoloFalso: @unchecked Sendable {
    private let lock = NSLock()
    private var _pedidos: [URLRequest] = []
    private var _status = 200

    var pedidos: [URLRequest] { lock.withLock { _pedidos } }

    func zerar(status: Int) {
        lock.withLock {
            _pedidos = []
            _status = status
        }
    }

    func registrar(_ pedido: URLRequest) -> Int {
        lock.withLock {
            _pedidos.append(pedido)
            return _status
        }
    }
}

/// Responde todo pedido das sessões do `NetworkManager` sem rede, com o status
/// de `estado`, e guarda o que chegou. Próprio deste arquivo (como o
/// `URLProtocolSessaoTrocada`): suítes diferentes rodam em paralelo e não
/// podem dividir o estado estático do `URLProtocolDeTeste`.
nonisolated final class ProtocoloFalso: URLProtocol {
    nonisolated static let estado = EstadoProtocoloFalso()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.estado.registrar(request)
        let url = request.url ?? URL(string: "https://teste.invalid")!
        let resposta = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resposta, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Conta as chamadas de `aoDeslogar` do `NetworkManager`.
nonisolated final class RegistroDeLogout: @unchecked Sendable {
    private let lock = NSLock()
    private var _vezes = 0

    var vezes: Int { lock.withLock { _vezes } }

    func deslogar() {
        lock.withLock { _vezes += 1 }
    }
}

private func ehChaveIndisponivel(_ erro: Error) -> Bool {
    if case APIError.chaveIndisponivel = erro { return true }
    return false
}

private func ehAutenticacao(_ erro: Error) -> Bool {
    if case APIError.authentication = erro { return true }
    return false
}

// MARK: - NetworkManager

/// Tokens no Keychain com `WhenUnlockedThisDeviceOnly`: com a tela trancada o
/// Keychain não os entrega. Antes, o pedido saía sem `Authorization`, o 401
/// procurava o refresh token, não achava e deslogava — a pessoa voltava para
/// a tela de login depois de um envio longo com a tela apagando no meio.
///
/// `.serialized`: o `ProtocoloFalso` guarda o estado num `static`.
@Suite(.serialized)
struct TokenComIPhoneTrancadoTests {

    func montar(_ cofre: CofreDeTokensFalso, status: Int) -> (NetworkManager, RegistroDeLogout) {
        ProtocoloFalso.estado.zerar(status: status)
        let registro = RegistroDeLogout()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProtocoloFalso.self]
        let sessao = URLSession(configuration: config)
        let rede = NetworkManager(
            session: sessao,
            uploadSession: sessao,
            tokens: cofre,
            aoDeslogar: { registro.deslogar() }
        )
        return (rede, registro)
    }

    /// (a) Access token trancado: o pedido nem sai, o erro é
    /// `.chaveIndisponivel`, ninguém desloga e os tokens ficam.
    @Test func accessTokenTrancadoNaoMandaPedidoNemDesloga() async {
        let cofre = CofreDeTokensFalso(access: "access-1", refresh: "refresh-1")
        cofre.accessTrancado = true
        cofre.refreshTrancado = true
        let (rede, registro) = montar(cofre, status: 200)

        await #expect {
            _ = try await rede.fetchFeatures()
        } throws: { ehChaveIndisponivel($0) }

        #expect(ProtocoloFalso.estado.pedidos.isEmpty)
        #expect(registro.vezes == 0)
        #expect(cofre.gravacoes == 0)
        #expect(cofre.apagadas == 0)
        cofre.accessTrancado = false
        cofre.refreshTrancado = false
        #expect(cofre.buscarAccessToken() == .achou("access-1"))
        #expect(cofre.buscarRefreshToken() == .achou("refresh-1"))
    }

    /// O pedido de envio do sync (`POST /ciclos`) também não sai.
    @Test func postDoSyncComTokenTrancadoNaoSai() async {
        let cofre = CofreDeTokensFalso(access: "access-1", refresh: "refresh-1")
        cofre.accessTrancado = true
        let (rede, registro) = montar(cofre, status: 200)

        await #expect {
            _ = try await rede.postCiclo(request: CicloCreateRequest(
                client_id: UUID().uuidString, titulo: "Cuiabá, MT",
                valor_total: 300, diaria: 100, periodo: "01/09 - 03/09"
            ))
        } throws: { ehChaveIndisponivel($0) }

        #expect(ProtocoloFalso.estado.pedidos.isEmpty)
        #expect(registro.vezes == 0)
    }

    /// (b) 401 (access vencido) com o refresh token trancado: não chama o
    /// `/auth/refresh`, não desloga, e os tokens ficam como estavam.
    @Test func refreshTokenTrancadoNo401NaoDesloga() async {
        let cofre = CofreDeTokensFalso(access: "access-vencido", refresh: "refresh-1")
        cofre.refreshTrancado = true
        let (rede, registro) = montar(cofre, status: 401)

        await #expect {
            _ = try await rede.fetchFeatures()
        } throws: { ehChaveIndisponivel($0) }

        // Só o pedido original chegou, com o token que o cofre entregou.
        let pedidos = ProtocoloFalso.estado.pedidos
        #expect(pedidos.count == 1)
        #expect(pedidos.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access-vencido")
        #expect(registro.vezes == 0)
        #expect(cofre.gravacoes == 0)
        #expect(cofre.apagadas == 0)
        cofre.refreshTrancado = false
        #expect(cofre.buscarAccessToken() == .achou("access-vencido"))
        #expect(cofre.buscarRefreshToken() == .achou("refresh-1"))
    }

    /// (d) Sem token nenhum (`.naoExiste`): continua como sempre — o pedido sai
    /// sem token, o 401 não acha refresh token e desloga.
    @Test func semTokenContinuaDeslogando() async {
        let cofre = CofreDeTokensFalso(access: nil, refresh: nil)
        let (rede, registro) = montar(cofre, status: 401)

        await #expect {
            _ = try await rede.fetchFeatures()
        } throws: { ehAutenticacao($0) }

        let pedidos = ProtocoloFalso.estado.pedidos
        #expect(pedidos.count == 1)
        #expect(pedidos.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(registro.vezes == 1)
    }

    /// Access token legível e refresh token sumido: 401 desloga, como antes.
    @Test func refreshTokenAusenteNo401Desloga() async {
        let cofre = CofreDeTokensFalso(access: "access-vencido", refresh: nil)
        let (rede, registro) = montar(cofre, status: 401)

        await #expect {
            _ = try await rede.fetchFeatures()
        } throws: { ehAutenticacao($0) }

        #expect(registro.vezes == 1)
    }

    @Test func chaveIndisponivelNaoDeslogaNemRepete() {
        #expect(!deveDeslogarAposFalhaDeRefresh(APIError.chaveIndisponivel))
        #expect(!ehFalhaTransitoriaDeRefresh(APIError.chaveIndisponivel))
        #expect(APIError.chaveIndisponivel.errorDescription == "Desbloqueie o iPhone para continuar.")
    }
}

// MARK: - SyncActor

/// (c) `.chaveIndisponivel` no `SyncActor` segue o caminho do limite por
/// minuto: o item fica `.pending`, sem contar tentativa e sem erro na tela,
/// tenta de novo daqui a 60 s, e nenhuma outra chamada à API sai no mesmo
/// `sync` (todo pedido seguinte daria o mesmo erro).
@MainActor
struct TokenTrancadoNoSyncTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    /// Ciclo → dia → gasto criados offline (nenhum com `backendId`).
    func criarViagemOffline(titulo: String = "Cuiabá, MT") throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: titulo, dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        ctx.insert(GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()
    }

    func sync(agora: Date, forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: agora, userId: userId, forcar: forcar)
    }

    func ciclos() throws -> [CicloSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>())
    }

    @Test func viagemFicaPendingSemTentativaEOSyncPara() async throws {
        try criarViagemOffline(titulo: "Cuiabá, MT")
        try criarViagemOffline(titulo: "Recife, PE")
        api.falhar(.postCiclo, com: APIError.chaveIndisponivel)
        let agora = Date()

        _ = await sync(agora: agora, forcar: true)

        // Uma chamada só: a segunda viagem, os dias e os gastos não tentaram.
        #expect(api.chamadas == [.postCiclo])
        let todos = try ciclos()
        #expect(todos.count == 2)
        let recusado = try #require(todos.first { $0.tentativas > 0 || $0.proximaTentativaEm != nil })
        #expect(recusado.syncStatus == .pending)
        #expect(recusado.tentativas == 0)
        #expect(recusado.syncError == nil)
        #expect(recusado.proximaTentativaEm == agora.addingTimeInterval(60))
        #expect(recusado.backendId == nil)
        for ciclo in todos {
            #expect(ciclo.syncStatus == .pending)
            #expect(ciclo.tentativas == 0)
            #expect(ciclo.syncError == nil)
        }
    }

    /// Gasto já com dia no servidor: o PUT/POST recusado pelo token trancado
    /// fica `.pending` e a remoção pendente nem tenta.
    @Test func gastoFicaPendingEApagarNaoTenta() async throws {
        try criarViagemOffline()
        _ = await sync(agora: .now)
        try #require(api.gastos.count == 1)

        // Um gasto novo e outro marcado como apagado, ambos esperando envio.
        let ctx = ModelContext(container)
        let dia = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        let novo = GastosDia(valor: 10, titulo: "Café", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(novo)
        let antigo = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first { $0.backendId != nil })
        antigo.deletadoEm = .now
        antigo.syncStatus = .pending
        try ctx.save()
        let novoId = novo.id

        api.limparChamadas()
        api.falhar(.postGasto, com: APIError.chaveIndisponivel)
        let agora = Date()
        _ = await sync(agora: agora)

        #expect(api.chamadas == [.postGasto])
        let lido = try #require(try ModelContext(container).fetch(
            FetchDescriptor<GastosDia>(predicate: #Predicate { $0.id == novoId })
        ).first)
        #expect(lido.syncStatus == .pending)
        #expect(lido.tentativas == 0)
        #expect(lido.syncError == nil)
        #expect(lido.proximaTentativaEm == agora.addingTimeInterval(60))
        #expect(api.gastos.count == 1)
    }

    /// Desbloqueado, o próximo sync (passados os 60 s) sobe tudo.
    @Test func depoisDoDesbloqueioSobeTudo() async throws {
        try criarViagemOffline()
        api.falhar(.postCiclo, com: APIError.chaveIndisponivel)
        let agora = Date()
        _ = await sync(agora: agora)

        api.pararDeFalhar(.postCiclo)
        let restantes = await sync(agora: agora.addingTimeInterval(61))

        #expect(restantes == 0)
        #expect(api.ciclos.count == 1)
        #expect(api.dias.count == 1)
        #expect(api.gastos.count == 1)
    }
}
