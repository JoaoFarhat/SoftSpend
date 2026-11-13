import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Fluxo A1 de docs/cartao-sem-open-finance.md, testado sem tela com a
/// `FakeFaturaAPI` (§2.11): consentimento, leitura, conferência nos três
/// grupos e o "Importar" que grava no servidor antes de criar gastos.
@MainActor
struct ImportarFaturaTests {
    let container: ModelContainer
    let ctx: ModelContext
    let api = FakeFaturaAPI()
    let suite = UserDefaults(suiteName: "ImportarFaturaTests-\(UUID().uuidString)")!
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
    }

    // MARK: - Fixtures

    /// Viagem 20–25/07/2026 (um dia por data), já sincronizada.
    @discardableResult
    func viagem(comGastoJaLancado: Bool = true) throws -> (ciclo: CicloSoftex, dias: [DiaSoftex]) {
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 2700, gasto_total: 0,
            periodo: "20/07 - 25/07", diaria: 450, titulo: "Cuiabá, MT", dias: []
        )
        ciclo.backendId = 100
        ciclo.syncStatus = .synced
        ctx.insert(ciclo)
        var dias: [DiaSoftex] = []
        for n in 20...25 {
            let dia = DiaSoftex(data: dia(n), saldo: 450)
            ctx.insert(dia)
            dia.ciclo = ciclo
            dias.append(dia)
        }
        if comGastoJaLancado {
            let gasto = GastosDia(valor: 150, titulo: "Padaria Sao Joao", categoria: .ALIMENTACAO, dia: dias[1])
            gasto.backendId = 7
            gasto.syncStatus = .synced
            ctx.insert(gasto)
        }
        try ctx.save()
        return (ciclo, dias)
    }

    /// 21/07, 22/07, 01/08… como o backend manda a data da compra.
    func dia(_ n: Int, mes: Int = 7) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: mes, day: n))!
    }

    func compra(
        _ indice: Int, data: Date, valor: Decimal, descricao: String,
        tipo: TipoCompraFatura = .compra, match: MatchPreviaFatura? = nil,
        dentroDaViagem: Bool = true
    ) -> CompraLida {
        CompraLida(
            indice: indice, data: data, descricao: descricao, valor: valor,
            tipo: tipo, dentroDaViagem: dentroDaViagem, match: match
        )
    }

    /// Fatura típica: já lançada, duas que faltam, estorno e uma fora.
    func faturaPadrao() -> FaturaLida {
        FaturaLida(
            emissor: "Banco Teste", finalCartao: "4321",
            vencimento: dia(5, mes: 8), totalFatura: 730,
            compras: [
                compra(0, data: dia(21), valor: 150, descricao: "PADARIA SAO JOAO",
                       match: MatchPreviaFatura(gastoId: 7, score: 90, status: "AUTO_MATCHED")),
                compra(1, data: dia(22), valor: 50, descricao: "UBER BRASIL"),
                compra(2, data: dia(23), valor: 30, descricao: "CAFE CENTRAL"),
                compra(3, data: dia(23), valor: 20, descricao: "ESTORNO LOJA", tipo: .estorno),
                compra(4, data: dia(1, mes: 8), valor: 500, descricao: "ELETRO STORE",
                       dentroDaViagem: false),
            ]
        )
    }

    /// `detalhe` do `POST /api/faturas`/`conciliar`: a compra 0 já casada com
    /// o gasto 7 (match 99), a transação da compra 1 sem vínculo ainda.
    func detalhePadrao() -> CreditCardBillDetailResponse {
        CreditCardBillDetailResponse(
            id: 42, cartaoId: 1, billId: "fatura:teste",
            dueDate: nil, closingDate: nil, totalAmount: 730,
            currencyCode: "BRL", minimumPaymentAmount: nil,
            allowsInstallments: nil,
            transacoes: [
                transacao(1, matchId: 99, gastoId: 7, status: "AUTO_MATCHED"),
                transacao(2),
            ]
        )
    }

    func transacao(_ id: Int, matchId: Int? = nil, gastoId: Int = 0,
                   status: String = "AUTO_MATCHED") -> CreditCardTransactionResponse {
        CreditCardTransactionResponse(
            id: id, cartaoId: 1, faturaId: 42, transactionId: "fatura:t\(id)",
            description: "COMPRA", descriptionRaw: "COMPRA", amount: 150,
            amountInAccountCurrency: 150, currencyCode: "BRL", date: nil,
            category: nil, status: nil, type: nil, providerCode: nil,
            providerId: nil, merchantName: nil, creditCardMetadata: nil,
            openFinanceMatch: matchId.map {
                ExpenseTransactionMatchResponse(
                    id: $0, gastoId: gastoId, cartaoTransacaoId: id,
                    providerTransactionId: nil, transactionDescription: nil,
                    transactionAmount: nil, transactionDate: nil,
                    status: status, score: 90, method: "RULES",
                    confirmedByUser: status == "CONFIRMED", matchedAt: .now
                )
            }
        )
    }

    /// ViewModel pronto: leitura por IA permitida e aviso já visto — o PDF
    /// vai direto. `criarGasto` imita o `createNewGasto` (insert + save,
    /// `.pending` por padrão) e anota o passo na linha do tempo da API.
    func viewModel(para ciclo: CicloSoftex, criandoGastos: Bool = true) -> ImportarFaturaViewModel {
        Consentimento.gravar(true, em: suite)
        Consentimento.gravarAvisoFatura(true, em: suite)
        let vm = ImportarFaturaViewModel(
            ciclo: ciclo, api: api,
            sincronizar: {},
            criarGasto: { compra, dia in
                self.api.marcar("criarGasto")
                guard criandoGastos else { return }
                let gasto = GastosDia(
                    valor: compra.valor,
                    titulo: ImportarFaturaViewModel.tituloDoGasto(compra),
                    categoria: compra.categoria,
                    dia: dia
                )
                ctx.insert(gasto)
                try ctx.save()
            },
            defaults: suite
        )
        vm.contexto = ctx
        return vm
    }

    /// Leva o VM até `.conferindo` com a fatura configurada, como se o
    /// usuário tivesse escolhido um OFX (sem consentimento).
    func conferindo(_ vm: ImportarFaturaViewModel, fatura: FaturaLida? = nil) async {
        api.lida = fatura ?? faturaPadrao()
        #expect(vm.preparar(dados: Data([1, 2, 3]), tipo: .ofx, nome: "fatura.ofx"))
        await vm.ler()
        #expect(vm.etapa == .conferindo)
    }

    func gastosLocais() throws -> [GastosDia] {
        try ctx.fetch(FetchDescriptor<GastosDia>())
    }

    // MARK: - §2.11: DTO

    @Test func dtoDecodificaParcelaEValorOriginal() throws {
        let json = """
        {
          "emissor": "Banco Teste", "final_cartao": "4321",
          "fechamento": "2026-07-25", "vencimento": "2026-08-05",
          "total_fatura": 350.0, "moeda": "BRL",
          "soma_confere": false, "diferenca": 10.5,
          "avisos": ["aviso do servidor"],
          "compras": [
            {
              "indice": 0, "data": "2026-07-21",
              "descricao": "PARCELAMENTO LOJA", "valor": 200.0,
              "parcela_atual": 2, "parcela_total": 3,
              "tipo": "COMPRA", "categoria": "OUTROS",
              "valor_original": "US$ 34,00",
              "dentro_da_viagem": true, "dia_id": 55,
              "match": {"gasto_id": 7, "score": 90, "status": "AUTO_MATCHED"}
            }
          ]
        }
        """.data(using: .utf8)!

        let lida = try JSONDecoder().decode(FaturaLida.self, from: json)

        #expect(lida.emissor == "Banco Teste")
        #expect(lida.somaConfere == false)
        #expect(lida.diferenca == Decimal(string: "10.5"))
        #expect(lida.avisos == ["aviso do servidor"])
        let c = try #require(lida.compras.first)
        #expect(c.parcelaAtual == 2 && c.parcelaTotal == 3)
        #expect(c.valorOriginal == "US$ 34,00")
        #expect(c.diaId == 55 && c.dentroDaViagem)
        #expect(c.match?.gastoId == 7 && c.match?.score == 90)
        #expect(c.match?.status == "AUTO_MATCHED")
        #expect(Calendar.current.isDate(c.data, inSameDayAs: dia(21)))
        #expect(c.textoParcela == "parcela 2 de 3")
        #expect(lida.vencimento.map {
            Calendar.current.isDate($0, inSameDayAs: dia(5, mes: 8))
        } == true)
    }

    // MARK: - §2.11: nada criado antes de "Importar"

    @Test func nadaCriadoAntesDeImportar() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)

        await conferindo(vm)

        // Só o `ler` aconteceu: nada de gravação, nada de gasto novo.
        #expect(api.chamadas == ["ler"])
        #expect(api.enviada == nil)
        #expect(try gastosLocais().count == 1) // só o já lançado da fixture

        // "Faltam" nasce toda desmarcada.
        #expect(vm.faltam.count == 2)
        #expect(vm.faltam.allSatisfy { !$0.marcada })
    }

    @Test func gruposSeparados() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        await conferindo(vm)

        #expect(vm.jaLancadas.map(\.id) == [0])
        #expect(vm.faltam.map(\.id) == [1, 2])
        #expect(vm.estornosEEncargos.map(\.id) == [3])
        #expect(vm.foraDaViagem.map(\.id) == [4])
    }

    // MARK: - §2.11: só as marcadas viram gasto

    @Test func soMarcadasViramGastoNoDiaCertoEPending() async throws {
        let (ciclo, dias) = try viagem()
        let vm = viewModel(para: ciclo)
        await conferindo(vm)

        // Marca só a compra 1 (a 2 fica de fora), desvincula a 0 para o
        // teste do DELETE e depois revincula para não atrapalhar.
        vm.alternarMarcada(1)

        api.detalhe = detalhePadrao()
        await vm.importar()

        #expect(vm.etapa == .pronto)
        // Servidor primeiro, gasto depois, conciliação no fim.
        #expect(api.chamadas == ["ler", "gravar", "criarGasto", "conciliar"])

        // As compras mantidas são as da viagem (0–3); a de fora não vai.
        let enviada = try #require(api.enviada)
        #expect(enviada.compras.map(\.indice) == [0, 1, 2, 3])

        // Só a marcada virou gasto, no DiaSoftex de 22/07, ainda `.pending`.
        let novos = try gastosLocais().filter { $0.backendId == nil }
        #expect(novos.count == 1)
        let gasto = try #require(novos.first)
        #expect(gasto.dia?.id == dias[2].id)
        #expect(gasto.valor == 50)
        #expect(gasto.syncStatus == .pending)
        #expect(gasto.titulo == "Uber Brasil")

        // O match que o servidor confirmou chegou ao gasto já lançado.
        let antigo = try #require(gastosLocais().first { $0.backendId == 7 })
        #expect(antigo.openFinanceStatus == .autoMatched)
        #expect(antigo.openFinanceMatchBackendId == 99)
    }

    @Test func marcarTodasSelecionaTodasAsFaltam() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        await conferindo(vm)

        vm.marcarTodas()
        #expect(vm.faltam.allSatisfy { $0.marcada })
        // Estorno não entra no "marcar todas" (nem é selecionável).
        #expect(vm.estornosEEncargos.count == 1)

        await vm.importar()
        #expect(try gastosLocais().filter { $0.backendId == nil }.count == 2)
    }

    // MARK: - §2.11: desvincular / confirmar na conferência

    @Test func desvincularRepeteDeleteNoServidor() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        await conferindo(vm)
        api.detalhe = detalhePadrao()

        vm.desvincular(0)
        // A compra desce para "Faltam", desmarcada.
        #expect(vm.jaLancadas.isEmpty)
        #expect(vm.faltam.map(\.id) == [0, 1, 2])

        await vm.importar()

        // Continua enviada (ficou na conferência), e o match sai do servidor.
        #expect(api.enviada?.compras.map(\.indice).contains(0) == true)
        #expect(api.removidos == [99])
        let antigo = try #require(gastosLocais().first { $0.backendId == 7 })
        #expect(antigo.openFinanceStatus == .pendente)
    }

    @Test func confirmarRepeteConfirmNoServidor() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        var fatura = faturaPadrao()
        fatura.compras[0].match = MatchPreviaFatura(gastoId: 7, score: 55, status: "REVIEW")
        await conferindo(vm, fatura: fatura)
        api.detalhe = detalhePadrao()

        vm.confirmar(0)
        await vm.importar()

        #expect(api.confirmados == [99])
        let antigo = try #require(gastosLocais().first { $0.backendId == 7 })
        #expect(antigo.openFinanceStatus == .confirmed)
    }

    // MARK: - §2.11: consentimento

    @Test func consentimentoRecusadoNaoChamaServidor() throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        Consentimento.gravar(nil, em: suite) // nunca perguntado

        #expect(!vm.preparar(dados: Data([1, 2]), tipo: .pdf, nome: "fatura.pdf"))
        #expect(vm.etapa == .consentindo(.pergunta))
        #expect(api.chamadas.isEmpty)

        #expect(!vm.decidirConsentimento(false))
        guard case .erro = vm.etapa else {
            Issue.record("Esperava .erro depois da recusa")
            return
        }
        #expect(api.chamadas.isEmpty)
    }

    @Test func primeiraImportacaoMostraAvisoFatura() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        Consentimento.gravarAvisoFatura(false, em: suite)
        api.lida = faturaPadrao()

        // Já permitiu a leitura, mas a primeira fatura mostra o aviso (§2.8).
        #expect(!vm.preparar(dados: Data([1, 2]), tipo: .pdf, nome: "fatura.pdf"))
        #expect(vm.etapa == .consentindo(.avisoFatura))
        #expect(api.chamadas.isEmpty)

        vm.continuarAvisoFatura()
        await vm.ler()
        #expect(Consentimento.avisoFatura(em: suite))
        #expect(api.chamadas == ["ler"])
        #expect(vm.etapa == .conferindo)
    }

    @Test func ofxECsvPassamSemConsentimento() throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        Consentimento.gravar(false, em: suite) // leitura por IA desligada

        #expect(vm.preparar(dados: Data([1]), tipo: .ofx, nome: "fatura.ofx"))
        #expect(vm.preparar(dados: Data([1]), tipo: .csv, nome: "fatura.csv"))
    }

    // MARK: - §2.11: arquivo barrado no aparelho

    @Test func tipoErradoBarradoAntesDoEnvio() throws {
        #expect(throws: ArquivoFatura.Erro.tipoInvalido) {
            try ArquivoFatura.validar(dados: Data([1]), nomeArquivo: "foto.jpg")
        }
        #expect(throws: ArquivoFatura.Erro.vazio) {
            try ArquivoFatura.validar(dados: Data(), nomeArquivo: "fatura.pdf")
        }
    }

    @Test func arquivoGrandeBarradoAntesDoEnvio() throws {
        let pdfGrande = Data(count: ArquivoFatura.tamanhoMaximoPDF + 1)
        #expect(throws: ArquivoFatura.Erro.muitoGrande(limiteMB: 10)) {
            try ArquivoFatura.validar(dados: pdfGrande, nomeArquivo: "fatura.pdf")
        }
        let ofxGrande = Data(count: ArquivoFatura.tamanhoMaximoTexto + 1)
        #expect(throws: ArquivoFatura.Erro.muitoGrande(limiteMB: 2)) {
            try ArquivoFatura.validar(dados: ofxGrande, nomeArquivo: "fatura.ofx")
        }
        // No limite passa; um byte a menos também.
        #expect(try ArquivoFatura.validar(
            dados: Data(count: ArquivoFatura.tamanhoMaximoPDF),
            nomeArquivo: "fatura.pdf"
        ) == .pdf)
    }

    // MARK: - §2.11: erros da leitura

    @Test func erro422DeSenhaPedeSenhaERepete() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        api.lida = faturaPadrao()
        api.erroAoLer = APIError.serverError(
            message: "PDF protegido por senha; informe a senha",
            requestId: "-", statusCode: 422
        )

        #expect(vm.preparar(dados: Data([1]), tipo: .pdf, nome: "fatura.pdf"))
        await vm.ler()
        #expect(vm.etapa == .pedindoSenha)
        #expect(!vm.senhaIncorreta)

        // Senha errada: o servidor reclama de novo, o aviso aparece.
        api.erroAoLer = APIError.serverError(
            message: "Senha incorreta", requestId: "-", statusCode: 422
        )
        vm.senha = "errada"
        await vm.ler()
        #expect(vm.etapa == .pedindoSenha)
        #expect(vm.senhaIncorreta)
        #expect(api.senhas.last == "errada")

        // Senha certa: segue para a conferência.
        api.erroAoLer = nil
        vm.senha = "certa"
        await vm.ler()
        #expect(vm.etapa == .conferindo)
        #expect(api.senhas == [nil, "errada", "certa"])
    }

    @Test func erro503ViraLeituraIndisponivel() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        api.erroAoLer = APIError.serverError(
            message: "IA indisponível", requestId: "-", statusCode: 503
        )
        #expect(vm.preparar(dados: Data([1]), tipo: .pdf, nome: "fatura.pdf"))
        await vm.ler()
        guard case .erro(let mensagem) = vm.etapa else {
            Issue.record("Esperava .erro no 503")
            return
        }
        #expect(mensagem.localizedCaseInsensitiveContains("indisponível"))
    }

    @Test func somaConfereFalsoAvvisa() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        var fatura = faturaPadrao()
        fatura = FaturaLida(
            somaConfere: false, diferenca: 20,
            avisos: ["servidor avisou de truncamento"],
            compras: fatura.compras
        )
        await conferindo(vm, fatura: fatura)
        #expect(vm.fatura?.somaConfere == false)
        #expect(vm.fatura?.avisos == ["servidor avisou de truncamento"])
    }

    @Test func gastoPendenteAntesDaLeituraGeraAviso() async throws {
        let (ciclo, dias) = try viagem()
        // Um gasto ainda não enviado: pode aparecer como "faltam" (§2.5).
        let pendente = GastosDia(valor: 10, titulo: "Snack", categoria: .ALIMENTACAO, dia: dias[0])
        ctx.insert(pendente)
        try ctx.save()

        let vm = viewModel(para: ciclo)
        await conferindo(vm)
        let aviso = try #require(vm.avisoPendentes)
        #expect(aviso.contains("1 gasto"))
    }

    // MARK: - §2.11: falha na gravação não cria gasto

    @Test func falhaNaGravacaoNaoCriaNenhumGasto() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        await conferindo(vm)
        vm.marcarTodas()
        api.erroAoGravar = APIError.serverError(
            message: "Falha simulada", requestId: "-", statusCode: 500
        )

        await vm.importar()

        guard case .erro = vm.etapa else {
            Issue.record("Esperava .erro na gravação")
            return
        }
        #expect(api.chamadas == ["ler", "gravar"]) // sem criarGasto, sem conciliar
        #expect(try gastosLocais().filter { $0.backendId == nil }.isEmpty)
    }

    @Test func cicloIdVaiNaLeitura() async throws {
        let (ciclo, _) = try viagem()
        let vm = viewModel(para: ciclo)
        await conferindo(vm)
        #expect(api.cicloIds == [100])
    }
}
