import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Fila JSON "sem viagem" do Apple Pay (§1.5 e §1.9 de
/// docs/cartao-sem-open-finance.md): arquivo temporário por teste.
@MainActor
struct ComprasAguardandoViagemTests {
    let arquivo: URL
    let fila: ComprasAguardandoViagem
    let container: ModelContainer
    let ctx: ModelContext
    let userId = "u1"

    init() throws {
        arquivo = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-\(UUID().uuidString).json")
        fila = ComprasAguardandoViagem(arquivo: arquivo)
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    func compra(userId: String? = nil, valor: Decimal = 10,
                recebidaEm: Date = .now) -> CompraAguardandoViagem {
        CompraAguardandoViagem(id: UUID(), userId: userId ?? self.userId,
                               valor: valor, estabelecimento: "Padaria",
                               cartao: nil, categoria: .OUTROS, recebidaEm: recebidaEm)
    }

    @Test func lerEGravar() throws {
        #expect(fila.ler(userId: userId).isEmpty)

        let item = compra(valor: Decimal(string: "12.34")!,
                          recebidaEm: Date(timeIntervalSince1970: 1_780_000_000))
        fila.adicionar(item)

        // Sobrevive a uma instância nova no mesmo arquivo (leu o JSON).
        let relida = ComprasAguardandoViagem(arquivo: arquivo)
        let itens = relida.ler(userId: userId)
        try #require(itens.count == 1)
        #expect(itens[0] == item)
    }

    @Test func tetoDe50PorUsuario() {
        for i in 0..<51 {
            fila.adicionar(compra(valor: Decimal(i),
                                  recebidaEm: Date(timeIntervalSince1970: TimeInterval(i))))
        }

        let itens = fila.ler(userId: userId)
        #expect(itens.count == ComprasAguardandoViagem.tetoPorUsuario)
        // A mais antiga (recebidaEm = 0) saiu; fica a segunda em diante.
        #expect(itens.allSatisfy { $0.recebidaEm > Date(timeIntervalSince1970: 0) })
        #expect(itens.contains { $0.valor == 50 })
    }

    @Test func isolamentoPorUsuario() {
        fila.adicionar(compra(userId: "u1", valor: 10))
        fila.adicionar(compra(userId: "u2", valor: 20))

        #expect(fila.ler(userId: "u1").map(\.valor) == [10])
        #expect(fila.ler(userId: "u2").map(\.valor) == [20])
        #expect(fila.todas().count == 2)
    }

    @Test func tetoEhPorUsuario() {
        for _ in 0..<50 { fila.adicionar(compra(userId: "u1")) }
        for _ in 0..<10 { fila.adicionar(compra(userId: "u2")) }

        #expect(fila.ler(userId: "u1").count == 50)
        #expect(fila.ler(userId: "u2").count == 10)
    }

    @Test func arquivoCorrompidoViraListaVazia() throws {
        try Data("lixo não-json".utf8).write(to: arquivo)
        #expect(fila.todas().isEmpty)
        #expect(fila.ler(userId: userId).isEmpty)

        // E continua funcionando: gravar por cima do arquivo corrompido.
        fila.adicionar(compra())
        #expect(fila.ler(userId: userId).count == 1)
    }

    /// "Lançar" grava o gasto e tira o item da fila **depois** do save.
    @Test func lancarRemoveODepoisDoSave() throws {
        let item = compra(valor: 30)
        fila.adicionar(item)

        let ciclo = CicloSoftex(userId: userId, valor_total: 700, gasto_total: 0,
                                periodo: "13/11 - 15/11", diaria: 100, titulo: "Cuiabá, MT")
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()

        try RegistroApplePay.lancar(item, em: dia, contexto: ctx, fila: fila)

        #expect(fila.ler(userId: userId).isEmpty)
        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        #expect(gastos[0].valor == 30)
        #expect(gastos[0].titulo == "Padaria")
        #expect(ciclo.gasto_total == 30)
    }

    /// Falhou antes do save (dia órfão, sem viagem para somar o total): o item
    /// fica na fila.
    @Test func lancarQueFalhaMantemOItem() throws {
        let item = compra()
        fila.adicionar(item)

        let diaOrfao = DiaSoftex(data: .now, saldo: 100)
        ctx.insert(diaOrfao)
        try ctx.save()

        #expect(throws: ErroRegistro.diaSemViagem) {
            try RegistroApplePay.lancar(item, em: diaOrfao, contexto: ctx, fila: fila)
        }
        #expect(fila.ler(userId: userId).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
    }
}
