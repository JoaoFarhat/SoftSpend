import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Regra do registro de gasto pelo atalho do Apple Pay (§1.4 e §1.9 de
/// docs/cartao-sem-open-finance.md): banco em memória, `agora`, `calendario`
/// e fila injetados.
@MainActor
struct RegistroApplePayTests {
    let container: ModelContainer
    let ctx: ModelContext
    let fila: ComprasAguardandoViagem
    let cal: Calendar
    let agora: Date
    let hoje: Date
    let userId = "u1"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        let arquivo = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-\(UUID().uuidString).json")
        fila = ComprasAguardandoViagem(arquivo: arquivo)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Cuiaba")!
        cal = c
        agora = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15))!
        hoje = cal.startOfDay(for: agora)
    }

    // MARK: Apoio

    /// Viagem do usuário com dias nas datas dadas (o intervalo sai dos dias).
    @discardableResult
    func viagem(userId: String? = nil, titulo: String = "Cuiabá, MT",
                dias datas: [Date], periodo: String = "13/11 - 15/11") -> CicloSoftex {
        let ciclo = CicloSoftex(userId: userId ?? self.userId, valor_total: 700,
                                gasto_total: 0, periodo: periodo, diaria: 100,
                                titulo: titulo, dias: [])
        ciclo.criadoEm = agora  // `periodo` é lido no ano em que o ciclo foi criado.
        ctx.insert(ciclo)
        for d in datas {
            let dia = DiaSoftex(data: d, saldo: 100)
            dia.ciclo = ciclo
            ctx.insert(dia)
        }
        try? ctx.save()
        return ciclo
    }

    func diaDeHoje(_ ciclo: CicloSoftex) -> DiaSoftex? {
        (ciclo.dias ?? []).first { cal.isDate($0.data, inSameDayAs: hoje) }
    }

    @discardableResult
    func gasto(valor: Decimal, titulo: String, em dia: DiaSoftex,
               criadoEm: Date) -> GastosDia {
        let g = GastosDia(valor: valor, titulo: titulo, categoria: .OUTROS, dia: dia)
        g.criadoEm = criadoEm
        ctx.insert(g)
        try? ctx.save()
        return g
    }

    func registrar(_ valor: String = "12,34", _ estabelecimento: String = "Padaria",
                   userId: String? = "u1") throws -> ResultadoRegistro {
        try RegistroApplePay.registrar(valor: valor, estabelecimento: estabelecimento,
                                       userId: userId, em: ctx, fila: fila,
                                       agora: agora, calendario: cal)
    }

    func gastosNoBanco() throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    func dia(_ n: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: n))!
    }

    // MARK: Gravação

    @Test func gravaNoDiaDeHojeESomaNoTotal() throws {
        let ciclo = viagem(dias: [hoje, dia(14)])
        let diaHoje = try #require(diaDeHoje(ciclo))

        let r = try registrar("R$ 12,34", "PADARIA PÃO QUENTE")

        #expect(r == .gravado(titulo: "Padaria Pão Quente", valor: Decimal(string: "12.34")!,
                              viagem: "Cuiabá, MT", dia: diaHoje.data))
        let gastos = try gastosNoBanco()
        try #require(gastos.count == 1)
        let g = gastos[0]
        #expect(g.dia === diaHoje)
        #expect(g.titulo == "Padaria Pão Quente")
        #expect(g.valor == Decimal(string: "12.34"))
        #expect(g.syncStatus == .pending)
        #expect(ciclo.gasto_total == Decimal(string: "12.34"))
    }

    @Test func naoDuplicaARelacaoDiaGastos() throws {
        let ciclo = viagem(dias: [hoje])
        let diaHoje = try #require(diaDeHoje(ciclo))

        _ = try registrar()
        try #require(diaHoje.gastos.count == 1)

        _ = try registrar("50,00", "Outro lugar")
        // Pegadinha 3 do AGENTS.md: sem append manual na relação inversa.
        #expect(diaHoje.gastos.count == 2)
        #expect(try gastosNoBanco().count == 2)
    }

    @Test func categoriaSugerida() throws {
        _ = viagem(dias: [hoje])
        _ = try registrar("30,00", "Uber")
        _ = try registrar("40,00", "Cinemark")
        _ = try registrar("10,00", "Estabelecimento Sem Nome Conhecido")

        let gastos = try gastosNoBanco()
        #expect(gastos.first { $0.titulo == "Uber" }?.categoria == .TRANSPORTE)
        #expect(gastos.first { $0.titulo == "Cinemark" }?.categoria == .LAZER)
        #expect(gastos.first { $0.categoria == .OUTROS } != nil)
    }

    @Test func estabelecimentoVazioViraCompraNoCartao() throws {
        _ = viagem(dias: [hoje])
        _ = try registrar("10,00", "   ")
        let gastos = try gastosNoBanco()
        #expect(gastos.first?.titulo == "Compra no cartão")
    }

    @Test func tituloCortadoEm60Caracteres() throws {
        _ = viagem(dias: [hoje])
        _ = try registrar("10,00", String(repeating: "A", count: 80))
        let gastos = try gastosNoBanco()
        #expect(gastos.first?.titulo.count == 60)
    }

    // MARK: Qual viagem conta

    @Test func viagemEncerradaNaoConta() throws {
        _ = viagem(dias: [dia(1), dia(5)])
        let r = try registrar()
        #expect(r == .guardadoSemViagem(titulo: "Padaria", valor: Decimal(string: "12.34")!))
        #expect(fila.ler(userId: userId).count == 1)
        #expect(try gastosNoBanco().isEmpty)
    }

    @Test func viagemFuturaNaoConta() throws {
        _ = viagem(dias: [dia(20), dia(25)])
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria", valor: Decimal(string: "12.34")!))
        #expect(fila.ler(userId: userId).count == 1)
    }

    @Test func viagemApagadaNaoConta() throws {
        let ciclo = viagem(dias: [hoje])
        ciclo.deletadoEm = agora
        try ctx.save()
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria", valor: Decimal(string: "12.34")!))
        #expect(try gastosNoBanco().isEmpty)
    }

    @Test func viagemDeOutroUsuarioNaoConta() throws {
        _ = viagem(userId: "u2", dias: [hoje])
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria", valor: Decimal(string: "12.34")!))
        #expect(fila.ler(userId: userId).count == 1)
        #expect(try gastosNoBanco().isEmpty)
    }

    @Test func sobreposicaoUsaADePrimeiroDiaMaisRecente() throws {
        let antiga = viagem(titulo: "Antiga", dias: [dia(10), hoje])
        let recente = viagem(titulo: "Recente", dias: [dia(12), hoje])

        let r = try registrar()
        guard case .gravado(_, _, let viagem, _) = r else {
            Issue.record("esperava .gravado, veio \(r)")
            return
        }
        #expect(viagem == "Recente")
        let diaHoje = try #require(diaDeHoje(recente))
        #expect(diaHoje.gastos.count == 1)
        #expect(recente.gasto_total == Decimal(string: "12.34"))
        #expect(antiga.gasto_total == 0)
    }

    @Test func semViagemVaiParaFila() throws {
        let r = try RegistroApplePay.registrar(valor: "12,34", estabelecimento: "Padaria",
                                               cartao: "Nubank", userId: userId,
                                               em: ctx, fila: fila, agora: agora, calendario: cal)
        #expect(r == .guardadoSemViagem(titulo: "Padaria", valor: Decimal(string: "12.34")!))
        let itens = fila.ler(userId: userId)
        try #require(itens.count == 1)
        let item = itens[0]
        #expect(item.userId == userId)
        #expect(item.valor == Decimal(string: "12.34"))
        #expect(item.estabelecimento == "Padaria")
        #expect(item.cartao == "Nubank")
        #expect(item.categoria == .ALIMENTACAO)  // "padaria" está nas palavras de alimentação do InterpretadorComprovante
        #expect(item.recebidaEm == agora)
        #expect(try gastosNoBanco().isEmpty)
    }

    @Test func viagemSemDiaLocalDeHojeVaiParaFila() throws {
        // Intervalo pelo `periodo` (sem nenhum dia local — instalação nova que
        // ainda não baixou os dias): contém hoje, mas não há DiaSoftex de hoje.
        _ = viagem(dias: [], periodo: "10/11 - 15/11")
        #expect(try registrar() == .guardadoSemViagem(titulo: "Padaria", valor: Decimal(string: "12.34")!))
        #expect(fila.ler(userId: userId).count == 1)
    }

    // MARK: Duplicata (janela deslizante de 60 s)

    @Test func duplicataEm30sEhBarrada() throws {
        let ciclo = viagem(dias: [hoje])
        let diaHoje = try #require(diaDeHoje(ciclo))
        gasto(valor: Decimal(string: "12.34")!, titulo: "Padaria", em: diaHoje,
              criadoEm: agora.addingTimeInterval(-30))

        #expect(try registrar() == .duplicado)
        #expect(try gastosNoBanco().count == 1)
        #expect(ciclo.gasto_total == 0)
    }

    @Test func compraEm61sGrava() throws {
        let ciclo = viagem(dias: [hoje])
        let diaHoje = try #require(diaDeHoje(ciclo))
        gasto(valor: Decimal(string: "12.34")!, titulo: "Padaria", em: diaHoje,
              criadoEm: agora.addingTimeInterval(-61))

        #expect(try registrar() != .duplicado)
        #expect(try gastosNoBanco().count == 2)
    }

    @Test func duplicataComTituloEmOutraCaixaEAcento() throws {
        let ciclo = viagem(dias: [hoje])
        let diaHoje = try #require(diaDeHoje(ciclo))
        gasto(valor: Decimal(string: "12.34")!, titulo: "Café São Braz", em: diaHoje, criadoEm: agora)

        // Caixa diferente, sem acento e com espaço repetido: é a mesma compra.
        #expect(try registrar("12,34", "CAFE SAO  BRAZ") == .duplicado)
    }

    @Test func valorDiferenteNaoEhDuplicata() throws {
        let ciclo = viagem(dias: [hoje])
        let diaHoje = try #require(diaDeHoje(ciclo))
        gasto(valor: Decimal(string: "12.35")!, titulo: "Padaria", em: diaHoje, criadoEm: agora)

        #expect(try registrar("12,34") != .duplicado)
        #expect(try gastosNoBanco().count == 2)
    }

    @Test func duplicataContraItemDaFila() throws {
        fila.adicionar(CompraAguardandoViagem(
            id: UUID(), userId: userId, valor: Decimal(string: "12.34")!, estabelecimento: "Padaria",
            cartao: nil, categoria: .OUTROS, recebidaEm: agora.addingTimeInterval(-30)))

        #expect(try registrar() == .duplicado)
        #expect(fila.ler(userId: userId).count == 1)
        #expect(try gastosNoBanco().isEmpty)
    }

    @Test func gastoApagadoNaoContaParaDuplicata() throws {
        let ciclo = viagem(dias: [hoje])
        let diaHoje = try #require(diaDeHoje(ciclo))
        let morto = gasto(valor: Decimal(string: "12.34")!, titulo: "Padaria", em: diaHoje, criadoEm: agora)
        morto.deletadoEm = agora
        try ctx.save()

        #expect(try registrar() != .duplicado)
        #expect(try gastosNoBanco().count == 2)
    }

    @Test func duplicataDeOutroUsuarioNaoConta() throws {
        _ = viagem(dias: [hoje])
        let cicloDeOutro = viagem(userId: "u2", titulo: "Outro", dias: [hoje])
        let diaDeOutro = try #require(diaDeHoje(cicloDeOutro))
        gasto(valor: Decimal(string: "12.34")!, titulo: "Padaria", em: diaDeOutro, criadoEm: agora)

        #expect(try registrar() != .duplicado)
    }

    // MARK: Destino do "Lançar em …" da folha da fila (§1.5)

    @Test func destinoEhODiaDaCompraNaViagemQueAContem() throws {
        let ciclo = viagem(dias: [dia(10), dia(11), dia(12)])
        let quando = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
        let d = try #require(RegistroApplePay.viagemEDia(para: quando, userId: userId,
                                                       ciclos: [ciclo], calendario: cal))
        #expect(d.ciclo === ciclo)
        #expect(cal.isDate(d.dia.data, inSameDayAs: dia(11)))
    }

    @Test func destinoNilSemViagemNaData() {
        let ciclo = viagem(dias: [dia(10), dia(11)])
        #expect(RegistroApplePay.viagemEDia(para: dia(20), userId: userId,
                                          ciclos: [ciclo], calendario: cal) == nil)
    }

    @Test func destinoNilQuandoODiaDaCompraEstaApagado() throws {
        let ciclo = viagem(dias: [dia(10), dia(11), dia(12)])
        let dia11 = try #require((ciclo.dias ?? []).first {
            cal.isDate($0.data, inSameDayAs: dia(11))
        })
        dia11.deletadoEm = agora
        try ctx.save()
        // O intervalo ainda cobre 11/11 (dias 10 e 12 vivos), mas não há
        // DiaSoftex vivo da data para receber o gasto.
        #expect(RegistroApplePay.viagemEDia(para: dia(11), userId: userId,
                                          ciclos: [ciclo], calendario: cal) == nil)
    }

    @Test func destinoIgnoraViagemApagadaEDeOutroUsuario() throws {
        let apagada = viagem(dias: [dia(11)])
        apagada.deletadoEm = agora
        let deOutro = viagem(userId: "u2", dias: [dia(11)])
        try ctx.save()
        #expect(RegistroApplePay.viagemEDia(para: dia(11), userId: userId,
                                          ciclos: [apagada, deOutro], calendario: cal) == nil)
    }

    @Test func destinoEmSobreposicaoUsaAPrimeiroDiaMaisRecente() throws {
        let antiga = viagem(titulo: "Antiga", dias: [dia(10), dia(11), dia(12)])
        let recente = viagem(titulo: "Recente", dias: [dia(11), dia(12)])
        let d = try #require(RegistroApplePay.viagemEDia(para: dia(11), userId: userId,
                                                       ciclos: [antiga, recente], calendario: cal))
        #expect(d.ciclo === recente)
    }

    // MARK: Recusas

    @Test func valorInvalido() throws {
        _ = viagem(dias: [hoje])
        #expect(try registrar("abc") == .recusado(.valorInvalido))
        #expect(try gastosNoBanco().isEmpty)
    }

    @Test func moedaEstrangeira() throws {
        _ = viagem(dias: [hoje])
        #expect(try registrar("US$ 10,00") == .recusado(.moedaEstrangeira))
        #expect(try gastosNoBanco().isEmpty)
        #expect(fila.ler(userId: userId).isEmpty)
    }

    @Test func semUsuarioRecusaENaoGrava() throws {
        _ = viagem(dias: [hoje])
        #expect(try registrar(userId: nil) == .recusado(.semUsuario))
        #expect(try gastosNoBanco().isEmpty)
        #expect(fila.ler(userId: userId).isEmpty)
    }
}
