import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T2 de `docs/revisao-sync-offline-ios.md`: o usuário muda o item enquanto a
/// requisição dele está em voo.
///
/// Roteiro de cada teste, com a `FakeSyncAPI` segurando as respostas:
/// 1. o sync chega ao servidor e fica parado no portão;
/// 2. o teste faz o papel da tela: muda o item num contexto próprio e salva;
/// 3. segura a próxima chamada e libera a primeira;
/// 4. quando a próxima chamada chega, a resposta da primeira já foi gravada:
///    o item tem de estar `.pending` (não `.synced`), sem backoff;
/// 5. libera a segunda: na mesma chamada de `sync()` o servidor fica com o valor novo.
@MainActor
struct MudancaDuranteEnvioTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    // MARK: Apoio

    /// Ciclo → dia → gasto criados offline (nenhum com `backendId`), já salvos.
    func criarViagemOffline() throws {
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
    }

    /// Faz o papel da tela (`editGasto`, `deleteGasto`, anexar nota): muda e salva.
    func editarGasto(_ mudar: (GastosDia) -> Void) throws {
        let ctx = ModelContext(container)
        let gasto = try #require(try ctx.fetch(FetchDescriptor<GastosDia>()).first)
        mudar(gasto)
        gasto.syncStatus = .pending
        gasto.syncError = nil
        try ctx.save()
    }

    /// Faz o papel do `editCiclo`.
    func editarCiclo(_ mudar: (CicloSoftex) -> Void) throws {
        let ctx = ModelContext(container)
        let ciclo = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        mudar(ciclo)
        ciclo.syncStatus = .pending
        ciclo.syncError = nil
        try ctx.save()
    }

    /// Lê num contexto novo (vê o que o `SyncActor` salvou).
    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    func lerCiclo() throws -> CicloSoftex {
        let ciclos = try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>())
        try #require(ciclos.count == 1)
        return ciclos[0]
    }

    func sync() async -> Int {
        await SyncActor(modelContainer: container, api: api).sync(agora: .now, userId: userId)
    }

    func iniciarSync() -> Task<Int, Never> {
        let syncActor = SyncActor(modelContainer: container, api: api)
        let usuario = userId
        return Task { await syncActor.sync(agora: .now, userId: usuario) }
    }

    /// Item que mudou durante o envio: `.pending`, sem tentativa nem backoff.
    func esperarPendenteSemBackoff(_ item: any Syncavel) {
        #expect(item.syncStatus == .pending)
        #expect(item.tentativas == 0)
        #expect(item.proximaTentativaEm == nil)
        #expect(item.syncError == nil)
    }

    // MARK: Testes

    /// Editar durante o POST: o `backendId` fica gravado (o POST não se repete)
    /// e a edição sobe num PUT logo em seguida.
    @Test func editarDuranteOPostSobeOValorNovo() async throws {
        try criarViagemOffline()
        let post = api.segurar(.postGasto)
        let tarefa = iniciarSync()
        await post.aguardarChegada()

        try editarGasto {
            $0.titulo = "Jantar"
            $0.valor = 40
        }
        let put = api.segurar(.putGasto)
        await post.liberar()
        try #require(await put.chegouAntes(doFimDe: tarefa), "a edição feita durante o POST não foi enviada")

        let meio = try lerGasto()
        esperarPendenteSemBackoff(meio)
        #expect(meio.backendId == api.gastos.first?.id)
        #expect(meio.titulo == "Jantar")
        #expect(api.gastos.first?.titulo == "Almoço")

        await put.liberar()
        #expect(await tarefa.value == 0)

        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto, .putGasto])
        #expect(api.gastos.count == 1)
        #expect(api.gastos.first?.titulo == "Jantar")
        #expect(api.gastos.first?.valor == 40)
        #expect(try lerGasto().syncStatus == .synced)
    }

    /// Editar de novo durante o PUT: a segunda edição sobe num segundo PUT.
    @Test func editarDuranteOPutSobeOValorNovo() async throws {
        try criarViagemOffline()
        #expect(await sync() == 0)

        try editarGasto { $0.titulo = "Almoço executivo" }
        let put1 = api.segurar(.putGasto)
        let tarefa = iniciarSync()
        await put1.aguardarChegada()

        try editarGasto {
            $0.titulo = "Almoço com cliente"
            $0.categoria = .OUTROS
        }
        let put2 = api.segurar(.putGasto)
        await put1.liberar()
        try #require(await put2.chegouAntes(doFimDe: tarefa), "a edição feita durante o PUT não foi enviada")

        esperarPendenteSemBackoff(try lerGasto())
        #expect(api.gastos.first?.titulo == "Almoço executivo")

        await put2.liberar()
        #expect(await tarefa.value == 0)

        #expect(api.chamadas.filter { $0 == .putGasto }.count == 2)
        #expect(api.gastos.first?.titulo == "Almoço com cliente")
        #expect(api.gastos.first?.categoria == .OUTROS)
        #expect(try lerGasto().syncStatus == .synced)
    }

    /// Apagar durante o POST: o gasto recebe o `backendId` e o delete é enviado;
    /// o servidor termina sem o gasto.
    @Test func apagarDuranteOPostApagaNoServidor() async throws {
        try criarViagemOffline()
        let post = api.segurar(.postGasto)
        let tarefa = iniciarSync()
        await post.aguardarChegada()

        try editarGasto { $0.deletadoEm = .now }
        let delete = api.segurar(.deleteGasto)
        await post.liberar()
        try #require(await delete.chegouAntes(doFimDe: tarefa), "o delete feito durante o POST não foi enviado")

        let meio = try lerGasto()
        esperarPendenteSemBackoff(meio)
        #expect(meio.deletadoEm != nil)
        #expect(meio.backendId != nil)
        #expect(meio.backendId == api.gastos.first?.id)

        await delete.liberar()
        _ = await tarefa.value

        #expect(api.gastos.isEmpty)
        #expect(api.chamadas.last == .deleteGasto)
        let fim = try lerGasto()
        #expect(fim.deletadoEm != nil)
        #expect(fim.syncStatus == .synced)
    }

    /// Anexar outra nota durante o upload: a nova não é descartada e sobe em seguida.
    @Test func anexarComprovanteNovoDuranteOUploadSobeONovo() async throws {
        try criarViagemOffline()
        #expect(await sync() == 0)

        let notaA = Data("nota fiscal A".utf8)
        let notaB = Data("nota fiscal B".utf8)
        try editarGasto { $0.comprovanteData = notaA }
        try #require(try lerGasto().comprovanteData == notaA, "a nota não foi cifrada (Keychain do simulador)")

        let upload1 = api.segurar(.uploadComprovante)
        let tarefa = iniciarSync()
        await upload1.aguardarChegada()

        try editarGasto { $0.comprovanteData = notaB }
        let upload2 = api.segurar(.uploadComprovante)
        await upload1.liberar()
        try #require(await upload2.chegouAntes(doFimDe: tarefa), "a nota anexada durante o upload não foi enviada")

        let meio = try lerGasto()
        esperarPendenteSemBackoff(meio)
        #expect(meio.comprovanteData == notaB)
        #expect(meio.comprovanteUrl != nil)
        #expect(api.gastos.first?.comprovante == notaA)

        await upload2.liberar()
        #expect(await tarefa.value == 0)

        #expect(api.gastos.first?.comprovante == notaB)
        let fim = try lerGasto()
        #expect(fim.comprovanteDataCriptografado == nil)
        #expect(fim.comprovanteUrl != nil)
        #expect(fim.syncStatus == .synced)
    }

    /// Editar o ciclo durante o PUT do ciclo: antes, o `.synced` era incondicional.
    @Test func editarCicloDuranteOPutSobeOValorNovo() async throws {
        try criarViagemOffline()
        #expect(await sync() == 0)

        try editarCiclo { $0.titulo = "Cuiabá e Chapada" }
        let put1 = api.segurar(.putCiclo)
        let tarefa = iniciarSync()
        await put1.aguardarChegada()

        try editarCiclo { $0.titulo = "Chapada dos Guimarães" }
        let put2 = api.segurar(.putCiclo)
        await put1.liberar()
        try #require(await put2.chegouAntes(doFimDe: tarefa), "a edição feita durante o PUT do ciclo não foi enviada")

        let meio = try lerCiclo()
        esperarPendenteSemBackoff(meio)
        #expect(meio.titulo == "Chapada dos Guimarães")
        #expect(api.ciclos.first?.titulo == "Cuiabá e Chapada")

        await put2.liberar()
        #expect(await tarefa.value == 0)

        #expect(api.ciclos.first?.titulo == "Chapada dos Guimarães")
        #expect(try lerCiclo().syncStatus == .synced)
    }

    /// Sem mudança durante o envio, nada muda: uma passada, tudo `.synced`.
    @Test func semMudancaNaoHaPassadaExtra() async throws {
        try criarViagemOffline()
        #expect(await sync() == 0)
        try editarGasto { $0.titulo = "Almoço executivo" }

        #expect(await sync() == 0)

        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto, .putGasto])
        #expect(try lerGasto().syncStatus == .synced)
    }
}
