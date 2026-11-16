import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Os dias pendentes de uma viagem sobem num `POST /dias/lote` só (em partes
/// de `SyncActor.maxDiasPorLote`, 60): uma viagem de 30 dias criada sem
/// internet eram 30 pedidos seguidos — lento no 4G e perto do limite por
/// minuto do servidor. Cada dia da resposta casa pelo `client_id`, não pela
/// posição; o que não volta falha sozinho. 404 descarta os dias do lote.
@MainActor
struct DiasEmLoteTests {
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

    /// Ciclo com `dias` dias criados offline (nenhum com `backendId`), já salvos.
    func criarViagemOffline(dias: Int) throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 100 * Decimal(dias), gasto_total: 0,
            periodo: "01/09 - \(String(format: "%02d", dias))/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let inicio = Calendar.current.startOfDay(for: .now)
        for i in 0..<dias {
            let dia = DiaSoftex(data: inicio.addingTimeInterval(TimeInterval(86400 * i)), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = ciclo
        }
        try ctx.save()
    }

    /// Lê os dias locais num contexto novo, por data.
    func diasLocais() throws -> [DiaSoftex] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<DiaSoftex>(sortBy: [SortDescriptor(\.data)]))
    }

    func gastosLocais() throws -> [GastosDia] {
        try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
    }

    func cicloLocal() throws -> CicloSoftex {
        try #require(try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>()).first)
    }

    func sync() async -> Int {
        await SyncActor(modelContainer: container, api: api).sync(agora: .now, userId: userId)
    }

    /// Sync em background, para mexer no dia com a requisição parada no `Portao`.
    func iniciarSync() -> Task<Int, Never> {
        let syncActor = SyncActor(modelContainer: container, api: api)
        let usuario = userId
        return Task { await syncActor.sync(agora: .now, userId: usuario) }
    }

    // MARK: Testes

    /// Viagem offline de 10 dias: um único `postDiasLote` com os 10 e todos
    /// `.synced` com `backendId`.
    @Test func dezDiasSobemNumPedidoSo() async throws {
        try criarViagemOffline(dias: 10)

        #expect(await sync() == 0)

        #expect(api.chamadas == [.postCiclo, .postDiasLote])
        #expect(api.lotesDias.map(\.count) == [10])
        #expect(api.dias.count == 10)

        let dias = try diasLocais()
        #expect(dias.count == 10)
        let remotos = Dictionary(
            api.dias.compactMap { remoto -> (String, Int)? in
                remoto.clientId.map { ($0, remoto.id) }
            },
            uniquingKeysWith: { a, _ in a }
        )
        for dia in dias {
            #expect(dia.syncStatus == .synced)
            #expect(dia.backendId == remotos[dia.clientId])
        }
    }

    /// Acima de 60, em partes de 60: 70 dias viram duas chamadas (60 + 10).
    @Test func setentaDiasSobemEmDoisLotes() async throws {
        try criarViagemOffline(dias: 70)

        #expect(await sync() == 0)

        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postDiasLote])
        #expect(api.lotesDias.map(\.count) == [60, 10])
        #expect(api.dias.count == 70)

        let dias = try diasLocais()
        #expect(dias.count == 70)
        for dia in dias {
            #expect(dia.syncStatus == .synced)
            #expect(dia.backendId != nil)
        }
    }

    /// Um dia editado durante o envio fica `.pending` (sem tentativa nem
    /// backoff) e sobe de novo na passada seguinte; os outros ficam `.synced`.
    @Test func diaEditadoDuranteOEnvioFicaPending() async throws {
        try criarViagemOffline(dias: 5)
        let post1 = api.segurar(.postDiasLote)
        let tarefa = iniciarSync()
        await post1.aguardarChegada()

        // Como a tela faria: muda o dia num contexto próprio e salva.
        let edicao = ModelContext(container)
        let emVoo = try #require(try edicao.fetch(
            FetchDescriptor<DiaSoftex>(sortBy: [SortDescriptor(\.data)])).first)
        emVoo.data = emVoo.data.addingTimeInterval(86400 * 100)
        let editadoId = emVoo.id
        try edicao.save()

        let post2 = api.segurar(.postDiasLote)
        await post1.liberar()
        try #require(await post2.chegouAntes(doFimDe: tarefa), "o dia editado durante o envio não foi reenviado")

        // Estado intermediário: só o editado ficou pendente; já tem backendId.
        let meio = try diasLocais()
        for dia in meio where dia.id != editadoId {
            #expect(dia.syncStatus == .synced)
            #expect(dia.backendId != nil)
        }
        let aindaPendente = try #require(meio.first { $0.id == editadoId })
        #expect(aindaPendente.syncStatus == .pending)
        #expect(aindaPendente.tentativas == 0)
        #expect(aindaPendente.proximaTentativaEm == nil)
        #expect(aindaPendente.syncError == nil)
        #expect(aindaPendente.backendId != nil)

        await post2.liberar()
        #expect(await tarefa.value == 0)

        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postDiasLote])
        #expect(api.lotesDias.map(\.count) == [5, 1])
        #expect(api.dias.count == 5)
        for dia in try diasLocais() {
            #expect(dia.syncStatus == .synced)
        }
    }

    /// Resposta sem um dos dias enviados: só ele falha; os outros sobem.
    @Test func diaAusenteDaRespostaFalhaSozinho() async throws {
        try criarViagemOffline(dias: 5)
        let ausente = try #require(try diasLocais().dropFirst(2).first)
        api.omitirDaResposta(ausente.clientId)

        #expect(await sync() == 1)

        #expect(api.chamadas == [.postCiclo, .postDiasLote])
        #expect(api.dias.count == 5)

        let dias = try diasLocais()
        for dia in dias where dia.id != ausente.id {
            #expect(dia.syncStatus == .synced)
            #expect(dia.backendId != nil)
        }
        let falho = try #require(dias.first { $0.id == ausente.id })
        #expect(falho.syncStatus == .failed)
        #expect(falho.syncError == "Falha ao sincronizar dia")
        #expect(falho.tentativas == 1)
        #expect(falho.proximaTentativaEm != nil)
        #expect(falho.backendId == nil)
    }

    /// Erro que não é 404 nem 429 (500, timeout, 422 por um dia ruim): o
    /// pedido falhou para o lote inteiro — os dias do lote entram juntos no
    /// backoff (comportamento decidido: isolar o dia ruim pediria um pedido
    /// por dia de novo justamente quando o servidor já está mal). Com o erro
    /// resolvido, um sync forçado sobe o lote de uma vez.
    @Test func erroGenericoFalhaOLoteInteiro() async throws {
        try criarViagemOffline(dias: 5)
        api.falhar(.postDiasLote)  // erroSimulado: serverError 500

        #expect(await sync() == 5)
        #expect(api.chamadas == [.postCiclo, .postDiasLote])
        #expect(api.dias.isEmpty)

        for dia in try diasLocais() {
            #expect(dia.syncStatus == .failed)
            #expect(dia.tentativas == 1)
            #expect(dia.syncError != nil)
            #expect(dia.proximaTentativaEm != nil)
            #expect(dia.backendId == nil)
        }

        api.pararDeFalhar(.postDiasLote)
        #expect(await SyncActor(modelContainer: container, api: api).sync(
            agora: .now, userId: userId, forcar: true) == 0)
        #expect(api.lotesDias.map(\.count) == [5, 5])
        for dia in try diasLocais() {
            #expect(dia.syncStatus == .synced)
            #expect(dia.backendId != nil)
        }
    }

    /// 404 no lote (a viagem foi apagada em outro aparelho): os dias do lote
    /// são descartados com os gastos, que saem do `gasto_total`.
    @Test func erro404DescartaOsDiasDoLote() async throws {
        try criarViagemOffline(dias: 5)
        api.falhar(.postDiasLote, com: FakeSyncAPI.naoEncontrado)

        // Um gasto vivo num dos dias (como o addGasto faz: entra no total).
        let ctx = ModelContext(container)
        let diaComGasto = try #require(try ctx.fetch(FetchDescriptor<DiaSoftex>()).first)
        ctx.insert(GastosDia(valor: 40, titulo: "Hotel", categoria: .TRANSPORTE, dia: diaComGasto))
        let ciclo = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        ciclo.gasto_total = 40
        try ctx.save()

        #expect(await sync() == 0)
        #expect(api.chamadas == [.postCiclo, .postDiasLote])

        // Segundo sync (forçado): nada foi reenviado — o lote foi descartado.
        api.limparChamadas()
        #expect(await SyncActor(modelContainer: container, api: api).sync(
            agora: .now, userId: userId, forcar: true) == 0)
        #expect(api.chamadas.isEmpty)

        #expect(try diasLocais().isEmpty)
        #expect(try gastosLocais().isEmpty)
        #expect(try cicloLocal().gasto_total == 0)
        #expect(try cicloLocal().syncStatus == .synced)
    }
}
