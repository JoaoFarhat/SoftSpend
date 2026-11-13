import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// §1.4 e §1.9 de docs/cartao-sem-open-finance.md: a regra do atalho do
/// Apple Pay com banco em memória e fila "sem viagem" em arquivo temporário.
@MainActor
struct RegistroApplePayTests {
    let container: ModelContainer
    let ctx: ModelContext
    let fila: ComprasAguardandoViagem
    let cal = Calendar(identifier: .gregorian)
    /// "Hoje" fixo do teste: sexta, 13/11/2026 às 15h.
    let agora: Date
    let userId = "u-1"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fila = ComprasAguardandoViagem(url: dir.appendingPathComponent("fila.json"))
        agora = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15))!
    }

    // MARK: Apoio

    /// Viagem com um `DiaSoftex` por dia de `inicio` a `fim` (incluídos).
    @discardableResult
    func viagem(de inicio: Date, ate fim: Date, titulo: String = "Cuiabá, MT",
                userId: String? = nil) -> CicloSoftex {
        let ciclo = CicloSoftex(
            userId: userId ?? self.userId, valor_total: 300, gasto_total: 0,
            periodo: "", diaria: 100, titulo: titulo, dias: []
        )
        ciclo.criadoEm = agora
        ctx.insert(ciclo)
        var data = cal.startOfDay(for: inicio)
        let ultimo = cal.startOfDay(for: fim)
        while data <= ultimo {
            let dia = DiaSoftex(data: data, saldo: 100)
            dia.ciclo = ciclo
            ctx.insert(dia)
            data = cal.date(byAdding: .day, value: 1, to: data)!
        }
        try? ctx.save()
        return ciclo
    }

    func registrar(
        valor: String = "R$ 12,34",
        estabelecimento: String = "PADARIA PAO QUENTE",
        agora momento: Date? = nil
    ) throws -> ResultadoRegistro {
        try RegistroApplePay.registrar(
            valorTexto: valor, estabelecimento: estabelecimento, cartao: nil,
            userId: userId, em: ctx, agora: momento ?? agora, calendario: cal, fila: fila
        )
    }

    func gastos() throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    func diaDeHoje(_ ciclo: CicloSoftex) -> DiaSoftex? {
        (ciclo.dias ?? []).first { cal.isDate($0.data, inSameDayAs: agora) }
    }

    // MARK: Gravação no dia de hoje da viagem aberta

    @Test func gravaNoDiaDeHojeDaViagemAbertaESomaNoTotal() throws {
        let ciclo = viagem(de: agora - 86400, ate: agora + 86400)

        let resultado = try registrar()
        guard case .gravado(let titulo, let valor, let viagemNome, let dia) = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        // Apple Pay manda em MAIÚSCULAS: `formatarTitulo` antes de gravar.
        #expect(titulo == "Padaria Pao Quente")
        #expect(valor == Decimal(string: "12.34"))
        #expect(viagemNome == "Cuiabá")
        #expect(cal.isDate(dia, inSameDayAs: agora))

        let todos = try gastos()
        try #require(todos.count == 1)
        let gasto = todos[0]
        #expect(gasto.syncStatus == .pending)
        #expect(ciclo.gasto_total == valor)
        let diaHoje = try #require(diaDeHoje(ciclo))
        #expect(gasto.dia?.id == diaHoje.id)
        // Sem append manual na relação inversa (pegadinha 3 do AGENTS.md).
        #expect(diaHoje.gastos.count == 1)
    }

    @Test("Categoria sugerida pelo nome do local", arguments: [
        ("UBER*TRIP", Categoria.TRANSPORTE),
        ("CINEMARK SHOPPING", Categoria.LAZER),
        ("PADARIA PÃO QUENTE", Categoria.ALIMENTACAO),
        ("XPTO DESCONHECIDO", Categoria.OUTROS),
    ])
    func categoriaSugerida(_ estabelecimento: String, _ esperada: Categoria) throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        _ = try registrar(estabelecimento: estabelecimento)
        #expect(try gastos().first?.categoria == esperada)
    }

    @Test func estabelecimentoVazioViraCompraNoCartao() throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        let resultado = try registrar(estabelecimento: "   ")
        guard case .gravado(let titulo, _, _, _) = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        #expect(titulo == "Compra no cartão")
    }

    // MARK: Só viagem aberta conta (senão vai para a fila)

    @Test func viagemEncerradaVaiParaFila() throws {
        viagem(de: agora - 10 * 86400, ate: agora - 5 * 86400)
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria Pao Quente", valor: Decimal(string: "12.34")!))
        #expect(fila.itens(do: userId).count == 1)
        #expect(try gastos().isEmpty)
    }

    @Test func viagemFuturaVaiParaFila() throws {
        viagem(de: agora + 2 * 86400, ate: agora + 5 * 86400)
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria Pao Quente", valor: Decimal(string: "12.34")!))
        #expect(fila.itens(do: userId).count == 1)
    }

    @Test func viagemApagadaVaiParaFila() throws {
        let ciclo = viagem(de: agora - 86400, ate: agora + 86400)
        ciclo.deletadoEm = agora
        try ctx.save()
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria Pao Quente", valor: Decimal(string: "12.34")!))
        #expect(fila.itens(do: userId).count == 1)
    }

    @Test func viagemDeOutroUsuarioVaiParaFila() throws {
        viagem(de: agora - 86400, ate: agora + 86400, userId: "u-2")
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria Pao Quente", valor: Decimal(string: "12.34")!))
        // O item é do usuário que recebeu a compra, nunca do dono da viagem.
        #expect(fila.itens(do: "u-1").count == 1)
        #expect(fila.itens(do: "u-2").isEmpty)
    }

    @Test func semViagemAlgumaVaiParaFila() throws {
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria Pao Quente", valor: Decimal(string: "12.34")!))
        let item = try #require(fila.itens(do: "u-1").first)
        #expect(item.valor == Decimal(string: "12.34"))
        #expect(item.estabelecimento == "Padaria Pao Quente")
    }

    @Test func viagemSemDiaLocalDeHojeVaiParaFila() throws {
        // O intervalo pelo `periodo` contém hoje (instalação nova que ainda não
        // baixou os dias), mas não existe DiaSoftex local de hoje: fila, nunca
        // um dia errado.
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "12/11 - 20/11", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        // O `periodo` é lido no ano do `criadoEm`: fixa para o teste não
        // depender da data real.
        ciclo.criadoEm = agora
        ctx.insert(ciclo)
        try ctx.save()

        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria Pao Quente", valor: Decimal(string: "12.34")!))
        #expect(fila.itens(do: userId).count == 1)
        #expect(try gastos().isEmpty)
    }

    @Test func sobreposicaoPegaADePrimeiroDiaMaisRecente() throws {
        let antiga = viagem(de: agora - 5 * 86400, ate: agora + 86400, titulo: "Antiga, XX")
        let recente = viagem(de: agora - 2 * 86400, ate: agora + 86400, titulo: "Recente, YY")

        let resultado = try registrar()
        guard case .gravado(_, _, let viagemNome, _) = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        #expect(viagemNome == "Recente")
        #expect(recente.gasto_total == Decimal(string: "12.34"))
        #expect(antiga.gasto_total == 0)
    }

    // MARK: Deduplicação (janela deslizante de 60 s)

    @Test func duplicataEm30sEhBarrada() throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        _ = try registrar()
        #expect(try registrar(agora: agora + 30) == .duplicado)
        #expect(try gastos().count == 1)
    }

    @Test func duplicataEm61sGrava() throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        _ = try registrar()
        let resultado = try registrar(agora: agora + 61)
        guard case .gravado = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        #expect(try gastos().count == 2)
    }

    @Test("Duplicata com título em outra caixa ou com acento é barrada", arguments: [
        "padaria pao quente", "PADARIA PÃO QUENTE", "Padaria   Pao    Quente",
    ])
    func duplicataTituloNormalizado(_ estabelecimento: String) throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        _ = try registrar(estabelecimento: "PADARIA PAO QUENTE")
        #expect(try registrar(estabelecimento: estabelecimento, agora: agora + 30) == .duplicado)
        #expect(try gastos().count == 1)
    }

    @Test func valorDiferenteGrava() throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        _ = try registrar(valor: "R$ 12,34")
        let resultado = try registrar(valor: "R$ 12,35", agora: agora + 30)
        guard case .gravado = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        #expect(try gastos().count == 2)
    }

    @Test func duplicataContraItemDaFilaEhBarrada() throws {
        // Sem viagem: a primeira vai para a fila; a segunda em 30 s é a mesma compra.
        _ = try registrar()
        #expect(fila.itens(do: userId).count == 1)
        #expect(try registrar(agora: agora + 30) == .duplicado)
        #expect(fila.itens(do: userId).count == 1)
    }

    @Test func gastoApagadoNaoContaParaDuplicata() throws {
        let ciclo = viagem(de: agora - 86400, ate: agora + 86400)
        let diaHoje = try #require(diaDeHoje(ciclo))
        let apagado = GastosDia(valor: Decimal(string: "12.34")!, titulo: "Padaria Pao Quente",
                                categoria: .ALIMENTACAO, dia: diaHoje)
        apagado.criadoEm = agora - 10
        apagado.deletadoEm = agora - 5
        ctx.insert(apagado)
        try ctx.save()

        let resultado = try registrar()
        guard case .gravado = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        // O apagado continua no banco (soft delete) + o novo gravado.
        #expect(try gastos().count == 2)
    }

    // MARK: Recusas

    @Test func semUsuarioRecusaENaoGrava() throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        let resultado = try RegistroApplePay.registrar(
            valorTexto: "R$ 12,34", estabelecimento: "PADARIA", cartao: nil,
            userId: nil, em: ctx, agora: agora, calendario: cal, fila: fila
        )
        #expect(resultado == .recusado(.semUsuario))
        #expect(try gastos().isEmpty)
        #expect(fila.itens(do: userId).isEmpty)
    }

    @Test func valorInvalidoEMoedaEstrangeiraSaoRecusados() throws {
        viagem(de: agora - 86400, ate: agora + 86400)
        #expect(try registrar(valor: "abc") == .recusado(.valorInvalido))
        #expect(try registrar(valor: "0,00") == .recusado(.valorInvalido))
        #expect(try registrar(valor: "US$ 10,00") == .recusado(.moedaEstrangeira))
        #expect(try gastos().isEmpty)
        #expect(fila.itens(do: userId).isEmpty)
    }
}
