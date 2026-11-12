import Testing
import Foundation
import SwiftData
@testable import SoftSpend

// Em série com as outras suítes do usuário global: ver `UsuarioGlobalTests`.
extension UsuarioGlobalTests {

/// T1 de `docs/revisao-sync-offline-ios.md`: o refresh do servidor (`salvarOuAtualizar*Local`)
/// não pode apagar uma edição ou exclusão que ainda não subiu.
///
/// Roteiro: a viagem sobe pela `FakeSyncAPI`; o "app" (um `ModelContext` novo, como o da tela)
/// altera algo sem sincronizar; chega um refresh com a versão do servidor; depois o `SyncActor`
/// roda e o servidor falso tem que terminar com a versão do usuário.
@MainActor
struct RefreshPendenteTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    /// O mesmo usuário que o `CiclosViewModel` usa para casar os ciclos.
    let userId: String

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        userId = AuthService.shared.currentUser?.id ?? ""
    }

    // MARK: Apoio

    struct Local {
        let ctx: ModelContext
        let ciclo: CicloSoftex
        let dia: DiaSoftex
        let gasto: GastosDia
    }

    /// Ciclo → dia → gasto (Almoço, R$ 25) criados e já sincronizados com o servidor falso.
    func subirViagem() async throws {
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

        #expect(await sync() == 0)
        try #require(api.gastos.count == 1)
    }

    /// Lê o banco num contexto novo (vê o que o `SyncActor` ou a tela salvaram).
    func lerLocal() throws -> Local {
        let ctx = ModelContext(container)
        let ciclos = try ctx.fetch(FetchDescriptor<CicloSoftex>())
        let dias = try ctx.fetch(FetchDescriptor<DiaSoftex>())
        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        // Exatamente um de cada: o refresh não pode ter criado cópia nem revivido nada.
        try #require(ciclos.count == 1 && dias.count == 1 && gastos.count == 1)
        return Local(ctx: ctx, ciclo: ciclos[0], dia: dias[0], gasto: gastos[0])
    }

    func sync() async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: true)
    }

    func viewModel(_ local: Local) -> CiclosViewModel {
        let vm = CiclosViewModel()
        vm.modelContext = local.ctx
        vm.allCiclos = [local.ciclo]
        vm.atualCiclo = local.ciclo
        return vm
    }

    /// O que o servidor falso tem agora, no formato da resposta de `GET /dias`.
    func diasDoServidor() -> [DiaSoftex] {
        let gastos = api.gastos
        return api.dias.map { d in
            DiaSoftex(from: DiaSoftexResponse(
                id: d.id, clientId: d.clientId, data: d.data, saldo: d.saldo,
                gastos: gastos.filter { $0.diaId == d.id }.map { g in
                    GastosDiaResponse(
                        id: g.id, clientId: g.clientId, dia_id: g.diaId, valor: g.valor, titulo: g.titulo,
                        categoria: g.categoria, comprovante_url: g.comprovanteUrl,
                        openFinanceStatus: nil, openFinanceMatch: nil
                    )
                }
            ))
        }
    }

    /// O ciclo do servidor falso, no formato da resposta de `GET /ciclos/resumo`.
    func cicloDoServidor(titulo: String? = nil) throws -> CicloSoftex {
        let c = try #require(api.ciclos.first)
        return CicloSoftex(from: CicloResponse(
            id: c.id, clientId: c.clientId, valor_total: c.valorTotal, gasto_total: 25,
            periodo: c.periodo, diaria: c.diaria, titulo: titulo ?? c.titulo, dias: nil
        ))
    }

    /// Refresh dos dias (e gastos) do ciclo aberto com a resposta dada.
    func refreshDias(_ local: Local, servidor: [DiaSoftex]) async throws {
        let cicloId = try #require(local.ciclo.backendId)
        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: cicloId) { _, _ in servidor }
    }

    // MARK: Gasto

    @Test func edicaoDeGastoPendenteSobreviveAoRefreshEDepoisSobe() async throws {
        try await subirViagem()
        let servidor = diasDoServidor()  // ainda com "Almoço", R$ 25
        var local = try lerLocal()
        local.gasto.titulo = "Jantar"
        local.gasto.valor = 40
        local.gasto.syncStatus = .pending
        try local.ctx.save()

        try await refreshDias(local, servidor: servidor)

        local = try lerLocal()
        #expect(local.gasto.titulo == "Jantar")
        #expect(local.gasto.valor == 40)
        #expect(local.gasto.syncStatus == .pending)

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.putGasto))
        #expect(api.gastos.first?.titulo == "Jantar")
        #expect(api.gastos.first?.valor == 40)
        #expect(try lerLocal().gasto.syncStatus == .synced)
    }

    @Test func exclusaoDeGastoPendenteSobreviveAoRefreshEOSyncEnvia() async throws {
        try await subirViagem()
        let servidor = diasDoServidor()  // o gasto ainda existe lá
        var local = try lerLocal()
        local.gasto.deletadoEm = .now
        local.gasto.syncStatus = .pending
        try local.ctx.save()

        try await refreshDias(local, servidor: servidor)

        local = try lerLocal()  // exige um único gasto: não voltou como gasto novo
        #expect(local.gasto.deletadoEm != nil)
        #expect(local.gasto.syncStatus == .pending)

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.deleteGasto))
        #expect(api.gastos.isEmpty)
    }

    // MARK: Dia

    @Test func exclusaoDeDiaPendenteSobreviveAoRefreshEOSyncEnvia() async throws {
        try await subirViagem()
        let servidor = diasDoServidor()
        var local = try lerLocal()
        // Como o `editCiclo` faz ao tirar uma data da viagem.
        local.dia.deletadoEm = .now
        local.dia.syncStatus = .pending
        local.gasto.deletadoEm = .now
        local.gasto.syncStatus = .pending
        try local.ctx.save()

        try await refreshDias(local, servidor: servidor)

        local = try lerLocal()
        #expect(local.dia.deletadoEm != nil)
        #expect(local.dia.syncStatus == .pending)
        #expect(local.gasto.deletadoEm != nil)

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.deleteDia))
        #expect(api.dias.isEmpty)
        #expect(api.gastos.isEmpty)
    }

    /// Dia apagado no aparelho antes de a resposta do POST chegar (sem `backendId` local):
    /// o refresh casa pelo `clientId`, preenche o `backendId` e o dia não volta.
    @Test func diaApagadoSemBackendIdNaoReviveERecebeOId() async throws {
        try await subirViagem()
        let servidor = diasDoServidor()
        let idNoServidor = try #require(api.dias.first?.id)
        var local = try lerLocal()
        local.dia.backendId = nil
        local.dia.deletadoEm = .now
        local.dia.syncStatus = .pending
        local.gasto.deletadoEm = .now
        local.gasto.syncStatus = .pending
        try local.ctx.save()

        try await refreshDias(local, servidor: servidor)

        local = try lerLocal()  // exige um único dia
        #expect(local.dia.backendId == idNoServidor)
        #expect(local.dia.deletadoEm != nil)
        #expect(local.dia.syncStatus == .pending)

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.deleteDia))
        #expect(api.dias.isEmpty)
    }

    // MARK: Ciclo

    @Test func edicaoDeCicloPendenteSobreviveAoRefreshEDepoisSobe() async throws {
        try await subirViagem()
        let servidor = try cicloDoServidor()  // ainda "Cuiabá, MT"
        var local = try lerLocal()
        local.ciclo.titulo = "Goiânia, GO"
        local.ciclo.syncStatus = .pending
        try local.ctx.save()

        let vm = viewModel(local)
        vm.salvarOuAtualizarCicloLocal(servidor)
        try local.ctx.save()

        local = try lerLocal()  // exige um único ciclo
        #expect(local.ciclo.titulo == "Goiânia, GO")
        #expect(local.ciclo.syncStatus == .pending)

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.putCiclo))
        #expect(api.ciclos.first?.titulo == "Goiânia, GO")
        #expect(try lerLocal().ciclo.syncStatus == .synced)
    }

    @Test func exclusaoDeCicloPendenteSobreviveAoRefreshEOSyncEnvia() async throws {
        try await subirViagem()
        let servidor = try cicloDoServidor()
        var local = try lerLocal()
        local.ciclo.deletadoEm = .now
        local.ciclo.syncStatus = .pending
        try local.ctx.save()

        let vm = viewModel(local)
        vm.salvarOuAtualizarCicloLocal(servidor)
        try local.ctx.save()

        local = try lerLocal()
        #expect(local.ciclo.deletadoEm != nil)
        #expect(local.ciclo.syncStatus == .pending)

        #expect(await sync() == 0)

        #expect(api.chamadas.contains(.deleteCiclo))
        #expect(api.ciclos.isEmpty)
    }

    /// Ciclo criado no aparelho cujo POST foi processado mas a resposta se perdeu: o refresh
    /// só preenche o `backendId` (casando pelo `clientId`) e mantém os campos e o status locais.
    @Test func cicloPendenteSemBackendIdSoRecebeOId() throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Goiânia, GO", dias: []
        )
        ctx.insert(ciclo)
        try ctx.save()
        let servidor = CicloSoftex(from: CicloResponse(
            id: 99, clientId: ciclo.clientId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: nil
        ))
        let vm = CiclosViewModel()
        vm.modelContext = ctx

        let resultado = vm.salvarOuAtualizarCicloLocal(servidor)

        #expect(resultado === ciclo)
        #expect(ciclo.backendId == 99)
        #expect(ciclo.titulo == "Goiânia, GO")
        #expect(ciclo.syncStatus == .pending)
        #expect(try ctx.fetch(FetchDescriptor<CicloSoftex>()).count == 1)
    }

    // MARK: Registro já sincronizado

    /// Sem nada pendente, a versão do servidor (editada em outro aparelho) continua entrando.
    @Test func registroSincronizadoContinuaSendoAtualizado() async throws {
        try await subirViagem()
        var local = try lerLocal()
        let diaServidor = try #require(api.dias.first)
        let gastoServidor = try #require(api.gastos.first)
        let servidor = [DiaSoftex(from: DiaSoftexResponse(
            id: diaServidor.id, clientId: diaServidor.clientId, data: diaServidor.data, saldo: 70,
            gastos: [GastosDiaResponse(
                id: gastoServidor.id, clientId: gastoServidor.clientId, dia_id: diaServidor.id,
                valor: 30, titulo: "Almoço e café", categoria: .ALIMENTACAO, comprovante_url: nil,
                openFinanceStatus: nil, openFinanceMatch: nil
            )]
        ))]

        try await refreshDias(local, servidor: servidor)
        let vm = viewModel(local)
        vm.salvarOuAtualizarCicloLocal(try cicloDoServidor(titulo: "Cuiabá e Chapada, MT"))
        try local.ctx.save()

        local = try lerLocal()  // exige um de cada: atualizou, não duplicou
        #expect(local.gasto.titulo == "Almoço e café")
        #expect(local.gasto.valor == 30)
        #expect(local.gasto.syncStatus == .synced)
        #expect(local.dia.saldo == 70)
        #expect(local.dia.syncStatus == .synced)
        #expect(local.ciclo.titulo == "Cuiabá e Chapada, MT")
        #expect(local.ciclo.syncStatus == .synced)
    }
}

}  // extension UsuarioGlobalTests
