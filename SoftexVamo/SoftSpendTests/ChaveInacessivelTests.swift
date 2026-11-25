import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Chave das notas indisponível — típico do sync em segundo plano com o
/// iPhone trancado (a chave é `WhenUnlockedThisDeviceOnly`). A nota pode
/// estar boa: o gasto fica `.pending`, sem contar tentativa e sem "nota não
/// abre" na tela (isso levaria a "Descartar nota" numa nota válida), nunca
/// vira `.synced` com a nota presa, e sobe quando o aparelho é destrancado.
///
/// A cifra é a de verdade (`ComprovanteCrypto(armazem:)`); só o Keychain é
/// trocado pelo `ArmazemDeChaveFalso`.
@MainActor
struct ChaveInacessivelTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let armazem = ArmazemDeChaveFalso(chave: ArmazemDeChaveFalso.chaveAleatoria())
    let userId = "usuario-teste"
    let nota = Data("nota fiscal do jantar".utf8)

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    var crypto: ComprovanteCrypto { ComprovanteCrypto(armazem: armazem) }

    func sync(forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api, crypto: crypto)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    /// Ciclo + dia + gasto, tudo criado offline; com `cifrada`, o gasto já
    /// nasce com a nota anexada.
    func criarViagem(cifrada: Data? = nil) throws {
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
        gasto.comprovanteDataCriptografado = cifrada
        ctx.insert(gasto)
        try ctx.save()
    }

    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    /// Sync com o aparelho bloqueado: a viagem e o gasto sobem, a nota espera
    /// — `.pending`, sem tentativa e sem mensagem de falha — e nada é enviado
    /// nem criado no armazém. Ao destrancar, o `sync(forcar:)` sobe a nota.
    @Test func notaBoaAguardaDesbloqueioSemFalhar() async throws {
        let cifrada = try crypto.criptografar(nota)
        try criarViagem(cifrada: cifrada)
        armazem.indisponivel = true

        let restantes = await sync()

        #expect(restantes == 1)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let aguardando = try lerGasto()
        #expect(aguardando.backendId != nil)
        #expect(aguardando.syncStatus == .pending)
        #expect(aguardando.syncError == nil)
        #expect(aguardando.tentativas == 0)
        #expect(aguardando.proximaTentativaEm != nil)
        #expect(aguardando.comprovanteDataCriptografado == cifrada)
        #expect(EstadoEnvio.de(aguardando) == .aguardando)
        #expect(armazem.adicionadas.isEmpty)

        // Ainda bloqueado, nem o sync forçado vira falha — só espera de novo.
        api.limparChamadas()
        _ = await sync(forcar: true)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let aindaAguardando = try lerGasto()
        #expect(aindaAguardando.syncStatus == .pending)
        #expect(aindaAguardando.tentativas == 0)
        #expect(aindaAguardando.syncError == nil)
        #expect(aindaAguardando.comprovanteDataCriptografado == cifrada)

        // iPhone destrancado: a nota sobe, sem descarte e sem chave nova.
        armazem.indisponivel = false
        api.limparChamadas()
        let depois = await sync(forcar: true)

        #expect(depois == 0)
        #expect(api.chamadas.filter { $0 == .uploadComprovante }.count == 1)
        #expect(api.gastos.first?.comprovante == nota)
        let fim = try lerGasto()
        #expect(fim.syncStatus == .synced)
        #expect(fim.syncError == nil)
        #expect(fim.comprovanteDataCriptografado == nil)
        #expect(fim.comprovanteUrl != nil)
        #expect(armazem.adicionadas.isEmpty)
    }

    /// Remover a nota não precisa dos bytes nem da chave: mesmo com o
    /// aparelho bloqueado o DELETE sobe. O gasto tem bytes guardados **e**
    /// remoção pendente (anexou outra nota depois de remover), então o teste
    /// falha se o ramo de "chave indisponível" passar na frente da remoção.
    /// A nota nova espera o desbloqueio e sobe depois.
    @Test func remocaoNaoEsperaAChave() async throws {
        try criarViagem(cifrada: try crypto.criptografar(Data("nota antiga".utf8)))
        #expect(await sync() == 0)
        try #require(try lerGasto().syncStatus == .synced)
        try #require(try lerGasto().comprovanteUrl != nil)

        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        let cifrada = try crypto.criptografar(nota)
        gasto.comprovanteDataCriptografado = cifrada
        gasto.comprovanteParaRemover = true
        gasto.syncStatus = .pending
        try ctx.save()
        api.limparChamadas()
        armazem.indisponivel = true

        _ = await sync()

        #expect(api.chamadas.contains(.deleteComprovante))
        #expect(!api.chamadas.contains(.uploadComprovante))
        let removido = try lerGasto()
        #expect(!removido.comprovanteParaRemover)
        #expect(removido.comprovanteUrl == nil)
        #expect(removido.comprovanteDataCriptografado == cifrada)
        #expect(removido.syncStatus == .pending)
        #expect(removido.syncError == nil)
        #expect(removido.tentativas == 0)

        // Ainda bloqueado: a nota nova só espera, sem falhar.
        api.limparChamadas()
        _ = await sync(forcar: true)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let aguardando = try lerGasto()
        #expect(aguardando.syncStatus == .pending)
        #expect(aguardando.syncError == nil)
        #expect(aguardando.tentativas == 0)
        #expect(aguardando.proximaTentativaEm != nil)

        armazem.indisponivel = false
        #expect(await sync(forcar: true) == 0)
        #expect(api.gastos.first?.comprovante == nota)
        let fim = try lerGasto()
        #expect(fim.syncStatus == .synced)
        #expect(fim.comprovanteDataCriptografado == nil)
        #expect(fim.comprovanteUrl != nil)
    }
}
