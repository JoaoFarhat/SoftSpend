import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// I2a de `docs/assinatura.md` (§3.4): o servidor recusa a viagem nova com
/// `403 subscription_required` quando a conta não tem assinatura. O
/// `SyncActor` deixa a viagem na fila (`.pending`, sem backoff, sem descarte,
/// sem logout); os dias e gastos dela esperam o `backendId` do ciclo e sobem
/// todos juntos no `sync(forcar: true)` depois da compra.
@MainActor
struct AssinaturaSyncTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    static let semAssinatura = APIError.serverError(
        message: "subscription_required", requestId: "-", statusCode: 403
    )

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    // MARK: Apoio

    func sync(forcar: Bool = true) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    func hoje(mais dias: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: dias, to: Calendar.current.startOfDay(for: .now))!
    }

    /// Viagem com dois dias e um gasto no primeiro, criada localmente (nada enviado).
    @discardableResult
    func criarViagem(titulo: String = "Cuiabá, MT") throws -> UUID {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 200, gasto_total: 25,
            periodo: "01/09 - 02/09", diaria: 100, titulo: titulo, dias: []
        )
        ctx.insert(ciclo)
        let dia1 = DiaSoftex(data: hoje(), saldo: 75)
        ctx.insert(dia1)
        dia1.ciclo = ciclo
        let dia2 = DiaSoftex(data: hoje(mais: 1), saldo: 100)
        ctx.insert(dia2)
        dia2.ciclo = ciclo
        ctx.insert(GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia1))
        try ctx.save()
        return ciclo.id
    }

    func ciclo(_ id: UUID) throws -> CicloSoftex? {
        try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>(predicate: #Predicate { $0.id == id })).first
    }

    func ciclosLocais() throws -> [CicloSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>())
    }

    func diasLocais() throws -> [DiaSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<DiaSoftex>())
    }

    func gastosLocais() throws -> [GastosDia] {
        try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
    }

    /// Viagem nova recusada pelo servidor (o cenário de quase todos os testes).
    func viagemBloqueada() async throws -> UUID {
        let id = try criarViagem()
        api.falhar(.postCiclo, com: Self.semAssinatura)
        _ = await sync()
        return id
    }

    // MARK: 1. Fica na fila, sem backoff

    @Test func viagemNovaCom403FicaPendenteSemBackoff() async throws {
        let id = try await viagemBloqueada()

        let local = try #require(try ciclo(id))
        #expect(local.syncStatus == .pending)
        #expect(local.tentativas == 0)
        #expect(local.proximaTentativaEm == nil)
        #expect(local.syncError == SyncActor.erroAssinaturaNecessaria)
        #expect(local.backendId == nil)
        #expect(api.ciclos.isEmpty)
    }

    // MARK: 2. Dias e gastos nunca são enviados

    @Test func diasEGastosDaViagemBloqueadaNaoSaoEnviados() async throws {
        _ = try await viagemBloqueada()
        _ = await sync()

        #expect(!api.chamadas.contains(.postDiasLote))
        #expect(!api.chamadas.contains(.postGasto))
        #expect(api.dias.isEmpty)
        #expect(api.gastos.isEmpty)
        // Continuam no aparelho, pendentes e sem erro de falha.
        let dias = try diasLocais()
        let gastos = try gastosLocais()
        #expect(dias.count == 2)
        #expect(gastos.count == 1)
        #expect(dias.allSatisfy { $0.syncStatus == .pending && $0.tentativas == 0 })
        #expect(gastos.allSatisfy { $0.syncStatus == .pending && $0.tentativas == 0 })
    }

    // MARK: 3. Um POST de ciclo por sync

    @Test func soUmPostCicloPorSync() async throws {
        try criarViagem()
        api.falhar(.postCiclo, com: Self.semAssinatura)

        let restantes = await sync()
        #expect(api.chamadas == [.postCiclo])
        // Ciclo + 2 dias + 1 gasto contam como aguardando envio.
        #expect(restantes == 4)

        api.limparChamadas()
        _ = await sync()
        #expect(api.chamadas == [.postCiclo])
    }

    /// Outra viagem (já no servidor) progredindo faz o loop rodar mais
    /// passadas; a bloqueada não é reenviada nelas.
    @Test func viagemBloqueadaNaoReenviaNasPassadasSeguintes() async throws {
        // Viagem já sincronizada, com um dia novo ainda não enviado.
        try criarViagem(titulo: "Recife, PE")
        #expect(await sync() == 0)
        let ctx = ModelContext(container)
        let antiga = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        let diaNovo = DiaSoftex(data: hoje(mais: 2), saldo: 100)
        ctx.insert(diaNovo)
        diaNovo.ciclo = antiga
        try ctx.save()

        // Viagem nova, recusada.
        try criarViagem()
        api.falhar(.postCiclo, com: Self.semAssinatura)
        api.limparChamadas()
        _ = await sync()

        #expect(api.chamadas.filter { $0 == .postCiclo }.count == 1)
        #expect(api.chamadas.contains(.postDiasLote))
    }

    // MARK: 4. Depois da compra, tudo sobe na mesma chamada

    @Test func depoisDaCompraTudoSobeNaMesmaChamada() async throws {
        let id = try await viagemBloqueada()

        api.pararDeFalhar(.postCiclo)
        api.limparChamadas()
        #expect(await sync(forcar: true) == 0)

        #expect(api.ciclos.count == 1)
        #expect(api.dias.count == 2)
        #expect(api.gastos.count == 1)
        #expect(api.chamadas.filter { $0 == .postCiclo }.count == 1)
        let local = try #require(try ciclo(id))
        #expect(local.syncStatus == .synced)
        #expect(local.syncError == nil)
        #expect(local.backendId != nil)
        let dias = try diasLocais()
        let gastos = try gastosLocais()
        #expect(dias.allSatisfy { $0.syncStatus == .synced })
        #expect(gastos.allSatisfy { $0.syncStatus == .synced })
    }

    // MARK: 5. Outro 403 continua sendo falha

    @Test func outro403VaiParaFalhaComBackoff() async throws {
        let id = try criarViagem()
        api.falhar(.postCiclo, com: APIError.serverError(message: "forbidden", requestId: "-", statusCode: 403))
        _ = await sync()

        let local = try #require(try ciclo(id))
        #expect(local.syncStatus == .failed)
        #expect(local.tentativas == 1)
        #expect(local.proximaTentativaEm != nil)
        #expect(local.syncError == "forbidden")
    }

    // MARK: 6. 500 e erro de rede seguem como hoje

    nonisolated enum ErroComum: CaseIterable, Sendable {
        case servidor500, semRede

        var erro: any Error {
            switch self {
            case .servidor500: return FakeSyncAPI.erroSimulado
            case .semRede: return URLError(.notConnectedToInternet)
            }
        }
    }

    @Test(arguments: ErroComum.allCases)
    func erro500ERedeSeguemComoHoje(_ caso: ErroComum) async throws {
        let erro = caso.erro
        let id = try criarViagem()
        api.falhar(.postCiclo, com: erro)
        _ = await sync()

        let local = try #require(try ciclo(id))
        #expect(local.syncStatus == .failed)
        #expect(local.tentativas == 1)
        #expect(local.proximaTentativaEm != nil)
        #expect(local.syncError == erro.localizedDescription)
        #expect(local.syncError != SyncActor.erroAssinaturaNecessaria)
        // Fora da regra da assinatura: apagá-la ainda repete o POST (T7).
        #expect(local.podeTerSidoCriadoNoServidor)
    }

    // MARK: 7. Sem logout nem renovação de token

    @Test func assinaturaNaoRenovaTokenNemDesloga() async throws {
        // Só o 401 passa pela renovação/logout do NetworkManager.execute.
        #expect(deveRenovarToken(statusCode: 401, logout401: true))
        #expect(!deveRenovarToken(statusCode: 403, logout401: true))
        #expect(!deveRenovarToken(statusCode: 401, logout401: false))

        // Detecção no erro tipado.
        #expect(Self.semAssinatura.assinaturaNecessaria)
        #expect(!APIError.serverError(message: "forbidden", requestId: "-", statusCode: 403).assinaturaNecessaria)
        #expect(!APIError.serverError(message: "subscription_required", requestId: "-", statusCode: 401).assinaturaNecessaria)
        #expect(!APIError.authentication.assinaturaNecessaria)

        // O sync não faz nada além do POST recusado (nenhuma outra chamada,
        // nenhum dado apagado no aparelho).
        _ = try await viagemBloqueada()
        #expect(api.chamadas == [.postCiclo])
        #expect(try ciclosLocais().count == 1)
        #expect(try diasLocais().count == 2)
        #expect(try gastosLocais().count == 1)
    }

    // MARK: 8. Apagar a viagem bloqueada

    @Test func apagarViagemBloqueadaNaoFazRequisicao() async throws {
        _ = try await viagemBloqueada()

        let ctx = ModelContext(container)
        let viagem = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        #expect(!viagem.podeTerSidoCriadoNoServidor)
        let vm = CiclosViewModel()
        vm.modelContext = ctx
        vm.allCiclos = [viagem]
        vm.atualCiclo = viagem
        try await vm.deleteCiclo(ciclo: viagem)

        #expect(try ciclosLocais().isEmpty)
        #expect(try diasLocais().isEmpty)
        #expect(try gastosLocais().isEmpty)

        api.limparChamadas()
        #expect(await sync() == 0)
        #expect(api.chamadas.isEmpty)
    }

    /// O marcador vale mais que `tentativas`: uma tentativa anterior (timeout)
    /// seguida do 403 garante que o `client_id` não está no servidor.
    @Test func marcadorTiraDoTalvezNoServidorMesmoComTentativas() throws {
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 100, gasto_total: 0,
            periodo: "01/09 - 01/09", diaria: 100, titulo: "x", dias: []
        )
        ciclo.tentativas = 2
        ciclo.syncError = SyncActor.erroAssinaturaNecessaria
        #expect(!ciclo.podeTerSidoCriadoNoServidor)
    }

    /// Viagem que já estava marcada como apagada (T7, POST com resposta
    /// perdida) e cuja recuperação do id recebe o 403: não está no servidor,
    /// sai do aparelho sem DELETE e sem backoff.
    @Test func recuperacaoDoIdCom403ContaComoNaoExiste() async throws {
        let id = try criarViagem()
        api.falhar(.postCiclo)
        _ = await sync()
        let ctx = ModelContext(container)
        let local = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>(predicate: #Predicate { $0.id == id })).first)
        try #require(local.podeTerSidoCriadoNoServidor)
        local.deletadoEm = .now
        local.syncStatus = .pending
        try ctx.save()

        api.falhar(.postCiclo, com: Self.semAssinatura)
        api.limparChamadas()
        _ = await sync()

        #expect(api.chamadas == [.postCiclo])
        let final = try #require(try ciclo(id))
        #expect(final.syncStatus == .synced)
        #expect(final.backendId == nil)
    }

    // MARK: 9. Viagem que já existe no servidor não é afetada

    @Test func edicaoDeViagemExistenteSegueNormal() async throws {
        let id = try criarViagem()
        #expect(await sync() == 0)
        let backendId = try #require(try ciclo(id)?.backendId)

        let ctx = ModelContext(container)
        let local = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>(predicate: #Predicate { $0.id == id })).first)
        local.titulo = "Cuiabá e Chapada"
        local.syncStatus = .pending
        try ctx.save()

        api.falhar(.postCiclo, com: Self.semAssinatura)
        api.limparChamadas()
        #expect(await sync() == 0)

        #expect(api.chamadas == [.putCiclo])
        #expect(api.ciclos.first(where: { $0.id == backendId })?.titulo == "Cuiabá e Chapada")
        let final = try #require(try ciclo(id))
        #expect(final.syncStatus == .synced)
        #expect(final.syncError == nil)
    }

    // MARK: Na tela

    @Test func gastoDaViagemBloqueadaMostraAssinaturaNecessaria() async throws {
        _ = try await viagemBloqueada()
        let gasto = try #require(try gastosLocais().first)

        let estado = EstadoEnvio.de(gasto)
        #expect(estado == .aguardandoAssinatura)
        #expect(estado.rotulo == "Assinatura necessária")
        #expect(estado.rotulo != EstadoEnvio.falhou("").rotulo)
        #expect(estado.detalhe == SyncActor.erroAssinaturaNecessaria)
        #expect(estado.simbolo == "lock")
    }
}
