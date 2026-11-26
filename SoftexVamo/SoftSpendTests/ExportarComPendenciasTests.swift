import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// O relatório PDF/CSV é montado pelo servidor (`GET /ciclos/{id}/export`):
/// alterações que ainda não subiram — gasto feito sem internet, edição ou
/// exclusão que não foi enviada — ficariam fora dele sem aviso, ruim para
/// prestação de contas. O `exportarCiclo` força um sync com teto antes de
/// exportar e devolve `.pendencias(n)` quando sobram dias/gastos não
/// enviados; a FecharViagemView então pergunta "gerar assim mesmo"
/// (`aceitarPendencias: true`, que exporta direto).
@MainActor
struct ExportarComPendenciasTests {
    let container: ModelContainer
    let ctx: ModelContext
    let api = FakeAssinaturaAPI()

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    // MARK: - Apoio

    /// Assinatura carregada com (ou sem) acesso, como a `Fabrica` dos
    /// `BloqueiosAssinaturaTests`.
    func assinatura(temAcesso: Bool = true) async -> AssinaturaViewModel {
        api.estado = AssinaturaResponse(
            status: temAcesso ? "active" : "none",
            temAcesso: temAcesso, expiraEm: nil, produto: nil,
            appAccountToken: FakeAssinaturaAPI.token.uuidString
        )
        let vm = AssinaturaViewModel(
            loja: FakeLojaAssinatura(), api: api,
            usuarioLogado: { "usuario-1" }, sincronizar: {}
        )
        await vm.carregarEstado()
        return vm
    }

    /// Viagem toda no servidor (`backendId` 7, `.synced`) com um dia e um
    /// gasto também sincronizados.
    func viagemSincronizada() throws -> (CicloSoftex, DiaSoftex, GastosDia) {
        let c = CicloSoftex(
            userId: "usuario-1", valor_total: 600, gasto_total: 40,
            periodo: "01/09 - 03/09", diaria: 200, titulo: "Cuiabá, MT", dias: []
        )
        c.backendId = 7
        c.syncStatus = .synced
        ctx.insert(c)
        let d = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 200)
        d.backendId = 50
        d.syncStatus = .synced
        ctx.insert(d)
        d.ciclo = c
        let g = GastosDia(valor: 40, titulo: "Almoço", categoria: .ALIMENTACAO, dia: d)
        g.backendId = 9
        g.syncStatus = .synced
        ctx.insert(g)
        try ctx.save()
        return (c, d, g)
    }

    func viewModel(acesso: AssinaturaViewModel, ciclo: CicloSoftex) -> CiclosViewModel {
        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.assinatura = acesso
        vm.atualCiclo = ciclo
        return vm
    }

    /// Viagem toda enviada: exporta sem chamar o sync.
    @Test func viagemTodaEnviadaExportaSemSync() async throws {
        let (c, _, _) = try viagemSincronizada()
        let vm = viewModel(acesso: await assinatura(), ciclo: c)
        var syncs = 0, rede = 0
        vm.sincronizarAntesDeExportar = { syncs += 1 }
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1, 2, 3]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf)

        #expect(syncs == 0)
        #expect(rede == 1)
        guard case .arquivo(let url) = resultado else {
            Issue.record("esperava .arquivo, veio \(resultado)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    /// Gasto feito sem internet: o sync com teto o envia (`.synced`) e a
    /// exportação sai na mesma chamada.
    @Test func gastoPendenteEnviadoNoSyncExportaUmaVez() async throws {
        let (c, _, g) = try viagemSincronizada()
        g.backendId = nil
        g.syncStatus = .pending
        let vm = viewModel(acesso: await assinatura(), ciclo: c)
        var syncs = 0, rede = 0
        vm.sincronizarAntesDeExportar = {
            syncs += 1
            g.backendId = 40
            g.syncStatus = .synced
        }
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf)

        #expect(syncs == 1)
        #expect(rede == 1)
        guard case .arquivo(let url) = resultado else {
            Issue.record("esperava .arquivo, veio \(resultado)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
    }

    /// O sync rodou mas não resolveu: `.pendencias(1)` e o `exportarRemoto`
    /// nunca é chamado — o relatório incompleto não sai sem a pessoa saber.
    @Test func syncQueNaoResolveDevolvePendenciasSemExportar() async throws {
        let (c, _, g) = try viagemSincronizada()
        g.syncStatus = .pending // edição que não subiu
        let vm = viewModel(acesso: await assinatura(), ciclo: c)
        var syncs = 0, rede = 0
        vm.sincronizarAntesDeExportar = { syncs += 1 }
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf)

        #expect(resultado == .pendencias(1))
        #expect(syncs == 1)
        #expect(rede == 0)
    }

    /// Sync travado (rede ruim) não segura a exportação: passado o teto de
    /// 50 ms, devolve `.pendencias` — o sync segue sozinho em background,
    /// nunca é cancelado.
    @Test func syncTravadoDevolvePendenciasDepoisDoTeto() async throws {
        let (c, _, g) = try viagemSincronizada()
        g.syncStatus = .pending
        let vm = viewModel(acesso: await assinatura(), ciclo: c)
        vm.tetoSyncExportacao = .milliseconds(50)
        var syncTerminou = false, rede = 0
        vm.sincronizarAntesDeExportar = {
            try? await Task.sleep(for: .seconds(60))
            syncTerminou = true
        }
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf)

        // Sem medir o relógio: com os testes em paralelo, o simulador do CI
        // chegou a levar mais de 30 s só para voltar à MainActor (PR #164).
        // `!syncTerminou` já prova que a exportação não esperou os 60 s.
        #expect(resultado == .pendencias(1))
        #expect(!syncTerminou)
        #expect(rede == 0)
    }

    /// "Gerar assim mesmo": exporta direto, sem sync nem checagem — a
    /// pessoa já foi avisada das pendências.
    @Test func aceitarPendenciasExportaSemSync() async throws {
        let (c, _, g) = try viagemSincronizada()
        g.syncStatus = .pending
        let vm = viewModel(acesso: await assinatura(), ciclo: c)
        var syncs = 0, rede = 0
        vm.sincronizarAntesDeExportar = { syncs += 1 }
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1, 2, 3]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf, aceitarPendencias: true)

        #expect(syncs == 0)
        #expect(rede == 1)
        guard case .arquivo(let url) = resultado else {
            Issue.record("esperava .arquivo, veio \(resultado)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    /// Sem acesso: a porta da assinatura vem antes de tudo — `.bloqueado`,
    /// planos abertos, nem sync nem download.
    @Test func semAcessoDevolveBloqueadoSemChamarNada() async throws {
        let (c, _, g) = try viagemSincronizada()
        g.syncStatus = .pending
        let acesso = await assinatura(temAcesso: false)
        let vm = viewModel(acesso: acesso, ciclo: c)
        var syncs = 0, rede = 0
        vm.sincronizarAntesDeExportar = { syncs += 1 }
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf)

        #expect(resultado == .bloqueado)
        #expect(acesso.planosAbertos)
        #expect(syncs == 0)
        #expect(rede == 0)
    }
}
