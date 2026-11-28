import Testing
import Foundation
import CoreData
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
}
