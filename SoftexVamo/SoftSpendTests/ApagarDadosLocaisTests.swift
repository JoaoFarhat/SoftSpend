import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Limpeza local na exclusão de conta (docs/publicacao.md §2, "Exclusão de
/// conta pelo app"): só depois do `DELETE /auth/conta` dar certo, o
/// `AuthService` apaga do aparelho tudo que é do `userId` — ciclos (a
/// cascata leva dias, gastos e os comprovantes criptografados), `UserModel`,
/// dados do Open Finance e os arquivos JSON do Apple Pay (fila e cartões).
/// Os dados dos outros usuários do aparelho ficam.
@MainActor
struct ApagarDadosLocaisTests {
    let container: ModelContainer
    let ctx: ModelContext
    let fila: ComprasAguardandoViagem
    let cartoes: CartoesApplePay
    let userId = "u1"
    let outroUserId = "u2"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self, UserModel.self,
                 CartaoOpenFinance.self, FaturaCartao.self, TransacaoCartao.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        let dir = FileManager.default.temporaryDirectory
        fila = ComprasAguardandoViagem(
            arquivo: dir.appendingPathComponent("fila-\(UUID().uuidString).json"))
        cartoes = CartoesApplePay(
            arquivo: dir.appendingPathComponent("cartoes-\(UUID().uuidString).json"))
    }

    /// Ciclo → dia → gasto do usuário, com um comprovante criptografado no
    /// gasto (o blob mora na linha do gasto e sai pela cascata).
    private func semearViagem(userId: String) throws {
        let ciclo = CicloSoftex(userId: userId, valor_total: 700, gasto_total: 30,
                              periodo: "13/11 - 15/11", diaria: 100, titulo: "Cuiabá, MT")
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 70)
        dia.ciclo = ciclo
        ctx.insert(dia)
        let gasto = GastosDia(valor: 30, titulo: "Padaria", categoria: .ALIMENTACAO, dia: dia)
        gasto.comprovanteDataCriptografado = Data([0x01, 0x02, 0x03])
        ctx.insert(gasto)
        try ctx.save()
    }

    private func semearOpenFinance(userId: String, backendIdBase: Int) throws {
        let cartao = CartaoOpenFinance(backendId: backendIdBase, userId: userId,
                                       conexaoBackendId: 1, accountId: "acc")
        ctx.insert(cartao)
        let fatura = FaturaCartao(backendId: backendIdBase + 1, userId: userId,
                                  billId: "bill", cartao: cartao)
        ctx.insert(fatura)
        ctx.insert(TransacaoCartao(backendId: backendIdBase + 2, userId: userId,
                                   transactionId: "tx", cartao: cartao, fatura: fatura))
        try ctx.save()
    }

    private func contagens() throws -> (ciclos: Int, dias: Int, gastos: Int) {
        (
            try ctx.fetchCount(FetchDescriptor<CicloSoftex>()),
            try ctx.fetchCount(FetchDescriptor<DiaSoftex>()),
            try ctx.fetchCount(FetchDescriptor<GastosDia>())
        )
    }

    @Test func apagaCiclosDiasGastosUsuarioEMantemOutro() throws {
        try semearViagem(userId: userId)
        try semearViagem(userId: outroUserId)
        ctx.insert(UserModel(id: userId, nome: "Um", username: "um", email: "u@x.com"))
        ctx.insert(UserModel(id: outroUserId, nome: "Dois", username: "dois", email: "d@x.com"))
        try semearOpenFinance(userId: userId, backendIdBase: 1_000)
        try semearOpenFinance(userId: outroUserId, backendIdBase: 2_000)

        try ApagarDadosLocais.apagar(userId: userId, contexto: ctx,
                                     fila: fila, cartoes: cartoes)

        // Tudo que sobrou no banco é do outro usuário.
        let (ciclos, dias, gastos) = try contagens()
        #expect(ciclos == 1 && dias == 1 && gastos == 1)
        let cicloRestante = try #require(ctx.fetch(FetchDescriptor<CicloSoftex>()).first)
        #expect(cicloRestante.userId == outroUserId)
        #expect(cicloRestante.dias?.first?.gastos.count == 1)

        // O UserModel dela sai; o do outro fica.
        let usuarios = try ctx.fetch(FetchDescriptor<UserModel>())
        #expect(usuarios.map(\.id) == [outroUserId])

        // Dados do Open Finance dela também saem, mesmo com o módulo desligado.
        #expect(try ctx.fetchCount(FetchDescriptor<CartaoOpenFinance>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<FaturaCartao>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<TransacaoCartao>()) == 1)
        #expect(try ctx.fetch(FetchDescriptor<CartaoOpenFinance>()).first?.userId == outroUserId)
    }

    @Test func filaECartoesSoDoUsuarioSaem() throws {
        for (i, uid) in [userId, outroUserId].enumerated() {
            try fila.adicionar(CompraAguardandoViagem(
                id: UUID(), userId: uid, valor: Decimal(10 + i),
                estabelecimento: "Padaria", cartao: nil, categoria: .OUTROS,
                recebidaEm: .now))
            try cartoes.registrarChegada(nome: "Cartão \(uid)", userId: uid)
        }

        try ApagarDadosLocais.apagar(userId: userId, contexto: ctx,
                                     fila: fila, cartoes: cartoes)

        #expect(fila.ler(userId: userId).isEmpty)
        #expect(cartoes.ler(userId: userId).isEmpty)
        #expect(fila.ler(userId: outroUserId).count == 1)
        #expect(cartoes.ler(userId: outroUserId).count == 1)
        // O arquivo em si continua com os itens do outro usuário.
        #expect(fila.todas().count == 1)
        #expect(cartoes.todos().count == 1)
    }

    /// DELETE falhou (rede, 5xx, 401): a limpeza local não roda — nada do
    /// aparelho sai e a sessão continua de pé para o usuário tentar de novo.
    @Test func deleteFalhandoNaoApagaNadaLocal() async throws {
        try semearViagem(userId: userId)

        var chamadas: [String] = []
        let service = AuthService()
        service.currentUser = UserModel(id: userId, nome: "Um", username: "um", email: "u@x.com")
        service.isAuthenticated = true
        service.deletarContaNoServidor = {
            throw APIError.serverError(message: "falhou", requestId: "-", statusCode: 500)
        }
        service.apagarDadosLocais = { chamadas.append($0) }

        await service.deleteAccount()

        #expect(chamadas.isEmpty)
        #expect(try contagens() == (1, 1, 1))
        #expect(service.isAuthenticated)
        #expect(service.currentUser?.id == userId)
        #expect(service.errorMessage == "falhou")
        #expect(service.isLoading == false)
    }

    /// DELETE deu certo: a limpeza roda com o `userId` da sessão **antes** do
    /// logout apagar `currentUser`, e a sessão fecha no fim.
    @Test func deleteCertoLimpaAntesDoLogout() async throws {
        var chamadas: [String] = []
        let service = AuthService()
        service.currentUser = UserModel(id: userId, nome: "Um", username: "um", email: "u@x.com")
        service.isAuthenticated = true
        service.deletarContaNoServidor = {}
        service.apagarDadosLocais = { chamadas.append($0) }

        await service.deleteAccount()

        #expect(chamadas == [userId])
        #expect(service.currentUser == nil)
        #expect(service.isAuthenticated == false)
        #expect(service.errorMessage == nil)
        #expect(service.isLoading == false)
    }
}
