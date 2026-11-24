import Testing
import Foundation
import SwiftData
@testable import SoftSpend

// Em série com as outras suítes do usuário global: ver `UsuarioGlobalTests`.
extension UsuarioGlobalTests {

/// T9 de `docs/revisao-sync-offline-ios.md` (R9): um `sync()` pedido enquanto
/// outro roda não é mais descartado — o `SyncManager` lembra (`pedidoPendente`,
/// juntando o `forcar` com OU) e roda mais uma vez ao fim.
@MainActor
struct SyncManagerPedidoTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    /// Duas chamadas seguidas executam duas rodadas. A primeira sobe ciclo e
    /// dia; o gasto — `failed` e em backoff — é pulado porque a primeira
    /// chamada não era forçada. A segunda, pedida durante a primeira com
    /// `forcar`, roda no fim e ignora o backoff. Sem o `pedidoPendente`, o
    /// gasto ficaria `failed` até o próximo gatilho (reabrir o app, a rede
    /// voltar).
    @Test func pedidoDuranteOSyncRodaMaisUmaVez() async throws {
        // O sync do SyncManager exige usuário autenticado e conexão.
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
        // O gasto já falhou antes e está em backoff: a rodada não forçada o pula.
        gasto.syncStatus = .failed
        gasto.syncError = "Falha anterior"
        gasto.tentativas = 1
        gasto.proximaTentativaEm = .now.addingTimeInterval(3600)
        try ctx.save()

        let portao = api.segurar(.postCiclo) // o sync fica parado no POST do ciclo

        // `estaConectado: { true }`: sem ele, um CI rodando sem rede faria o
        // sync cair no ramo offline e a FakeSyncAPI nunca seria chamada.
        let manager = SyncManager(estaConectado: { true })
        manager.injetarSyncActor(SyncActor(modelContainer: container, api: api))

        // Primeira chamada, sem `forcar`: roda de verdade e fica parada no portão.
        let primeira = Task { await manager.sync() }

        // Espera o POST do ciclo chegar, com timeout para falhar em vez de
        // travar se o sync não rodar (sem rede/usuário).
        let guarda = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await portao.desistirDaChegada()
        }
        await portao.aguardarChegada()
        guarda.cancel()
        try #require(await portao.jaChegou, "o sync não chegou ao postCiclo (rede ou usuário ausente?)")

        // Segunda chamada enquanto a primeira está em voo: guardada, e o
        // `forcar` junta com OU.
        await manager.sync(forcar: true)

        await portao.liberar()
        await primeira.value

        // A rodada lembrada corre dentro do sync que estava no ar.
        for _ in 0..<200 {
            if !manager.isSyncing { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(manager.isSyncing == false)
        #expect(manager.pendentesRestantes == 0)
        // 1ª rodada: postCiclo + postDiasLote (gasto pulado pelo backoff);
        // 2ª (lembrada, forçada): postGasto.
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        #expect(api.gastos.count == 1)
        #expect(api.gastos.first?.titulo == "Almoço")

        let local = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        #expect(local.first?.syncStatus == .synced)
        #expect(local.first?.backendId == api.gastos.first?.id)
    }

    /// Troca o usuário global pelo usuário do teste (ver `UsuarioGlobalTests`).
    private func logarUsuarioDeTeste() -> UserModel? {
        let anterior = AuthService.shared.currentUser
        AuthService.shared.currentUser = UserModel(
            id: userId, nome: "Teste", username: "teste", email: "t@t.com"
        )
        return anterior
    }

    /// Sem conexão o sync sai sem rodar nenhuma etapa nem chamar a API, mas
    /// `pendentesRestantes` passa a refletir a fila local — a faixa
    /// "N alterações aguardando envio" do `MainView` aparece (e cresce)
    /// justamente quando há gastos novos esperando para subir.
    @Test func offlinePublicaOsPendentesSemChamarAAPI() async throws {
        let usuarioAnterior = logarUsuarioDeTeste()
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
        // O dia já subiu antes: só o ciclo e o gasto estão na fila (2).
        dia.backendId = 1
        dia.syncStatus = .synced
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        try ctx.save()

        let manager = SyncManager(estaConectado: { false })
        manager.injetarSyncActor(SyncActor(modelContainer: container, api: api))
        manager.pendentesRestantes = 9 // contagem velha: tem que ser sobrescrita

        await manager.sync()

        #expect(manager.pendentesRestantes == 2)
        #expect(api.chamadas.isEmpty)
        #expect(manager.isSyncing == false)
    }

    /// Offline e sem nada na fila: publica 0 (apagando uma contagem velha).
    @Test func offlineSemPendentesPublicaZero() async throws {
        let usuarioAnterior = logarUsuarioDeTeste()
        defer { AuthService.shared.currentUser = usuarioAnterior }

        let manager = SyncManager(estaConectado: { false })
        manager.injetarSyncActor(SyncActor(modelContainer: container, api: api))
        manager.pendentesRestantes = 9

        await manager.sync()

        #expect(manager.pendentesRestantes == 0)
        #expect(api.chamadas.isEmpty)
    }

    /// Offline e sem usuário logado: publica 0 — o que está na fila é de
    /// outro usuário e não entra na contagem.
    @Test func offlineSemUsuarioPublicaZero() async throws {
        let usuarioAnterior = AuthService.shared.currentUser
        AuthService.shared.currentUser = nil
        defer { AuthService.shared.currentUser = usuarioAnterior }

        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: "outro-usuario", valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        try ctx.save()

        let manager = SyncManager(estaConectado: { false })
        manager.injetarSyncActor(SyncActor(modelContainer: container, api: api))
        manager.pendentesRestantes = 9

        await manager.sync()

        #expect(manager.pendentesRestantes == 0)
        #expect(api.chamadas.isEmpty)
    }

    /// Online o caminho não muda: as etapas rodam, tudo sobe em cascata e
    /// `pendentesRestantes` zera.
    @Test func onlineSobeTudoEZeraOsPendentes() async throws {
        let usuarioAnterior = logarUsuarioDeTeste()
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
        try ctx.save()

        let manager = SyncManager(estaConectado: { true })
        manager.injetarSyncActor(SyncActor(modelContainer: container, api: api))
        manager.pendentesRestantes = 9

        await manager.sync()

        #expect(manager.pendentesRestantes == 0)
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
    }
}

}  // extension UsuarioGlobalTests
