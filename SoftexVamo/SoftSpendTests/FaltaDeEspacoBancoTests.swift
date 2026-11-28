import Testing
import Foundation
import CoreData
import SwiftData
@testable import SoftSpend

/// `BancoLocal.acaoAposFalhaDeAbertura` decide pelo erro que derrubou a
/// abertura do `ModelContainer`: falta de espaço não move arquivo nenhum
/// (o banco abre só em memória e o app avisa para liberar espaço — o
/// `.sqlite` com o que ainda não subiu fica intacto); qualquer outro erro
/// segue como sempre, para a quarentena.
struct FaltaDeEspacoBancoTests {
    @Test func arquivoSemEspaco() {
        // 640 = NSFileWriteOutOfSpaceError: escrita recusada por disco cheio.
        let erro = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .emMemoriaSemEspaco)
    }

    @Test func sqliteCheio() {
        // 13 = SQLITE_FULL, a forma que o Core Data dá ao erro do SQLite.
        let erro = NSError(domain: NSSQLiteErrorDomain, code: 13)
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .emMemoriaSemEspaco)
    }

    @Test func enospc() {
        // ENOSPC (28): a mesma falta de espaço um andar abaixo, em POSIX.
        let erro = NSError(domain: NSPOSIXErrorDomain, code: 28)
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .emMemoriaSemEspaco)
    }

    @Test func espacoEmErroSubjacente() {
        // O erro real do `ModelContainer` costuma embrulhar o SQLITE_FULL em
        // `NSUnderlyingErrorKey` dentro de um erro maior do Core Data.
        let sqlite = NSError(domain: NSSQLiteErrorDomain, code: 13)
        let erro = NSError(domain: NSCocoaErrorDomain, code: 256,
                           userInfo: [NSUnderlyingErrorKey: sqlite])
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .emMemoriaSemEspaco)
    }

    @Test func bancoIncompativelMoveParaQuarentena() {
        // 134100 = NSPersistentStoreIncompatibleVersionHashError, o erro
        // típico de banco de build antiga que não bate com o plano.
        let erro = NSError(domain: NSCocoaErrorDomain, code: 134100)
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .quarentena)
    }

    @Test func sqliteOcupadoMoveParaQuarentena() {
        // SQLITE_BUSY (5) não é falta de espaço.
        let erro = NSError(domain: NSSQLiteErrorDomain, code: 5)
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .quarentena)
    }

    @Test func erroQualquerMoveParaQuarentena() {
        let erro = NSError(domain: "dominio.qualquer", code: 42)
        #expect(BancoLocal.acaoAposFalhaDeAbertura(erro) == .quarentena)
    }

    @Test func textoDoAviso() {
        #expect(BancoLocal.avisoSemEspaco == "Sem espaço no iPhone; libere espaço e abra de novo")
    }

    /// O atalho do Apple Pay não grava nada com o banco só em memória (o
    /// gasto sumiria ao fechar o app e a resposta "registrado" enganaria a
    /// pessoa): `true` devolve a resposta honesta, `false` segue o fluxo
    /// normal.
    @Test func atalhoRecusaQuandoSemEspaco() {
        #expect(RegistrarGastoIntent.respostaSemEspaco(semEspaco: true)
            == "Sem espaço no iPhone; libere espaço e lance no app.")
    }

    @Test func atalhoSegueNormalComEspaco() {
        #expect(RegistrarGastoIntent.respostaSemEspaco(semEspaco: false) == nil)
    }
}

/// "Lançar em …" da folha das compras sem viagem com o iPhone sem espaço
/// (`BancoLocal.semEspacoNoDisco`, banco aberto só em memória):
/// `RegistroApplePay.lancar` recusa com `ErroRegistro.semEspaco` **antes**
/// de gravar — o gasto não entra no contexto e a compra fica na fila para
/// ser lançada depois; gravar perderia os dois ao fechar o app. Com espaço,
/// grava e tira da fila como sempre. Fila em arquivo temporário por teste.
@MainActor
struct LancarSemEspacoTests {
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

    /// Viagem viva com um dia, para o "Lançar em …" ter destino.
    func diaDeViagem() throws -> DiaSoftex {
        let ciclo = CicloSoftex(userId: userId, valor_total: 700, gasto_total: 0,
                                periodo: "13/11 - 15/11", diaria: 100, titulo: "Cuiabá, MT")
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: .now, saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()
        return dia
    }

    /// Compra gravada na fila temporária, como a folha entrega.
    func compraNaFila() throws -> CompraAguardandoViagem {
        let item = CompraAguardandoViagem(id: UUID(), userId: userId, valor: 30,
                                          estabelecimento: "Padaria", cartao: nil,
                                          categoria: .OUTROS, recebidaEm: .now)
        try fila.adicionar(item)
        return item
    }

    /// Sem espaço: `ErroRegistro.semEspaco` antes do save — nenhum gasto no
    /// contexto, total da viagem intacto e a compra continua na fila.
    @Test func semEspacoNaoGravaNemTiraDaFila() throws {
        let dia = try diaDeViagem()
        let item = try compraNaFila()

        #expect(throws: ErroRegistro.semEspaco) {
            try RegistroApplePay.lancar(item, em: dia, contexto: ctx, fila: fila,
                                        semEspaco: true)
        }
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
        #expect(dia.ciclo?.gasto_total == 0)
        #expect(fila.ler(userId: userId) == [item])
    }

    /// Com espaço (o caso de sempre): o gasto entra no dia e a compra sai da fila.
    @Test func comEspacoGravaETiraDaFila() throws {
        let dia = try diaDeViagem()
        let item = try compraNaFila()

        try RegistroApplePay.lancar(item, em: dia, contexto: ctx, fila: fila,
                                    semEspaco: false)

        let gastos = try ctx.fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        #expect(gastos[0].valor == 30)
        #expect(gastos[0].dia === dia)
        #expect(dia.ciclo?.gasto_total == 30)
        #expect(fila.ler(userId: userId).isEmpty)
    }
}
