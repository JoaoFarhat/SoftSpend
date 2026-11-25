import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Nota guardada no aparelho que a chave atual não abre (cifrada por outra
/// chave ou corrompida): o envio falha com o motivo na tela
/// (`SyncActor.erroNotaNaoAbre`) e backoff — em vez de insistir a cada
/// passada sem registro — e o detalhe do gasto oferece "Descartar nota"
/// (`CiclosViewModel.removerComprovante`), que limpa os bytes e destrava o
/// gasto na passada seguinte.
@MainActor
struct DescartarNotaIlegivelTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"
    /// Chave em memória, como nos outros testes da cifra: com o Keychain de verdade do
    /// simulador, uma resposta diferente de "achou" ou "não existe" vira "chave
    /// indisponível" (desde o `ArmazemDeChave`) e o teste deixava de exercitar os bytes
    /// que não abrem — no CI os quatro testes da nota ilegível falhavam assim.
    let crypto = ComprovanteCrypto(armazem: ArmazemDeChaveFalso(chave: ArmazemDeChaveFalso.chaveAleatoria()))

    /// Bytes que nenhuma chave abre.
    let ilegiveis = Data([0x01, 0x02, 0x03])

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    func sync(forcar: Bool = false) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api, crypto: crypto)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    /// Ciclo + dia + gasto criados offline e já salvos, com a nota ilegível
    /// anexada ao gasto (bytes gravados direto, sem passar pela cifra).
    func criarViagemComNotaIlegivel() throws {
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
        gasto.comprovanteDataCriptografado = ilegiveis
        ctx.insert(gasto)
        try ctx.save()
    }

    /// Viagem com o gasto já sincronizado (tem `backendId` no servidor); a
    /// nota ilegível é anexada depois, como uma gravação de chave antiga.
    func subirViagemComNotaIlegivel() async throws {
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
        let ctx2 = ModelContext(container)
        let gasto = try #require(try ctx2.fetch(FetchDescriptor<GastosDia>()).first)
        gasto.comprovanteDataCriptografado = ilegiveis
        gasto.syncStatus = .pending
        try ctx2.save()
        api.limparChamadas()
    }

    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    /// O que o botão "Descartar nota" da tela chama.
    func descartarNota(_ gastoId: UUID) async throws {
        let vm = CiclosViewModel(estaConectado: { false })
        vm.modelContext = ModelContext(container)
        try await vm.removerComprovante(gastoId: gastoId)
    }

    /// Bytes que a chave atual não abre num gasto já no servidor: nada sobe,
    /// o gasto fica `.failed` com o motivo na tela e backoff — e descartar a
    /// nota limpa os bytes e destrava: `.synced` na passada seguinte.
    @Test func descartarNotaIlegivelDestrava() async throws {
        try await subirViagemComNotaIlegivel()

        let restantes = await sync()

        #expect(restantes == 1)
        #expect(!api.chamadas.contains(.uploadComprovante))
        let falhou = try lerGasto()
        #expect(falhou.syncStatus == .failed)
        #expect(falhou.syncError == SyncActor.erroNotaNaoAbre)
        #expect(falhou.tentativas == 1)
        #expect(falhou.proximaTentativaEm != nil)
        // Os bytes ficam: a nota pode voltar a abrir — e há o "Descartar nota".
        #expect(falhou.comprovanteDataCriptografado == ilegiveis)
        #expect(EstadoEnvio.de(falhou) == .falhou(SyncActor.erroNotaNaoAbre))

        // Backoff: sem forçar, a passada seguinte não repete.
        api.limparChamadas()
        _ = await sync()
        #expect(api.chamadas.isEmpty)
        #expect(try lerGasto().tentativas == 1)

        try await descartarNota(falhou.id)
        let descartado = try lerGasto()
        #expect(descartado.comprovanteDataCriptografado == nil)
        #expect(descartado.comprovanteParaRemover)
        #expect(descartado.syncStatus == .pending)

        // O `removerComprovante` dispara `sync(forcar: true)` no app — o
        // backoff da falha não segura a ação do usuário.
        api.limparChamadas()
        let depois = await sync(forcar: true)

        #expect(depois == 0)
        #expect(api.chamadas.contains(.deleteComprovante))
        let fim = try lerGasto()
        #expect(fim.syncStatus == .synced)
        #expect(fim.syncError == nil)
        #expect(!fim.comprovanteParaRemover)
        #expect(fim.comprovanteUrl == nil)
    }

    /// Gasto que nunca subiu (sem `backendId`) com nota ilegível: descartar
    /// destrava do mesmo jeito — o gasto sobe e a remoção da nota que nunca
    /// chegou lá conclui sem derrubar o envio.
    @Test func descartarNotaIlegivelDeGastoNovoDestrava() async throws {
        try criarViagemComNotaIlegivel()

        // O gasto inteiro falha pela nota: a viagem e o dia sobem, o gasto
        // sobe (POST vale, a nota é que não sai) e fica `.failed` pela nota.
        let restantes = await sync()
        #expect(restantes == 1)
        let falhou = try lerGasto()
        #expect(falhou.backendId != nil)
        #expect(falhou.syncStatus == .failed)
        #expect(falhou.syncError == SyncActor.erroNotaNaoAbre)

        try await descartarNota(falhou.id)
        api.limparChamadas()
        let depois = await sync(forcar: true)

        #expect(depois == 0)
        #expect(api.chamadas.contains(.deleteComprovante))
        #expect(try lerGasto().syncStatus == .synced)
    }

    /// Remoção pedida com a nota ilegível ainda guardada no aparelho: o
    /// DELETE sai sem tentar ler os bytes — `comprovanteParaRemover` é
    /// checado antes do ramo "nota não abre" do `sincronizarComprovante`.
    /// O estado é montado à mão (o `removerComprovante` da tela limpa os
    /// bytes junto com o pedido) justamente para prender a ordem dos
    /// ramos: se a checagem da nota passar na frente, a remoção esperaria
    /// a nota abrir — que nunca acontece — e este teste falha. Os bytes
    /// ilegíveis que sobram só viram `.failed` na passada seguinte.
    @Test func remocaoNaoEsperaANotaAbrir() async throws {
        try await subirViagemComNotaIlegivel()

        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        gasto.comprovanteParaRemover = true
        try ctx.save()

        let restantes = await sync()

        // A remoção subiu mesmo com a nota ilegível guardada: a nota não
        // precisa abrir para a nota ser desfeita no servidor.
        #expect(api.chamadas.contains(.deleteComprovante))
        #expect(!api.chamadas.contains(.uploadComprovante))
        let meio = try lerGasto()
        #expect(!meio.comprovanteParaRemover)
        #expect(meio.comprovanteUrl == nil)
        // Os bytes ilegíveis ficam no aparelho e o gasto segue `.pending`,
        // sem erro — o ramo "nota não abre" ainda não rodou.
        #expect(restantes == 1)
        #expect(meio.syncStatus == .pending)
        #expect(meio.syncError == nil)
        #expect(meio.comprovanteDataCriptografado == ilegiveis)

        // Na passada seguinte os bytes que sobraram caem no caso conhecido
        // da suíte: `.failed` com "nota não abre" e backoff — a saída é o
        // "Descartar nota" da tela, que limpa os bytes.
        api.limparChamadas()
        let depois = await sync()

        #expect(depois == 1)
        #expect(!api.chamadas.contains(.uploadComprovante))
        #expect(!api.chamadas.contains(.deleteComprovante))
        let fim = try lerGasto()
        #expect(fim.syncStatus == .failed)
        #expect(fim.syncError == SyncActor.erroNotaNaoAbre)
        #expect(fim.comprovanteDataCriptografado == ilegiveis)
        #expect(EstadoEnvio.de(fim) == .falhou(SyncActor.erroNotaNaoAbre))
    }
}
