import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// §1.4 de docs/cartao-sem-open-finance.md: a regra do registro do gasto do
/// Apple Pay — dia de hoje da viagem aberta, categoria, duplicata em 60 s e
/// fila "sem viagem" (§1.5). Banco em memória; fila em diretório temporário.
@MainActor
struct RegistroApplePayTests {
    let container: ModelContainer
    let ctx: ModelContext
    let fila: ComprasAguardandoViagem
    let usuario = "user-1"

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }()
    /// "Agora" fixo dos testes: 10h do dia 15/07/2026.
    var agora: Date { d(15, 7, hora: 10) }

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        fila = ComprasAguardandoViagem(diretorio: FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: Apoio

    func d(_ dia: Int, _ mes: Int, hora: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mes, day: dia, hour: hora))!
    }
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    /// Viagem com um dia para cada data de `ini` a `fim` (o intervalo sai dos dias).
    @discardableResult
    func viagem(de ini: Int, ate fim: Int, mes: Int = 7, userId: String? = nil,
                titulo: String = "Cuiabá", apagada: Bool = false) -> CicloSoftex {
        let ciclo = CicloSoftex(
            userId: userId ?? usuario, valor_total: 700, gasto_total: 0,
            periodo: "", diaria: 100, titulo: titulo, dias: []
        )
        ctx.insert(ciclo)
        for n in ini...fim {
            let dia = DiaSoftex(data: d(n, mes), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = ciclo
        }
        if apagada { ciclo.deletadoEm = agora }
        try? ctx.save()
        return ciclo
    }

    func diaDoCiclo(_ ciclo: CicloSoftex, _ n: Int) -> DiaSoftex {
        ciclo.dias!.first { cal.component(.day, from: $0.data) == n }!
    }

    func registrar(valor: String = "25", estab: String = "Padaria Pão",
                   userId: String? = nil, em data: Date? = nil) -> ResultadoRegistro {
        RegistroApplePay.registrar(
            valorTexto: valor, estabelecimento: estab, cartao: nil,
            userId: userId ?? usuario, em: ctx, fila: fila,
            agora: data ?? agora, calendario: cal
        )
    }

    func gastosDoBanco() throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    /// Gasto já existente para os testes de duplicata.
    @discardableResult
    func gastoExistente(valor: Decimal = 25, titulo: String = "Padaria Pão",
                        userId: String? = nil, criadoEm: Date, apagado: Bool = false) -> GastosDia {
        let ciclo = viagem(de: 13, ate: 17, userId: userId)
        let gasto = GastosDia(valor: valor, titulo: titulo, categoria: .ALIMENTACAO,
                              dia: diaDoCiclo(ciclo, 15))
        gasto.criadoEm = criadoEm
        if apagado { gasto.deletadoEm = agora }
        ctx.insert(gasto)
        try? ctx.save()
        return gasto
    }

    // MARK: Gravação

    @Test func gravaNoDiaDeHojeDaViagemAbertaESomaNoTotal() throws {
        let ciclo = viagem(de: 13, ate: 17, titulo: "Cuiabá, MT")
        let r = registrar(valor: "R$ 12,34", estab: "PADARIA PAO QUENTE")
        guard case .gravado(let titulo, let valor, let viagemNome, let data) = r else {
            Issue.record("esperava .gravado, veio \(r)")
            return
        }
        // MAIÚSCULAS do Apple Pay passam pelo formatarTitulo.
        #expect(titulo == "Padaria Pao Quente")
        #expect(valor == dec("12.34"))
        #expect(viagemNome == "Cuiabá, MT")
        #expect(cal.isDate(data, inSameDayAs: agora))
        #expect(ciclo.gasto_total == dec("12.34"))
        let diaHoje = diaDoCiclo(ciclo, 15)
        try #require(diaHoje.gastos.count == 1)
        #expect(diaHoje.gastos[0].titulo == "Padaria Pao Quente")
    }

    @Test func naoDuplicaARelacaoDoDia() throws {
        let ciclo = viagem(de: 13, ate: 17)
        guard case .gravado = registrar() else {
            Issue.record("esperava .gravado")
            return
        }
        // Insert + relação inversa automática, sem append manual (pegadinha 3).
        #expect(diaDoCiclo(ciclo, 15).gastos.count == 1)
        #expect(try gastosDoBanco().count == 1)
    }

    @Test func gastoFicaPendenteDeSync() throws {
        _ = viagem(de: 13, ate: 17)
        guard case .gravado = registrar() else {
            Issue.record("esperava .gravado")
            return
        }
        let gasto = try #require(gastosDoBanco().first)
        #expect(gasto.syncStatus == .pending)
        #expect(gasto.backendId == nil)
    }

    @Test(arguments: [("UBER *APP", Categoria.TRANSPORTE), ("CINEMARK", Categoria.LAZER), ("LOJA XPTO", Categoria.OUTROS)])
    func categoriaPeloNomeDoEstabelecimento(estab: String, esperada: Categoria) throws {
        _ = viagem(de: 13, ate: 17)
        guard case .gravado = registrar(estab: estab) else {
            Issue.record("esperava .gravado para \(estab)")
            return
        }
        #expect(try gastosDoBanco().first?.categoria == esperada)
    }

    @Test func estabelecimentoVazioViraCompraNoCartao() throws {
        _ = viagem(de: 13, ate: 17)
        guard case .gravado(let titulo, _, _, _) = registrar(estab: "   ") else {
            Issue.record("esperava .gravado")
            return
        }
        #expect(titulo == "Compra no cartão")
    }

    // MARK: Qual viagem conta

    @Test func viagemEncerradaOuFuturaNaoConta() throws {
        _ = viagem(de: 10, ate: 12, titulo: "Encerrada")
        _ = viagem(de: 20, ate: 22, titulo: "Futura")
        #expect(registrar() == .guardadoSemViagem(titulo: "Padaria Pão", valor: dec("25")))
        #expect(fila.ler(userId: usuario).count == 1)
        #expect(try gastosDoBanco().isEmpty)
    }

    @Test func viagemApagadaNaoConta() throws {
        _ = viagem(de: 13, ate: 17, apagada: true)
        #expect(registrar() == .guardadoSemViagem(titulo: "Padaria Pão", valor: dec("25")))
    }

    @Test func viagemDeOutroUsuarioNaoConta() throws {
        _ = viagem(de: 13, ate: 17, userId: "outro")
        #expect(registrar() == .guardadoSemViagem(titulo: "Padaria Pão", valor: dec("25")))
        #expect(fila.ler(userId: usuario).count == 1)
        #expect(fila.ler(userId: "outro").isEmpty)
    }

    @Test func sobreposicaoUsaAViagemDePrimeiroDiaMaisRecente() throws {
        _ = viagem(de: 13, ate: 16, titulo: "ComecouAntes")
        let recente = viagem(de: 15, ate: 18, titulo: "ComecouDepois")
        let r = registrar()
        guard case .gravado(_, _, let viagemNome, _) = r else {
            Issue.record("esperava .gravado, veio \(r)")
            return
        }
        #expect(viagemNome == "ComecouDepois")
        #expect(diaDoCiclo(recente, 15).gastos.count == 1)
    }

    // MARK: Fila "sem viagem" (§1.5)

    @Test func semViagemVaiParaAFilaComOsCampos() throws {
        let r = registrar(valor: "R$ 30,50", estab: "  POSTO  IPIRANGA  ")
        #expect(r == .guardadoSemViagem(titulo: "Posto Ipiranga", valor: dec("30.5")))
        let itens = fila.ler(userId: usuario)
        try #require(itens.count == 1)
        #expect(itens[0].valor == dec("30.5"))
        #expect(itens[0].estabelecimento == "Posto Ipiranga")
        #expect(itens[0].categoria == .TRANSPORTE)
        // O JSON guarda a data como Double: compara com folga.
        #expect(abs(itens[0].recebidaEm.timeIntervalSince1970 - agora.timeIntervalSince1970) < 0.01)
        #expect(try gastosDoBanco().isEmpty)
    }

    @Test func viagemSemDiaLocalDeHojeVaiParaAFila() throws {
        // Intervalo 14–17 contém hoje (15), mas o dia 15 não existe localmente
        // (instalação nova que ainda não baixou os dias): nunca dia errado.
        let ciclo = CicloSoftex(
            userId: usuario, valor_total: 700, gasto_total: 0,
            periodo: "", diaria: 100, titulo: "Cuiabá", dias: []
        )
        ctx.insert(ciclo)
        for n in [14, 16, 17] {
            let dia = DiaSoftex(data: d(n, 7), saldo: 100)
            ctx.insert(dia)
            dia.ciclo = ciclo
        }
        try ctx.save()
        #expect(registrar() == .guardadoSemViagem(titulo: "Padaria Pão", valor: dec("25")))
    }

    // MARK: Duplicata (janela deslizante de 60 s)

    @Test func duplicataEm30SegundosEhBarrada() throws {
        _ = gastoExistente(criadoEm: agora.addingTimeInterval(-30))
        #expect(registrar() == .duplicado)
        #expect(try gastosDoBanco().count == 1)
    }

    @Test func depoisDe61SegundosGravaDeNovo() throws {
        _ = gastoExistente(criadoEm: agora.addingTimeInterval(-61))
        guard case .gravado = registrar() else {
            Issue.record("esperava .gravado")
            return
        }
        #expect(try gastosDoBanco().count == 2)
    }

    @Test func duplicataComTituloEmOutraCaixaOuComAcentoEhBarrada() throws {
        _ = gastoExistente(titulo: "Padaria Pão", criadoEm: agora.addingTimeInterval(-10))
        #expect(registrar(estab: "padaria   PAO") == .duplicado)
        #expect(registrar(estab: "PADARIA PAO") == .duplicado)
        #expect(try gastosDoBanco().count == 1)
    }

    @Test func valorDiferenteNaoEhDuplicata() throws {
        _ = gastoExistente(valor: 30, criadoEm: agora.addingTimeInterval(-10))
        guard case .gravado = registrar(valor: "25") else {
            Issue.record("esperava .gravado")
            return
        }
        #expect(try gastosDoBanco().count == 2)
    }

    @Test func duplicataContraItemDaFilaEhBarrada() throws {
        _ = viagem(de: 13, ate: 17)
        fila.guardar(CompraAguardandoViagem(
            id: UUID(), userId: usuario, valor: dec("25"),
            estabelecimento: "Padaria Pão", cartao: "Nubank",
            categoria: .ALIMENTACAO, recebidaEm: agora.addingTimeInterval(-10)))
        #expect(registrar() == .duplicado)
        #expect(try gastosDoBanco().isEmpty)
        #expect(fila.ler(userId: usuario).count == 1)
    }

    @Test func gastoApagadoNaoContaParaDuplicata() throws {
        _ = gastoExistente(criadoEm: agora.addingTimeInterval(-10), apagado: true)
        guard case .gravado = registrar() else {
            Issue.record("esperava .gravado")
            return
        }
        #expect(try gastosDoBanco().count == 2)
    }

    @Test func gastoDeOutroUsuarioNaoEhDuplicata() throws {
        _ = viagem(de: 13, ate: 17)
        _ = gastoExistente(userId: "outro", criadoEm: agora.addingTimeInterval(-10))
        guard case .gravado = registrar() else {
            Issue.record("esperava .gravado")
            return
        }
    }

    // MARK: Recusas

    @Test func moedaEstrangeiraEhRecusada() {
        #expect(registrar(valor: "US$ 10,00") == .recusado(.moedaEstrangeira))
        #expect(registrar(valor: "€ 5") == .recusado(.moedaEstrangeira))
    }

    @Test func valorInvalidoEhRecusado() {
        #expect(registrar(valor: "abc") == .recusado(.valorInvalido))
        #expect(registrar(valor: "0") == .recusado(.valorInvalido))
        #expect(registrar(valor: "R$ 150.000,00") == .recusado(.valorInvalido))
    }

    @Test func semUsuarioEhRecusado() throws {
        let r = RegistroApplePay.registrar(
            valorTexto: "25", estabelecimento: "Padaria", userId: nil,
            em: ctx, fila: fila, agora: agora, calendario: cal)
        #expect(r == .recusado(.semUsuario))
        #expect(try gastosDoBanco().isEmpty)
        #expect(fila.ler(userId: usuario).isEmpty)
    }
}
