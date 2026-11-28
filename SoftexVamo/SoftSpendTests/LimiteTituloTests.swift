import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Título com mais de 100 caracteres não trava mais o envio: o servidor aceita
/// no máximo 100 (`max_length` nos DTOs) e respondia 422, que o `SyncActor`
/// retentava com backoff para sempre. Agora o app corta na entrada
/// (`CiclosViewModel`), nos campos e — para itens já gravados no aparelho —
/// no corpo do POST/PUT montado pelo `SyncActor` (o model não muda).
@MainActor
struct LimiteTituloTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    static let t150 = String(repeating: "a", count: 150)
    static let t100 = String(repeating: "b", count: 100)

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    func sync(forcar: Bool = true) async -> Int {
        let syncActor = SyncActor(modelContainer: container, api: api)
        return await syncActor.sync(agora: .now, userId: userId, forcar: forcar)
    }

    func ciclosLocais() throws -> [CicloSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<CicloSoftex>())
    }

    func gastosLocais() throws -> [GastosDia] {
        try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
    }

    // MARK: O helper

    /// `titulo` apara espaços e corta em 100; `cortarTitulo` (dos campos de
    /// texto) corta sem aparar; 100 exatos não muda.
    @Test func limiteTextoAparaECortaEm100() {
        #expect(LimiteTexto.titulo("  Cuiabá, MT  ") == "Cuiabá, MT")
        #expect(LimiteTexto.titulo(Self.t150).unicodeScalars.count == 100)
        #expect(LimiteTexto.titulo(Self.t100) == Self.t100)
        #expect(LimiteTexto.cortarTitulo(Self.t150).unicodeScalars.count == 100)
        #expect(LimiteTexto.cortarTitulo("  a  ") == "  a  ")
    }

    // MARK: Na entrada (CiclosViewModel)

    @Test func gastoCriadoCom150FicaCom100() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 0,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        try ctx.save()

        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.modelContext = ctx
        vm.atualCiclo = ciclo
        try await vm.createNewGasto(title: Self.t150, value: 25, dia: dia, categoria: .ALIMENTACAO)

        let gasto = try #require(try gastosLocais().first)
        #expect(gasto.titulo.count == 100)
        #expect(gasto.titulo == String(Self.t150.prefix(100)))
    }

    @Test func viagemCriadaCom150FicaCom100() async throws {
        let ctx = ModelContext(container)
        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.modelContext = ctx
        let ida = Calendar.current.startOfDay(for: .now)
        let volta = Calendar.current.date(byAdding: .day, value: 2, to: ida)!

        try await vm.createNewCiclo(startDate: ida, endDate: volta, totalValue: 300, titulo: Self.t150)

        let ciclo = try #require(try ciclosLocais().first)
        #expect(ciclo.titulo.count == 100)
        #expect(ciclo.titulo == String(Self.t150.prefix(100)))
    }

    @Test func gastoEditadoCom150FicaCom100() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 25,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 75)
        ctx.insert(dia)
        dia.ciclo = ciclo
        let gasto = GastosDia(valor: 25, titulo: "Almoço", categoria: .ALIMENTACAO, dia: dia)
        ctx.insert(gasto)
        try ctx.save()

        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.modelContext = ctx
        vm.atualCiclo = ciclo
        try await vm.editGasto(gastoId: gasto.id, novoDia: dia, titulo: Self.t150,
                               value: 25, categoria: .ALIMENTACAO)

        #expect(gasto.titulo.count == 100)
    }

    @Test func viagemEditadaCom150FicaCom100() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 0,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: [])
        ciclo.backendId = 7
        ctx.insert(ciclo)
        try ctx.save()

        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.modelContext = ctx
        vm.allCiclos = [ciclo]
        vm.atualCiclo = ciclo
        let edicao = CicloSoftex(valor_total: 300, gasto_total: 0, periodo: "01/09 - 03/09",
                                 diaria: 100, titulo: Self.t150, dias: nil)
        try await vm.editCiclo(cicloId: 7, ciclo: edicao)

        #expect(ciclo.titulo.count == 100)
    }

    // MARK: No corpo do POST/PUT (SyncActor)

    /// Viagem já gravada no aparelho com 150 caracteres (antes do limite
    /// existir): sobe cortada no corpo e destrava — fica `.synced`.
    @Test func viagemJaGravadaCom150SobeCom100EFicaSynced() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 0,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: Self.t150, dias: [])
        ctx.insert(ciclo)
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.ciclos.first?.titulo == String(Self.t150.prefix(100)))
        let local = try #require(try ciclosLocais().first)
        #expect(local.syncStatus == .synced)
        #expect(local.backendId != nil)
        // Só o corpo vai cortado: o model guarda o título como estava.
        #expect(local.titulo == Self.t150)
    }

    /// Mesmo destrave para o gasto já gravado com 150 caracteres.
    @Test func gastoJaGravadoCom150SobeCom100EFicaSynced() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 25,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 75)
        ctx.insert(dia)
        dia.ciclo = ciclo
        ctx.insert(GastosDia(valor: 25, titulo: Self.t150, categoria: .ALIMENTACAO, dia: dia))
        try ctx.save()

        #expect(await sync() == 0)

        #expect(api.gastos.first?.titulo == String(Self.t150.prefix(100)))
        let local = try #require(try gastosLocais().first)
        #expect(local.syncStatus == .synced)
        #expect(local.backendId != nil)
        #expect(local.titulo == Self.t150)
    }

    /// Edição de uma viagem já no servidor com título de 150 também sobe
    /// cortada no PUT.
    @Test func edicaoDeViagemCom150SobeCom100NoPut() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 0,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)
        try ctx.save()
        #expect(await sync() == 0)
        let backendId = try #require(try ciclosLocais().first?.backendId)

        // Mesmo contexto do cenário: só assim o save persiste a edição.
        let local = try #require(try ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        local.titulo = Self.t150
        local.syncStatus = .pending
        try ctx.save()
        api.limparChamadas()
        #expect(await sync() == 0)

        #expect(api.chamadas == [.putCiclo])
        #expect(api.ciclos.first(where: { $0.id == backendId })?.titulo == String(Self.t150.prefix(100)))
    }

    /// Título de 100 exatos passa sem mudança (na entrada e no envio).
    @Test func tituloDe100ExatosNaoMuda() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(userId: userId, valor_total: 300, gasto_total: 0,
                              periodo: "01/09 - 03/09", diaria: 100, titulo: Self.t100, dias: [])
        ctx.insert(ciclo)
        try ctx.save()

        #expect(await sync() == 0)
        #expect(api.ciclos.first?.titulo == Self.t100)
        #expect(try ciclosLocais().first?.titulo == Self.t100)
    }
}
