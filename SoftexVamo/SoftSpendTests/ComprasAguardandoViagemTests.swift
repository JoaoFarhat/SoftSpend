import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// §1.5 e §1.9 de docs/cartao-sem-open-finance.md: a fila "sem viagem" do
/// Apple Pay — JSON em arquivo temporário, por usuário, teto de 50.
@MainActor
struct ComprasAguardandoViagemTests {

    // MARK: Apoio

    func filaTemp() -> (fila: ComprasAguardandoViagem, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("compras.json")
        return (ComprasAguardandoViagem(url: url), url)
    }

    func compra(userId: String = "u-1", estabelecimento: String = "Padaria Pao Quente",
                recebidaEm: Date = Date(timeIntervalSince1970: 1_000)) -> CompraAguardandoViagem {
        CompraAguardandoViagem(
            id: UUID(), userId: userId, valor: Decimal(string: "12.34")!,
            estabelecimento: estabelecimento, cartao: "Nubank",
            categoria: .ALIMENTACAO, recebidaEm: recebidaEm
        )
    }

    // MARK: Arquivo

    @Test func leEGravaOJson() {
        let (fila, url) = filaTemp()
        let item = compra()
        fila.adicionar(item)

        // Outra instância no mesmo arquivo lê igual — o app e a ação do
        // Apple Pay mexem no mesmo arquivo.
        let outra = ComprasAguardandoViagem(url: url)
        #expect(fila.itens(do: "u-1") == [item])
        #expect(outra.itens(do: "u-1") == [item])
    }

    @Test func tetoDeCinquentaPorUsuario() {
        let (fila, _) = filaTemp()
        var ids: [UUID] = []
        for i in 0..<55 {
            let item = CompraAguardandoViagem(
                id: UUID(), userId: "u-1", valor: 10, estabelecimento: "Loja \(i)",
                cartao: nil, categoria: .OUTROS,
                recebidaEm: Date(timeIntervalSince1970: TimeInterval(i))
            )
            ids.append(item.id)
            fila.adicionar(item)
        }
        let itens = fila.itens(do: "u-1")
        #expect(itens.count == 50)
        // Passando de 50, a mais antiga sai: ficaram as de 5 a 54.
        #expect(!itens.contains { $0.id == ids[0] })
        #expect(!itens.contains { $0.id == ids[4] })
        #expect(itens.contains { $0.id == ids[5] })
        #expect(itens.contains { $0.id == ids[54] })
    }

    @Test func isolaPorUsuario() {
        let (fila, _) = filaTemp()
        let a = compra(userId: "u-1")
        let b = compra(userId: "u-2")
        fila.adicionar(a)
        fila.adicionar(b)
        // Itens de outro usuário ficam intocados e escondidos (§1.5).
        #expect(fila.itens(do: "u-1") == [a])
        #expect(fila.itens(do: "u-2") == [b])
        #expect(fila.itens(do: "u-3").isEmpty)
    }

    @Test func arquivoCorrompidoViraListaVaziaSemDerrubar() throws {
        let (fila, url) = filaTemp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("não é json".utf8).write(to: url)

        #expect(fila.itens(do: "u-1").isEmpty)
        // E grava por cima normalmente.
        let item = compra()
        fila.adicionar(item)
        #expect(fila.itens(do: "u-1") == [item])
    }

    @Test func removerTiraSoOItem() {
        let (fila, _) = filaTemp()
        let a = compra()
        let b = compra()
        fila.adicionar(a)
        fila.adicionar(b)
        fila.remover(id: a.id)
        #expect(fila.itens(do: "u-1") == [b])
    }

    // MARK: Lançar (§1.5): o item sai da fila só depois do save

    func bancoComDia() throws -> (ctx: ModelContext, ciclo: CicloSoftex, dia: DiaSoftex) {
        let container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: "u-1", valor_total: 300, gasto_total: 0,
            periodo: "", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()
        return (ctx, ciclo, dia)
    }

    @Test func lancarGravaOGastoETiraDaFilaDepoisDoSave() throws {
        let (ctx, ciclo, dia) = try bancoComDia()
        let (fila, _) = filaTemp()
        let item = compra()
        fila.adicionar(item)

        let ok = try RegistroApplePay.lancar(item, no: dia, em: ctx, agora: .now, fila: fila)
        #expect(ok)
        #expect(fila.itens(do: "u-1").isEmpty)

        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        #expect(gastos[0].syncStatus == .pending)
        #expect(gastos[0].titulo == item.estabelecimento)
        #expect(gastos[0].dia?.id == dia.id)
        #expect(ciclo.gasto_total == item.valor)
    }

    @Test func lancarNumDiaSemViagemNaoGravaNemTiraDaFila() throws {
        let container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        // Dia órfão: sem viagem, o lançamento é recusado e o item fica na fila.
        let diaOrfao = DiaSoftex(data: .now, saldo: 0)
        ctx.insert(diaOrfao)
        try ctx.save()

        let (fila, _) = filaTemp()
        let item = compra()
        fila.adicionar(item)

        let ok = try RegistroApplePay.lancar(item, no: diaOrfao, em: ctx, fila: fila)
        #expect(!ok)
        #expect(fila.itens(do: "u-1") == [item])
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
    }
}
