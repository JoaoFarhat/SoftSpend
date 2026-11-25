import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Usuário logado falso para o `SyncActor` (`init(usuarioAtual:)`): o teste
/// troca de conta no meio do envio sem mexer no `AuthService.shared`.
nonisolated final class UsuarioFalso: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String?

    init(_ id: String?) { _id = id }

    var id: String? { lock.withLock { _id } }

    func trocar(para novo: String?) { lock.withLock { _id = novo } }
}

/// Trocar de conta no meio do envio não pode mandar dados de uma conta com o
/// login da outra. O `NetworkManager` lê o token a cada pedido; o `SyncActor`
/// confere o usuário logado antes e depois de cada chamada à API e, se ele
/// mudou, para o `sync` sem marcar nada (sem falha, sem sucesso, sem descarte).
@MainActor
struct TrocaDeContaSyncTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let usuario = UsuarioFalso("A")

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    func novoSyncActor() -> SyncActor {
        let usuario = self.usuario
        return SyncActor(modelContainer: container, api: api, usuarioAtual: { usuario.id })
    }

    func sync(_ syncActor: SyncActor) async -> Int {
        await syncActor.sync(agora: .now, userId: "A")
    }

    /// Viagem da conta "A" criada sem internet (nada com `backendId`), já salva.
    func criarViagemOffline(comGasto: Bool = true) throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: "A", valor_total: 300, gasto_total: comGasto ? 25 : 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        if comGasto {
            let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
            ctx.insert(gasto)
        }
        try ctx.save()
    }

    /// Gasto novo (ainda não enviado) no dia que já existe.
    func lancarGasto() throws {
        let ctx = ModelContext(container)
        let dia = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        dia.ciclo?.gasto_total += 25
        try ctx.save()
    }

    func ciclosLocais() throws -> [CicloSoftex] { try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>()) }
    func diasLocais() throws -> [DiaSoftex] { try ModelContext(container).fetch(FetchDescriptor<DiaSoftex>()) }
    func gastosLocais() throws -> [GastosDia] { try ModelContext(container).fetch(FetchDescriptor<GastosDia>()) }

    /// Como o item estava antes do envio: nada marcado.
    func esperarIntocado(_ item: any Syncavel) {
        #expect(item.syncStatus == .pending)
        #expect(item.tentativas == 0)
        #expect(item.syncError == nil)
        #expect(item.proximaTentativaEm == nil)
    }

    /// (a) A sai e B entra com o `POST` da viagem de A em voo: nenhuma chamada
    /// depois dele, a resposta é ignorada e dia e gasto de A seguem no
    /// aparelho, não enviados.
    @Test func trocaDuranteOPostDaViagemNaoEnviaMaisNada() async throws {
        try criarViagemOffline()
        let portao = api.segurar(.postCiclo)
        let syncActor = novoSyncActor()

        let tarefa = Task { await sync(syncActor) }
        try #require(await portao.chegouAntes(doFimDe: tarefa), "o sync não chegou ao postCiclo")
        usuario.trocar(para: "B")
        await portao.liberar()
        let restantes = await tarefa.value

        #expect(api.chamadas == [.postCiclo])
        #expect(restantes == 3)
        let ciclo = try #require(try ciclosLocais().first)
        #expect(ciclo.backendId == nil)
        esperarIntocado(ciclo)
        let dia = try #require(try diasLocais().first)
        #expect(dia.backendId == nil)
        esperarIntocado(dia)
        let gasto = try #require(try gastosLocais().first)
        #expect(gasto.backendId == nil)
        #expect(gasto.deletadoEm == nil)
        esperarIntocado(gasto)
    }

    /// Depois da troca, quando A entra de novo, tudo sobe; o `client_id` faz o
    /// servidor devolver a viagem já criada, sem duplicar.
    @Test func quandoODonoVoltaTudoSobeSemDuplicar() async throws {
        try criarViagemOffline()
        let portao = api.segurar(.postCiclo)
        let syncActor = novoSyncActor()
        let tarefa = Task { await sync(syncActor) }
        try #require(await portao.chegouAntes(doFimDe: tarefa), "o sync não chegou ao postCiclo")
        usuario.trocar(para: "B")
        await portao.liberar()
        _ = await tarefa.value

        usuario.trocar(para: "A")
        api.limparChamadas()
        let restantes = await sync(syncActor)

        #expect(restantes == 0)
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        #expect(api.ciclos.count == 1)
        #expect(api.gastos.count == 1)
        #expect(try gastosLocais().first?.syncStatus == .synced)
    }

    /// Logout puro (ninguém logado) no meio do envio também para tudo.
    @Test func logoutDuranteOEnvioParaTudo() async throws {
        try criarViagemOffline()
        let portao = api.segurar(.postCiclo)
        let syncActor = novoSyncActor()
        let tarefa = Task { await sync(syncActor) }
        try #require(await portao.chegouAntes(doFimDe: tarefa), "o sync não chegou ao postCiclo")
        usuario.trocar(para: nil)
        await portao.liberar()
        _ = await tarefa.value

        #expect(api.chamadas == [.postCiclo])
        let ciclo = try #require(try ciclosLocais().first)
        esperarIntocado(ciclo)
    }

    /// Com outra conta já logada quando o sync começa, nenhuma chamada sai.
    @Test func outraContaJaLogadaNaoChamaAAPI() async throws {
        try criarViagemOffline()
        usuario.trocar(para: "B")

        let restantes = await sync(novoSyncActor())

        #expect(api.chamadas.isEmpty)
        #expect(restantes == 3)
        let gasto = try #require(try gastosLocais().first)
        esperarIntocado(gasto)
    }

    /// (b) 404 com `request_id` no `POST` do gasto de A, chegado depois da
    /// troca: não prova que o dia de A sumiu (o servidor respondeu pela conta
    /// de B). O gasto **não** é descartado.
    @Test func notFoundDepoisDaTrocaNaoDescartaOGasto() async throws {
        try criarViagemOffline(comGasto: false)
        #expect(await sync(novoSyncActor()) == 0)
        try lancarGasto()
        api.limparChamadas()
        let portao = api.segurar(.postGasto)
        api.falhar(.postGasto, com: FakeSyncAPI.naoEncontrado)
        let syncActor = novoSyncActor()

        let tarefa = Task { await sync(syncActor) }
        try #require(await portao.chegouAntes(doFimDe: tarefa), "o sync não chegou ao postGasto")
        usuario.trocar(para: "B")
        await portao.liberar()
        _ = await tarefa.value

        #expect(api.chamadas == [.postGasto])
        let gasto = try #require(try gastosLocais().first, "o gasto de A foi descartado")
        #expect(gasto.backendId == nil)
        esperarIntocado(gasto)
        #expect(try ciclosLocais().first?.gasto_total == 25)
    }

    /// Controle do caso (b): sem troca, o mesmo 404 descarta o gasto como hoje
    /// (T4) — prova que o teste acima passou pelo ramo do 404.
    @Test func notFoundSemTrocaDescartaComoHoje() async throws {
        try criarViagemOffline(comGasto: false)
        #expect(await sync(novoSyncActor()) == 0)
        try lancarGasto()
        api.falhar(.postGasto, com: FakeSyncAPI.naoEncontrado)

        _ = await sync(novoSyncActor())

        #expect(try gastosLocais().isEmpty)
        #expect(try ciclosLocais().first?.gasto_total == 0)
    }

    /// `DELETE` do gasto em voo durante a troca: a exclusão não é dada como
    /// feita e volta a ser enviada quando A entrar de novo.
    @Test func trocaDuranteODeleteNaoMarcaSucesso() async throws {
        try criarViagemOffline()
        #expect(await sync(novoSyncActor()) == 0)
        do {
            let ctx = ModelContext(container)
            let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
            gasto.deletadoEm = .now
            gasto.syncStatus = .pending
            try ctx.save()
        }
        api.limparChamadas()
        let portao = api.segurar(.deleteGasto)
        let syncActor = novoSyncActor()

        let tarefa = Task { await sync(syncActor) }
        try #require(await portao.chegouAntes(doFimDe: tarefa), "o sync não chegou ao deleteGasto")
        usuario.trocar(para: "B")
        await portao.liberar()
        _ = await tarefa.value

        #expect(api.chamadas == [.deleteGasto])
        let gasto = try #require(try gastosLocais().first)
        #expect(gasto.syncStatus == .pending)
        #expect(gasto.tentativas == 0)
    }

    /// (c) Sem troca, o envio é igual ao de hoje.
    @Test func semTrocaOEnvioEIgualAoDeHoje() async throws {
        try criarViagemOffline()

        let restantes = await sync(novoSyncActor())

        #expect(restantes == 0)
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        let ciclo = try #require(try ciclosLocais().first)
        let dia = try #require(try diasLocais().first)
        let gasto = try #require(try gastosLocais().first)
        #expect(ciclo.syncStatus == .synced)
        #expect(dia.syncStatus == .synced)
        #expect(gasto.syncStatus == .synced)
        #expect(ciclo.backendId == api.ciclos.first?.id)
        #expect(dia.backendId == api.dias.first?.id)
        #expect(gasto.backendId == api.gastos.first?.id)
    }
}

// Troca o usuário global: em série com as outras suítes (ver `UsuarioGlobalTests`).
extension UsuarioGlobalTests {

/// O `SyncManager` relê o usuário logado a cada volta do `repeat`: um pedido
/// guardado durante o envio de A não roda depois do logout.
@MainActor
struct TrocaDeContaSyncManagerTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    @Test func logoutNoMeioNaoRodaAVoltaGuardada() async throws {
        let usuarioAnterior = AuthService.shared.currentUser
        AuthService.shared.currentUser = UserModel(
            id: userId, nome: "Teste", username: "teste", email: "t@t.com"
        )
        defer { AuthService.shared.currentUser = usuarioAnterior }

        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        // Em backoff: a primeira volta (sem `forcar`) o pula; só a volta
        // guardada (forçada) o enviaria.
        gasto.syncStatus = .failed
        gasto.syncError = "Falha anterior"
        gasto.tentativas = 1
        gasto.proximaTentativaEm = .now.addingTimeInterval(3600)
        try ctx.save()

        let portao = api.segurar(.postCiclo)
        let manager = SyncManager(estaConectado: { true })
        manager.injetarSyncActor(SyncActor(modelContainer: container, api: api))

        let primeira = Task { await manager.sync() }
        let guarda = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await portao.desistirDaChegada()
        }
        await portao.aguardarChegada()
        guarda.cancel()
        try #require(await portao.jaChegou, "o sync não chegou ao postCiclo")

        await manager.sync(forcar: true) // guardado para o fim
        AuthService.shared.currentUser = nil // logout no meio
        await portao.liberar()
        await primeira.value

        #expect(manager.isSyncing == false)
        // A volta em andamento termina (este actor não confere o usuário);
        // a guardada não roda: o postGasto forçado nunca sai.
        #expect(api.chamadas == [.postCiclo, .postDiasLote])
        #expect(manager.pendentesRestantes == 0)
    }
}

}  // extension UsuarioGlobalTests
