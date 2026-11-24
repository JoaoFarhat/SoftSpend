import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Chave do Keychain inacessível — típico do sync em segundo plano com o
/// iPhone trancado (a chave é `WhenUnlockedThisDeviceOnly`). A nota pode
/// estar boa: o gasto fica `.pending`, sem contar tentativa e sem "nota não
/// abre" na tela (isso induziria "Descartar nota" numa nota válida), e
/// destrava sozinho quando o aparelho é destrancado.
@MainActor
struct ChaveInacessivelTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let cifrador = FakeCifrador()
    let userId = "usuario-teste"

    /// Bytes da nota: texto puro — o `FakeCifrador` não cifra de verdade.
    let nota = Data("nota".utf8)

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    func sync(forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api, cifrador: cifrador)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    /// Ciclo + dia + gasto com nota anexada, tudo criado offline.
    func criarViagemComNota() throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        let gasto = GastosDia(valor: 25, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia)
        gasto.comprovanteDataCriptografado = nota
        ctx.insert(gasto)
        try ctx.save()
    }

    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    /// Sync com o aparelho bloqueado: a viagem e o gasto sobem, a nota espera
    /// — `.pending`, sem tentativa e sem mensagem de falha — e nada é enviado.
    /// Ao destrancar, o `sync(forcar:)` sobe a nota e conclui, sem descarte.
    @Test func notaBoaAguardaDesbloqueioSemFalhar() async throws {
        try criarViagemComNota()
        cifrador.chaveInacessivel = true

        let restantes = await sync()

        #expect(restantes == 1)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let aguardando = try lerGasto()
        #expect(aguardando.backendId != nil)
        #expect(aguardando.syncStatus == .pending)
        #expect(aguardando.syncError == nil)
        #expect(aguardando.tentativas == 0)
        #expect(aguardando.proximaTentativaEm != nil)
        #expect(aguardando.comprovanteDataCriptografado == nota)
        #expect(EstadoEnvio.de(aguardando) == .aguardando)

        // Ainda bloqueado, nem o sync forçado vira falha — só espera de novo.
        api.limparChamadas()
        _ = await sync(forcar: true)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let aindaAguardando = try lerGasto()
        #expect(aindaAguardando.syncStatus == .pending)
        #expect(aindaAguardando.tentativas == 0)
        #expect(aindaAguardando.syncError == nil)

        // iPhone destrancado: a nota sobe na passada seguinte, sem descarte.
        cifrador.chaveInacessivel = false
        api.limparChamadas()
        let depois = await sync(forcar: true)

        #expect(depois == 0)
        #expect(api.chamadas.contains(.uploadComprovante))
        #expect(api.gastos.first?.comprovante == nota)
        let fim = try lerGasto()
        #expect(fim.syncStatus == .synced)
        #expect(fim.syncError == nil)
        #expect(fim.comprovanteDataCriptografado == nil)
        #expect(fim.comprovanteUrl != nil)
    }

    /// Remover a nota não precisa dos bytes nem da chave: mesmo com o
    /// aparelho bloqueado o DELETE sobe e a remoção conclui.
    @Test func remocaoNaoEsperaAChave() async throws {
        try criarViagemComNota()
        #expect(await sync() == 0)
        try #require(try lerGasto().syncStatus == .synced)

        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        gasto.comprovanteParaRemover = true
        gasto.syncStatus = .pending
        try ctx.save()
        api.limparChamadas()
        cifrador.chaveInacessivel = true

        let restantes = await sync()

        #expect(restantes == 0)
        #expect(api.chamadas.contains(.deleteComprovante))
        let fim = try lerGasto()
        #expect(fim.syncStatus == .synced)
        #expect(!fim.comprovanteParaRemover)
        #expect(fim.comprovanteUrl == nil)
        #expect(fim.syncError == nil)
    }
}
