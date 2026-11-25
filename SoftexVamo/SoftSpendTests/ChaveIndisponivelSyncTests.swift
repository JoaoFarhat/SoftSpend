import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Nota anexada a um gasto que já subiu, com a chave das notas fora do ar:
/// o gasto não pode virar `.synced` sem a nota subir. A decisão do
/// `concluirGasto` olha o campo cifrado, sem decifrar. A espera pelo
/// desbloqueio e a remoção com a chave fora estão em `ChaveInacessivelTests`.
@MainActor
struct ChaveIndisponivelSyncTests {
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

    func sync(crypto: ComprovanteCrypto? = nil, forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api, crypto: crypto ?? self.crypto)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    /// Viagem com um gasto já sincronizado (tem `backendId` no servidor).
    func criarGastoSincronizado() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        ctx.insert(GastosDia(valor: 25, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()
        #expect(await sync() == 0)
        try #require(try lerGasto().syncStatus == .synced)
    }

    /// Faz o papel da tela ao anexar a nota (cifrada com a chave do armazém).
    func anexarNota() throws -> Data {
        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        let cifrada = try crypto.criptografar(nota)
        gasto.comprovanteDataCriptografado = cifrada
        gasto.syncStatus = .pending
        gasto.syncError = nil
        try ctx.save()
        return cifrada
    }

    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    /// iPhone trancado: o PUT do gasto sobe, mas ele fica `.pending` (sem
    /// falha, sem tentativa) com a nota guardada; destrancou, a nota sobe.
    @Test func chaveIndisponivelNaoConcluiOGasto() async throws {
        try await criarGastoSincronizado()
        let cifrada = try anexarNota()
        armazem.indisponivel = true

        #expect(await sync() == 1)

        let aguardando = try lerGasto()
        #expect(aguardando.syncStatus == .pending)
        #expect(aguardando.syncError == nil)
        #expect(aguardando.tentativas == 0)
        #expect(aguardando.comprovanteDataCriptografado == cifrada)
        #expect(aguardando.comprovanteUrl == nil)
        #expect(!api.chamadas.contains(.uploadComprovante))
        #expect(api.gastos.first?.comprovante == nil)
        #expect(armazem.adicionadas.isEmpty)

        armazem.indisponivel = false
        #expect(await sync(forcar: true) == 0)

        #expect(api.chamadas.filter { $0 == .uploadComprovante }.count == 1)
        #expect(api.gastos.first?.comprovante == nota)
        let fim = try lerGasto()
        #expect(fim.syncStatus == .synced)
        #expect(fim.comprovanteDataCriptografado == nil)
        #expect(fim.comprovanteUrl != nil)
        #expect(armazem.adicionadas.isEmpty)
    }

    /// Chave guardada com tamanho errado não é "iPhone trancado": não volta
    /// sozinha. Falha com o motivo e backoff, bytes intactos, sem chave nova.
    @Test func chaveInvalidaMarcaFalha() async throws {
        try await criarGastoSincronizado()
        let cifrada = try anexarNota()
        let quebrado = ArmazemDeChaveFalso(chave: Data([1, 2, 3]))

        _ = await sync(crypto: ComprovanteCrypto(armazem: quebrado))

        let falhou = try lerGasto()
        #expect(falhou.syncStatus == .failed)
        #expect(falhou.tentativas == 1)
        #expect(falhou.syncError == ComprovanteCryptoError.invalidKeySize.errorDescription)
        #expect(falhou.comprovanteDataCriptografado == cifrada)
        #expect(!api.chamadas.contains(.uploadComprovante))
        #expect(quebrado.adicionadas.isEmpty)
    }

    /// Bytes que não abrem com a chave atual: nada sobe, e o gasto fica `.failed`
    /// com `erroNotaNaoAbre` (a saída é o "Descartar nota", ver
    /// `DescartarNotaIlegivelTests`), em vez de concluir com a nota presa.
    @Test func bytesIlegiveisFalhamComMotivoSemUpload() async throws {
        try await criarGastoSincronizado()
        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        gasto.comprovanteDataCriptografado = Data([0x01, 0x02, 0x03])
        gasto.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 1)

        #expect(!api.chamadas.contains(.uploadComprovante))
        let falhou = try lerGasto()
        #expect(falhou.syncStatus == .failed)
        #expect(falhou.syncError == SyncActor.erroNotaNaoAbre)
    }
}
