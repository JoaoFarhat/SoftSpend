import Testing
import Foundation
import SwiftData
@testable import SoftSpend

// Em série com as outras suítes do usuário global: ver `UsuarioGlobalTests`.
extension UsuarioGlobalTests {

/// T6 de `docs/revisao-sync-offline-ios.md` (R6): o refresh do servidor não pode
/// criar um segundo gasto local para um lançamento que já está no aparelho
/// (casa também por `clientId`), e duplicatas que já ficaram são absorvidas.
@MainActor
struct GastoDuplicadoTests {
    let container: ModelContainer
    let ctx: ModelContext
    let userId: String

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        userId = AuthService.shared.currentUser?.id ?? ""
    }

    // MARK: Apoio

    struct Local {
        let ciclo: CicloSoftex
        let dia: DiaSoftex
    }

    /// Ciclo e dia já sincronizados (backendId 7 e 50), prontos para receber gastos.
    @discardableResult
    func subirViagem() -> Local {
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ciclo.backendId = 7
        ciclo.syncStatus = .synced
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        dia.backendId = 50
        dia.syncStatus = .synced
        ctx.insert(dia)
        dia.ciclo = ciclo
        return Local(ciclo: ciclo, dia: dia)
    }

    /// O dia do servidor, no formato da resposta de `GET /dias`.
    func diaDoServidor(_ dia: DiaSoftex, gastos: [GastosDiaResponse] = []) -> DiaSoftex {
        DiaSoftex(from: DiaSoftexResponse(
            id: dia.backendId, clientId: dia.clientId, data: dia.data,
            dataLocal: DiaDoCalendario.texto(de: dia.data), saldo: dia.saldo,
            gastos: gastos
        ))
    }

    func viewModel(_ local: Local) -> CiclosViewModel {
        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.modelContext = ctx
        vm.allCiclos = [local.ciclo]
        vm.atualCiclo = local.ciclo
        return vm
    }

    func gastosNoBanco() throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    // MARK: Testes

    /// Gasto criado no aparelho com o POST ainda em voo (sem `backendId`): quando o
    /// refresh traz o gasto que o servidor já criou com o mesmo `clientId`, o local
    /// só recebe o `backendId` — não entra uma segunda cópia (e o status pendente
    /// fica, como manda a T1).
    @Test func refreshComPostEmVooNaoDuplicaGasto() async throws {
        let local = subirViagem()
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        ctx.insert(gasto)  // pending, backendId nil — POST em voo
        try ctx.save()

        let servidor = [diaDoServidor(local.dia, gastos: [GastosDiaResponse(
            id: 5, clientId: gasto.clientId, dia_id: 50, valor: 25, titulo: "Almoço",
            categoria: .ALIMENTACAO, comprovante_url: nil,
            openFinanceStatus: nil, openFinanceMatch: nil
        )])]

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in servidor }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == gasto.id)
        #expect(gastos[0].backendId == 5)
        #expect(gastos[0].syncStatus == .pending)
    }

    /// Duplicata que já ficou no aparelho (dois registros com o mesmo `backendId`):
    /// fica o que tem comprovante local ainda não enviado e o outro sai do SwiftData.
    @Test func duplicataExistenteEhAbsorvidaESobraUmSo() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        ctx.insert(antigo)
        let novo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5
        novo.comprovanteDataCriptografado = Data([1, 2, 3])  // comprovante local pendente
        ctx.insert(novo)
        try ctx.save()

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(local.dia)] }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == novo.id)
        #expect(gastos[0].comprovanteDataCriptografado == Data([1, 2, 3]))
    }

    /// A cópia mais nova tem uma edição de valor ainda não enviada: é ela que
    /// fica — antes, a regra da mais antiga apagava a editada e o valor velho
    /// voltava.
    @Test func duplicataComEdicaoPendenteFicaAEditada() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        ctx.insert(antigo)
        let novo = GastosDia(valor: 30, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5  // pending: o PUT com o valor editado ainda não subiu
        ctx.insert(novo)
        try ctx.save()

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(local.dia)] }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == novo.id)
        #expect(gastos[0].valor == 30)
        #expect(gastos[0].syncStatus == .pending)
    }

    /// A cópia mais nova foi apagada pela pessoa e o DELETE ainda não subiu: é
    /// ela que fica (marcada), senão o gasto apagado reaparecia na lista.
    @Test func duplicataComExclusaoPendenteFicaAApagada() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        ctx.insert(antigo)
        let novo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5
        novo.deletadoEm = Date()  // exclusão pendente, como deixa o deleteGasto
        ctx.insert(novo)
        try ctx.save()

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(local.dia)] }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == novo.id)
        #expect(gastos[0].deletadoEm != nil)
    }

    /// A cópia com alteração local vence a da nota guardada — mas a nota não se
    /// perde: os bytes cifrados migram para a que fica antes do delete.
    @Test func duplicataEditadaHerdaNotaDaOutra() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        antigo.comprovanteDataCriptografado = Data([1, 2, 3])
        ctx.insert(antigo)
        let novo = GastosDia(valor: 30, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5  // pending: edição ainda não enviada
        ctx.insert(novo)
        try ctx.save()

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(local.dia)] }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == novo.id)
        #expect(gastos[0].valor == 30)
        #expect(gastos[0].comprovanteDataCriptografado == Data([1, 2, 3]))
    }

    /// A nota migrada vem com o `comprovanteMime` junto: sem ele, um PDF
    /// herdado era tratado como foto ("image/jpeg") na tela.
    @Test func duplicataEditadaHerdaNotaComMimeDaOutra() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        antigo.comprovanteDataCriptografado = Data([1, 2, 3])
        antigo.comprovanteMime = "application/pdf"
        ctx.insert(antigo)
        let novo = GastosDia(valor: 30, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5  // pending: edição ainda não enviada
        ctx.insert(novo)
        try ctx.save()

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(local.dia)] }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == novo.id)
        #expect(gastos[0].comprovanteDataCriptografado == Data([1, 2, 3]))
        #expect(gastos[0].comprovanteMime == "application/pdf")
    }

    /// A cópia que fica tem a remoção da nota ainda não enviada
    /// (`comprovanteParaRemover`): a nota da outra não migra, senão a nota
    /// tirada voltava e o sync a enviava de novo.
    @Test func duplicataComRemocaoPendenteNaoHerdaNotaDaOutra() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        antigo.comprovanteDataCriptografado = Data([1, 2, 3])
        ctx.insert(antigo)
        let novo = GastosDia(valor: 30, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5  // pending: a pessoa tirou a nota e a remoção não subiu
        novo.comprovanteParaRemover = true
        ctx.insert(novo)
        try ctx.save()

        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in [self.diaDoServidor(local.dia)] }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == novo.id)
        #expect(gastos[0].comprovanteDataCriptografado == nil)
        #expect(gastos[0].comprovanteParaRemover)
    }

    /// Sem comprovante pendente em nenhuma cópia, fica a mais antiga.
    @Test func duplicataSemComprovanteFicaAMaisAntiga() async throws {
        let local = subirViagem()
        let antigo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        antigo.backendId = 5
        antigo.syncStatus = .synced
        antigo.criadoEm = Date(timeIntervalSinceNow: -3600)
        ctx.insert(antigo)
        let novo = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: local.dia)
        novo.backendId = 5
        novo.syncStatus = .synced
        ctx.insert(novo)
        try ctx.save()

        // O gasto 5 continua no servidor: sem ele na resposta, a T5 apagaria as duas cópias.
        let servidor = [diaDoServidor(local.dia, gastos: [GastosDiaResponse(
            id: 5, clientId: antigo.clientId, dia_id: 50, valor: 25, titulo: "Almoço",
            categoria: .ALIMENTACAO, comprovante_url: nil,
            openFinanceStatus: nil, openFinanceMatch: nil
        )])]
        let vm = viewModel(local)
        await vm.carregarDiasDoServidor(cicloId: 7) { _, _ in servidor }

        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        #expect(gastos[0].id == antigo.id)
    }
}

}  // extension UsuarioGlobalTests
