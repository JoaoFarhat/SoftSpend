import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// T3 de `docs/revisao-sync-offline-ios.md`: a edição do ciclo não usa mais o
/// `PUT /dias/lote`, que apagava no servidor os dias (e os gastos deles) fora da
/// lista deste aparelho. Dia novo sobe pelo `syncDias` (`POST /dias/lote`) e dia
/// removido pelo `syncDeletions` (`DELETE /dias/{id}`).
@MainActor
struct EdicaoCicloSyncTests {
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

    /// Ciclo com `qtdDias` dias criados no aparelho e já sincronizados com o
    /// servidor falso. O log de chamadas é zerado ao final: o que a montagem
    /// enviou não conta nas verificações do teste.
    func subirViagem(qtdDias: Int) async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 100 * Decimal(qtdDias), gasto_total: 0,
            periodo: "01/09 - 0\(qtdDias)/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let inicio = Calendar.current.startOfDay(for: .now)
        for i in 0..<qtdDias {
            let dia = DiaSoftex(data: inicio.addingTimeInterval(TimeInterval(86400 * i)), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = ciclo
        }
        try ctx.save()

        #expect(await sync() == 0)
        try #require(api.dias.count == qtdDias)
        api.limparChamadas()
    }

    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    /// O ciclo local, lido num contexto dado (como o da tela).
    func cicloLocal(_ ctx: ModelContext) throws -> CicloSoftex {
        let ciclos = try ctx.fetch(FetchDescriptor<CicloSoftex>())
        return try #require(ciclos.first)
    }

    /// Os dias locais ordenados por data, num contexto novo.
    func lerDias() throws -> [DiaSoftex] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<DiaSoftex>(sortBy: [SortDescriptor(\.data)]))
    }

    // MARK: Testes

    /// R3: outro aparelho criou um dia (com gasto) que este não conhece. Editar
    /// só o título não pode chamar o lote nem apagar nada no servidor.
    @Test func editarSoOTituloNaoApagaDiaNemGasto() async throws {
        try await subirViagem(qtdDias: 3)

        // O que veio de outro aparelho: existe no servidor, não existe aqui.
        let cicloId = try #require(api.ciclos.first?.id)
        _ = try await api.postDiasLote(
            cicloId: cicloId,
            dias: [DiaLoteRequest(clientId: "dia-outro-aparelho", data: .now)]
        )
        let diaOutro = try #require(api.dias.first { $0.clientId == "dia-outro-aparelho" })
        _ = try await api.postGasto(request: GastoCreateRequest(
            client_id: "gasto-outro-aparelho", titulo: "Táxi", valor: 30,
            categoria: .TRANSPORTE, dia_id: diaOutro.id
        ))
        api.limparChamadas()

        // Como o `editCiclo` faz quando só o título muda.
        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        ciclo.titulo = "Goiânia, GO"
        ciclo.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.putCiclo])
        #expect(api.dias.count == 4)   // 3 deste aparelho + 1 do outro, intactos
        #expect(api.gastos.count == 1) // o gasto do outro aparelho sobreviveu
        #expect(api.ciclos.first?.titulo == "Goiânia, GO")

        let dias = try lerDias()
        #expect(dias.count == 3)
        #expect(dias.allSatisfy { $0.deletadoEm == nil && $0.syncStatus == .synced })
    }

    /// Estender o período cria dias locais `pending`; eles sobem pelo
    /// `syncDias` (`POST /dias/lote`), sem nenhuma chamada ao lote que apaga.
    @Test func estenderPeriodoSobeOsDiasNovos() async throws {
        try await subirViagem(qtdDias: 3)

        // Como o `editCiclo` faz ao incluir uma data na viagem.
        let ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let ultimoDia = try #require(ciclo.dias?.max { $0.data < $1.data })
        let novoDia = DiaSoftex(data: ultimoDia.data.addingTimeInterval(86400), saldo: ciclo.diaria)
        ctx.insert(novoDia)
        novoDia.ciclo = ciclo
        ciclo.periodo = "01/09 - 04/09"
        ciclo.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.putCiclo, .postDiasLote])
        #expect(api.dias.count == 4)
        #expect(api.dias.contains { $0.clientId == novoDia.clientId })

        let dias = try lerDias()
        #expect(dias.count == 4)
        #expect(dias.allSatisfy { $0.syncStatus == .synced && $0.backendId != nil })
    }

    /// Reduzir o período apaga só os dias removidos — por `DELETE`, não pelo
    /// lote — e os dias e gastos mantidos continuam no servidor.
    @Test func reduzirPeriodoApagaSoOsRemovidosPorDelete() async throws {
        try await subirViagem(qtdDias: 3)

        // Gastos no primeiro e no último dia, já sincronizados.
        var ctx = ModelContext(container)
        var dias = try ctx.fetch(FetchDescriptor<DiaSoftex>(sortBy: [SortDescriptor(\.data)]))
        let primeiroDia = try #require(dias.first)
        let ultimoDia = try #require(dias.last)
        ctx.insert(GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: primeiroDia))
        ctx.insert(GastosDia(valor: 40, titulo: "Jantar", categoria: .ALIMENTACAO, dia: ultimoDia))
        try ctx.save()
        #expect(await sync() == 0)
        try #require(api.gastos.count == 2)
        api.limparChamadas()

        // Como o `editCiclo` faz ao tirar uma data da viagem: dia e gastos dele
        // ganham `deletadoEm` e ficam `pending`.
        ctx = ModelContext(container)
        let ciclo = try cicloLocal(ctx)
        let diaRemovido = try #require(ciclo.dias?.max { $0.data < $1.data })
        diaRemovido.deletadoEm = .now
        diaRemovido.syncStatus = .pending
        for gasto in diaRemovido.gastos where gasto.deletadoEm == nil {
            gasto.deletadoEm = .now
            gasto.syncStatus = .pending
        }
        ciclo.periodo = "01/09 - 02/09"
        ciclo.syncStatus = .pending
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.chamadas == [.putCiclo, .deleteGasto, .deleteDia])
        #expect(api.dias.count == 2)
        #expect(api.gastos.count == 1)
        #expect(api.gastos.first?.titulo == "Almoço")

        dias = try lerDias()
        let vivos = dias.filter { $0.deletadoEm == nil }
        #expect(vivos.count == 2)
        #expect(dias.first { $0.deletadoEm != nil }?.syncStatus == .synced)
    }
}
