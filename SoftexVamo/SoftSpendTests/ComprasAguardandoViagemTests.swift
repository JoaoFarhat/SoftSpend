import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// §1.5 de docs/cartao-sem-open-finance.md: a fila JSON de compras do Apple Pay
/// sem viagem aberta — por usuário, teto de 50, arquivo corrompido vira lista
/// vazia, e "lançar" só tira o item depois que o gasto foi gravado.
@MainActor
struct ComprasAguardandoViagemTests {
    let diretorio: URL
    let usuario = "user-1"

    init() {
        diretorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-\(UUID().uuidString)", isDirectory: true)
    }

    func fila() -> ComprasAguardandoViagem {
        ComprasAguardandoViagem(diretorio: diretorio)
    }

    /// Compra de teste; `i` vira valor, nome do estabelecimento e `recebidaEm`
    /// (segundos desde 1970 — inteiro, então o ida e volta do JSON é exato).
    func compra(_ i: Int, userId: String? = nil) -> CompraAguardandoViagem {
        CompraAguardandoViagem(
            id: UUID(), userId: userId ?? usuario, valor: Decimal(i),
            estabelecimento: "Loja \(i)", cartao: i.isMultiple(of: 2) ? "Cartão" : nil,
            categoria: .OUTROS, recebidaEm: Date(timeIntervalSince1970: TimeInterval(i)))
    }

    @Test func leEGravaOJson() {
        let f = fila()
        f.guardar(compra(1))
        f.guardar(compra(2))
        // Instância nova, do disco: prova que o arquivo foi gravado.
        let itens = fila().ler(userId: usuario)
        #expect(itens.map(\.estabelecimento) == ["Loja 1", "Loja 2"])
        #expect(itens[0].recebidaEm == Date(timeIntervalSince1970: 1))
        #expect(itens[1].cartao == "Cartão")
        #expect(itens[1].categoria == .OUTROS)
    }

    @Test func removerTiraSoOItem() {
        let f = fila()
        let um = compra(1)
        f.guardar(um)
        f.guardar(compra(2))
        f.remover(id: um.id)
        #expect(fila().ler(userId: usuario).map(\.estabelecimento) == ["Loja 2"])
    }

    @Test func tetoDeCinquentaPorUsuario() {
        let f = fila()
        for i in 1...51 { f.guardar(compra(i)) }
        let itens = f.ler(userId: usuario)
        #expect(itens.count == 50)
        // A mais antiga saiu; a mais nova ficou.
        #expect(!itens.contains { $0.estabelecimento == "Loja 1" })
        #expect(itens.last?.estabelecimento == "Loja 51")
    }

    @Test func isolamentoPorUsuario() {
        let f = fila()
        f.guardar(compra(1))
        f.guardar(compra(2, userId: "outro"))
        #expect(f.ler(userId: usuario).map(\.estabelecimento) == ["Loja 1"])
        #expect(f.ler(userId: "outro").count == 1)
        // O teto é por usuário: encher a fila de "outro" não tira nada de "usuario".
        for i in 10...60 { f.guardar(compra(i, userId: "outro")) }
        #expect(f.ler(userId: "outro").count == 50)
        #expect(f.ler(userId: usuario).count == 1)
    }

    @Test func arquivoCorrompidoViraListaVazia() throws {
        let f = fila()
        f.guardar(compra(1))
        let arquivo = diretorio.appendingPathComponent("compras-apple-pay.json")
        try Data("lixo".utf8).write(to: arquivo)
        #expect(f.ler(userId: usuario).isEmpty)
        // E a fila volta a funcionar por cima do arquivo corrompido.
        f.guardar(compra(2))
        #expect(fila().ler(userId: usuario).map(\.estabelecimento) == ["Loja 2"])
    }

    // MARK: Lançar da fila

    func banco() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        return (container, ModelContext(container))
    }

    @discardableResult
    func viagemHoje(em ctx: ModelContext) -> (ciclo: CicloSoftex, dia: DiaSoftex) {
        let ciclo = CicloSoftex(
            userId: usuario, valor_total: 300, gasto_total: 0,
            periodo: "", diaria: 100, titulo: "Cuiabá", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        try? ctx.save()
        return (ciclo, dia)
    }

    @Test func lancarGravaESaiDaFilaDepoisDoSave() throws {
        let (_, ctx) = try banco()
        let (ciclo, dia) = viagemHoje(em: ctx)
        let item = compra(1)
        let f = fila()
        f.guardar(item)

        let gasto = try RegistroApplePay.lancar(item, em: dia, em: ctx, fila: f)
        // O gasto nasce com o id da compra e o item só saiu depois do save.
        #expect(gasto.id == item.id)
        #expect(gasto.valor == item.valor)
        #expect(ciclo.gasto_total == item.valor)
        #expect(dia.gastos.count == 1)
        #expect(f.ler(userId: usuario).isEmpty)

        // Lançar de novo não duplica: acha o gasto e só limpa a fila.
        f.guardar(compra(2))
        let repetido = try RegistroApplePay.lancar(item, em: dia, em: ctx, fila: f)
        #expect(repetido.id == gasto.id)
        #expect(dia.gastos.count == 1)
        #expect(f.ler(userId: usuario).map(\.estabelecimento) == ["Loja 2"])
    }

    @Test func lancarQueNaoDaCertoMantemNaFila() throws {
        let (_, ctx) = try banco()
        // Dia solto, sem viagem: o lançamento falha antes de gravar e o item
        // fica — o mesmo caminho de quando o `save()` falha (`remover` só
        // roda depois do `try gravar`).
        let diaSolto = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(diaSolto)
        try ctx.save()

        let item = compra(1)
        let f = fila()
        f.guardar(item)
        #expect(throws: (any Error).self) {
            try RegistroApplePay.lancar(item, em: diaSolto, em: ctx, fila: f)
        }
        #expect(f.ler(userId: usuario).count == 1)
    }
}
