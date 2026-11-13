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
        try fila.adicionar(item)

        // Sobrevive a uma instância nova no mesmo arquivo (leu o JSON).
        let relida = ComprasAguardandoViagem(arquivo: arquivo)
        let itens = relida.ler(userId: userId)
        try #require(itens.count == 1)
        #expect(itens[0] == item)
    }

    @Test func tetoDe50PorUsuario() throws {
        for i in 0..<51 {
            try fila.adicionar(compra(valor: Decimal(i),
                                      recebidaEm: Date(timeIntervalSince1970: TimeInterval(i))))
        }

        let itens = fila.ler(userId: userId)
        #expect(itens.count == ComprasAguardandoViagem.tetoPorUsuario)
        // A mais antiga (recebidaEm = 0) saiu; fica a segunda em diante.
        #expect(itens.allSatisfy { $0.recebidaEm > Date(timeIntervalSince1970: 0) })
        #expect(itens.contains { $0.valor == 50 })
    }

    @Test func isolamentoPorUsuario() throws {
        try fila.adicionar(compra(userId: "u1", valor: 10))
        try fila.adicionar(compra(userId: "u2", valor: 20))

        #expect(fila.ler(userId: "u1").map(\.valor) == [10])
        #expect(fila.ler(userId: "u2").map(\.valor) == [20])
        #expect(fila.todas().count == 2)
    }

    @Test func tetoEhPorUsuario() throws {
        for _ in 0..<50 { try fila.adicionar(compra(userId: "u1")) }
        for _ in 0..<10 { try fila.adicionar(compra(userId: "u2")) }

        #expect(fila.ler(userId: "u1").count == 50)
        #expect(fila.ler(userId: "u2").count == 10)
    }

    /// Arquivo corrompido lê como lista vazia e vai para quarentena
    /// (`<nome>.corrompido-<data>`) em vez de ser sobrescrito — os itens dos
    /// outros usuários não se perdem num arquivo que dá para recuperar.
    @Test func arquivoCorrompidoVaiParaQuarentenaELeComoVazia() throws {
        try Data("lixo não-json".utf8).write(to: arquivo)
        #expect(fila.todas().isEmpty)
        #expect(fila.ler(userId: userId).isEmpty)

        let backups = try FileManager.default.contentsOfDirectory(
            at: arquivo.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("\(arquivo.lastPathComponent).corrompido-")
        }
        try #require(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == "lixo não-json")
        #expect(!FileManager.default.fileExists(atPath: arquivo.path))

        // E continua funcionando: a próxima gravação cria um arquivo novo.
        try fila.adicionar(compra())
        #expect(fila.ler(userId: userId).count == 1)
    }

    /// Arquivo que existe mas não lê (permissão) não pode virar lista vazia:
    /// `adicionar` lança em vez de sobrescrever os itens de todos os usuários
    /// e `ler` segue devolvendo vazio sem derrubar o app.
    @Test func arquivoIlegivelNaoEhLidoComoVazioNemSobrescrito() throws {
        try fila.adicionar(compra(valor: 42))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: arquivo.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: arquivo.path)
        }

        #expect(fila.ler(userId: userId).isEmpty)
        #expect(!fila.contem(id: UUID()))
        #expect(throws: (any Error).self) { try fila.adicionar(compra()) }

        // Voltou a permissão, a fila continua lá — nada foi sobrescrito.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: arquivo.path)
        #expect(fila.ler(userId: userId).map(\.valor) == [42])
    }

    /// Pasta que não existe: a escrita atômica falha e `adicionar` lança — a
    /// ação responde erro em vez de "guardado" com a compra perdida.
    @Test func adicionarEmPastaInexistenteLanca() {
        let quebrada = ComprasAguardandoViagem(
            arquivo: FileManager.default.temporaryDirectory
                .appendingPathComponent("pasta-\(UUID().uuidString)")
                .appendingPathComponent("fila.json"))
        #expect(throws: (any Error).self) { try quebrada.adicionar(compra()) }
        // Ler segue devolvendo lista vazia, sem derrubar o app.
        #expect(quebrada.ler(userId: userId).isEmpty)
    }

    /// Toque duplo em "Lançar": a `compras` da folha é uma cópia. O segundo
    /// toque encontra o `id` fora da fila e vira no-op — sem gasto duplicado.
    @Test func lancarComItemForaDaFilaNaoGrava() throws {
        let item = compra()  // nunca entrou na fila

        let ciclo = CicloSoftex(userId: userId, valor_total: 700, gasto_total: 0,
                                periodo: "13/11 - 15/11", diaria: 100, titulo: "Cuiabá, MT")
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()

        try RegistroApplePay.lancar(item, em: dia, contexto: ctx, fila: fila)

        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
        #expect(ciclo.gasto_total == 0)
    }

    /// "Lançar" grava o gasto e tira o item da fila **depois** do save.
    @Test func lancarRemoveODepoisDoSave() throws {
        let recebida = Date(timeIntervalSince1970: 1_780_000_000)
        let item = compra(valor: 30, recebidaEm: recebida)
        try fila.adicionar(item)

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
        // `criadoEm` é quando a compra aconteceu, não quando foi lançada.
        #expect(gastos[0].criadoEm == recebida)
        #expect(ciclo.gasto_total == 30)
    }

    /// Falhou antes do save (dia órfão, sem viagem para somar o total): o item
    /// fica na fila.
    @Test func lancarQueFalhaMantemOItem() throws {
        let item = compra()
        try fila.adicionar(item)

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
