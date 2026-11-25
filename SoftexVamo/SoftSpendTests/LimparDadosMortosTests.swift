import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// `SyncManager.limparDadosMortos` apaga de vez do aparelho o que já foi
/// sincronizado como apagado há mais de 7 dias (`.synced` + `deletadoEm`
/// velho): o `DELETE` já subiu e o servidor não devolve o item de novo. Item
/// apagado ainda não enviado (`.pending`/`.failed`) fica, por mais velho que
/// esteja — apagá-lo impediria o `DELETE` de sair e o registro voltaria na
/// próxima leitura. Item vivo também fica.
@MainActor
struct LimparDadosMortosTests {
    let container: ModelContainer
    let ctx: ModelContext
    let manager = SyncManager(estaConectado: { true })
    let userId = "usuario-teste"
    let agora = Date()

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    // MARK: Apoio

    /// `dias` corridos atrás do `agora` fixo do teste.
    private func ha(_ dias: Double) -> Date {
        agora.addingTimeInterval(-dias * 24 * 3600)
    }

    @discardableResult
    private func semearCiclo(deletadoEm: Date? = nil) -> CicloSoftex {
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ciclo.backendId = 1
        ciclo.syncStatus = .synced
        ciclo.deletadoEm = deletadoEm
        ctx.insert(ciclo)
        return ciclo
    }

    @discardableResult
    private func semearDia(no ciclo: CicloSoftex, deletadoEm: Date? = nil) -> DiaSoftex {
        let dia = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        dia.backendId = 1
        dia.syncStatus = .synced
        dia.deletadoEm = deletadoEm
        return dia
    }

    @discardableResult
    private func semearGasto(no dia: DiaSoftex, titulo: String = "Gasto",
                             deletadoEm: Date? = nil, syncStatus: SyncStatus = .synced) -> GastosDia {
        let gasto = GastosDia(valor: 10, titulo: titulo, categoria: .ALIMENTACAO, dia: dia)
        gasto.backendId = 1
        gasto.syncStatus = syncStatus
        gasto.deletadoEm = deletadoEm
        ctx.insert(gasto)
        return gasto
    }

    /// Contagens num contexto novo: enxerga o que o `limparDadosMortos` salvou.
    private func contagens() throws -> (ciclos: Int, dias: Int, gastos: Int) {
        let leitura = ModelContext(container)
        return (
            try leitura.fetchCount(FetchDescriptor<CicloSoftex>()),
            try leitura.fetchCount(FetchDescriptor<DiaSoftex>()),
            try leitura.fetchCount(FetchDescriptor<GastosDia>())
        )
    }

    private func limpar() {
        manager.limparDadosMortos(context: ctx, agora: agora)
    }

    // MARK: Testes

    /// (a) Gasto `.synced` apagado há 8 dias (mais que o limite de 7) sai do
    /// aparelho; o dia e a viagem dele ficam.
    @Test func gastoApagadoHaMaisDeSeteDiasSai() throws {
        let ciclo = semearCiclo()
        let dia = semearDia(no: ciclo)
        semearGasto(no: dia, deletadoEm: ha(8))
        try ctx.save()

        limpar()

        #expect(try contagens() == (1, 1, 0))
    }

    /// (b) O mesmo gasto com 6 dias ainda está dentro do prazo e fica.
    @Test func gastoApagadoHaMenosDeSeteDiasFica() throws {
        let ciclo = semearCiclo()
        let dia = semearDia(no: ciclo)
        semearGasto(no: dia, deletadoEm: ha(6))
        try ctx.save()

        limpar()

        #expect(try contagens() == (1, 1, 1))
    }

    /// (c) Gasto apagado mas ainda não enviado (`.pending` ou `.failed`) fica
    /// mesmo com `deletadoEm` de 30 dias: a limpeza não pode impedir o
    /// `DELETE` de subir — senão o item voltaria do servidor na próxima
    /// leitura.
    @Test func gastoApagadoNaoEnviadoFicaPorMaisVelhoQueSeja() throws {
        let ciclo = semearCiclo()
        let dia = semearDia(no: ciclo)
        semearGasto(no: dia, titulo: "Pendente", deletadoEm: ha(30), syncStatus: .pending)
        semearGasto(no: dia, titulo: "Falhou", deletadoEm: ha(30), syncStatus: .failed)
        try ctx.save()

        limpar()

        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        #expect(gastos.count == 2)
        #expect(gastos.allSatisfy { $0.deletadoEm != nil })
    }

    /// (d) Gasto vivo `.synced` (sem `deletadoEm`) nunca sai na limpeza.
    @Test func gastoVivoSincronizadoFica() throws {
        let ciclo = semearCiclo()
        let dia = semearDia(no: ciclo)
        semearGasto(no: dia)
        try ctx.save()

        limpar()

        #expect(try contagens() == (1, 1, 1))
    }

    /// (e) Viagem `.synced` apagada há 8 dias sai pela cascata com os dias e
    /// os gastos — aqui os filhos estão vivos (o `deleteCiclo` marca só a
    /// viagem), então a saída deles é só pela cascata do `delete`, não pelo
    /// filtro da limpeza. A viagem viva ao lado fica intacta.
    @Test func viagemApagadaSaiComDiasEGastos() throws {
        let morta = semearCiclo(deletadoEm: ha(8))
        for i in 0..<2 {
            let dia = semearDia(no: morta)
            semearGasto(no: dia, titulo: "Morto \(i)")
        }
        let viva = semearCiclo()
        let diaVivo = semearDia(no: viva)
        semearGasto(no: diaVivo, titulo: "Vivo")
        try ctx.save()

        limpar()

        let leitura = ModelContext(container)
        let ciclos = try leitura.fetch(FetchDescriptor<CicloSoftex>())
        #expect(ciclos.map(\.id) == [viva.id])
        // Os dias e gastos que restaram são os da viagem viva.
        let dias = try leitura.fetch(FetchDescriptor<DiaSoftex>())
        #expect(dias.count == 1)
        #expect(dias.first?.ciclo?.id == viva.id)
        let gastos = try leitura.fetch(FetchDescriptor<GastosDia>())
        #expect(gastos.map(\.titulo) == ["Vivo"])
    }

    /// (f) Dia `.synced` apagado há 8 dias numa viagem **viva** sai com os
    /// gastos dele (cascata), e a viagem e o `gasto_total` dela ficam como
    /// estavam: os valores dos gastos apagados já tinham saído do total na
    /// hora em que foram marcados — a limpeza não desconta de novo.
    @Test func diaApagadoNumaViagemVivaSaiComOsGastosDele() throws {
        let ciclo = semearCiclo()
        ciclo.gasto_total = 40 // só o gasto vivo: os apagados já saíram do total
        let diaMorto = semearDia(no: ciclo, deletadoEm: ha(8))
        semearGasto(no: diaMorto, titulo: "Morto 1", deletadoEm: ha(8))
        semearGasto(no: diaMorto, titulo: "Morto 2", deletadoEm: ha(8))
        let diaVivo = semearDia(no: ciclo)
        semearGasto(no: diaVivo, titulo: "Vivo")
        try ctx.save()

        limpar()

        let leitura = ModelContext(container)
        let ciclos = try leitura.fetch(FetchDescriptor<CicloSoftex>())
        #expect(ciclos.count == 1)
        #expect(ciclos.first?.gasto_total == 40)
        let dias = try leitura.fetch(FetchDescriptor<DiaSoftex>())
        #expect(dias.map(\.id) == [diaVivo.id])
        let gastos = try leitura.fetch(FetchDescriptor<GastosDia>())
        #expect(gastos.map(\.titulo) == ["Vivo"])
    }
}
