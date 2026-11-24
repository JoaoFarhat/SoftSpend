import Testing
import Foundation
import CryptoKit
import Security
import SwiftData
@testable import SoftSpend

/// Keychain em memória para os testes do `ComprovanteCrypto`: devolve os
/// status programados e conta as gravações. `adicionar` com `errSecSuccess`
/// guarda os bytes e o `buscar` passa a devolvê-los — como o Keychain real.
nonisolated final class KeychainFalso: ComprovanteKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var guardado: Data?
    private let statusAdicionar: OSStatus
    /// Respostas programadas do `buscar`, consumidas na ordem; esgotada a
    /// fila, vale o estado real (chave guardada ou o `statusBusca` do init).
    private var filaBusca: [(OSStatus, Data?)] = []
    private let statusBusca: OSStatus
    private(set) var chamadasAdicionar = 0

    init(statusBusca: OSStatus = errSecItemNotFound,
         statusAdicionar: OSStatus = errSecSuccess,
         chaveGuardada: Data? = nil) {
        self.statusBusca = statusBusca
        self.statusAdicionar = statusAdicionar
        self.guardado = chaveGuardada
    }

    /// A próxima chamada de `buscar` devolve esta resposta (consumida uma vez).
    func programarBusca(status: OSStatus, dados: Data? = nil) {
        lock.withLock { filaBusca.append((status, dados)) }
    }

    var chaveGuardada: Data? { lock.withLock { guardado } }

    func buscar() -> (status: OSStatus, dados: Data?) {
        lock.withLock {
            if !filaBusca.isEmpty { return filaBusca.removeFirst() }
            if let guardado { return (errSecSuccess, guardado) }
            return (statusBusca, nil)
        }
    }

    func adicionar(_ dados: Data) -> OSStatus {
        lock.withLock {
            chamadasAdicionar += 1
            if statusAdicionar == errSecSuccess { guardado = dados }
            return statusAdicionar
        }
    }
}

/// A chave das notas fiscais só pode ser criada quando o Keychain diz que ela
/// não existe (`errSecItemNotFound`). Com o iPhone travado
/// (`errSecInteractionNotAllowed` — sync em segundo plano, atalho do Apple
/// Pay) a leitura lança `keyNotAvailable` sem criar nada: criar outra chave
/// tornaria ilegíveis todas as notas guardadas no aparelho — e o sync
/// ofereceria "Descartar nota" para notas boas.
@MainActor
struct ChaveComprovanteTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    func lerGasto() throws -> GastosDia {
        let gastos = try ModelContext(container).fetch(FetchDescriptor<GastosDia>())
        try #require(gastos.count == 1)
        return gastos[0]
    }

    /// (a) `errSecItemNotFound`: a chave é criada e gravada uma vez — as
    /// leituras seguintes usam a que ficou no Keychain.
    @Test func chaveInexistenteEhCriadaEGravadaUmaVez() throws {
        let falso = KeychainFalso()
        let crypto = ComprovanteCrypto(keychain: falso)

        _ = try crypto.criptografar(Data("nota".utf8))
        #expect(falso.chamadasAdicionar == 1)
        #expect(falso.chaveGuardada?.count == 32)

        _ = try crypto.criptografar(Data("outra".utf8))
        #expect(falso.chamadasAdicionar == 1)
    }

    /// (b) `errSecInteractionNotAllowed` (aparelho travado): lança
    /// `keyNotAvailable` sem criar nada — o falso não recebe nenhuma gravação.
    @Test func aparelhoTravadoLancaKeyNotAvailableSemGravar() {
        let falso = KeychainFalso(statusBusca: errSecInteractionNotAllowed)
        let crypto = ComprovanteCrypto(keychain: falso)

        #expect(throws: ComprovanteCryptoError.keyNotAvailable) {
            try crypto.criptografar(Data("nota".utf8))
        }
        #expect(falso.chamadasAdicionar == 0)
        #expect(falso.chaveGuardada == nil)
    }

    /// (c) `errSecDuplicateItem` no adicionar (outra thread criou a chave ao
    /// mesmo tempo): relê e usa a que já estava lá — a cifra abre com ela.
    @Test func chaveDuplicadaUsaAQueJaEstava() throws {
        let existente = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let falso = KeychainFalso(statusAdicionar: errSecDuplicateItem, chaveGuardada: existente)
        // A corrida: a primeira busca ainda não via a chave da outra thread.
        falso.programarBusca(status: errSecItemNotFound)
        let crypto = ComprovanteCrypto(keychain: falso)
        let nota = Data("nota fiscal".utf8)

        let selada = try crypto.criptografar(nota)

        #expect(falso.chamadasAdicionar == 1)
        let aberta = try AES.GCM.open(try AES.GCM.SealedBox(combined: selada), using: SymmetricKey(data: existente))
        #expect(aberta == nota)
    }

    /// (d) Cifrar e decifrar devolve os bytes originais.
    @Test func cifrarEDecifrarDevolveOsBytesOriginais() throws {
        let crypto = ComprovanteCrypto(keychain: KeychainFalso())
        let original = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 42])

        let cifrado = try crypto.criptografar(original)
        let aberto = try crypto.descriptografar(cifrado)

        #expect(cifrado != original)
        #expect(aberto == original)
    }

    /// (e) Gasto com nota e chave inacessível (aparelho travado): nenhum
    /// upload sai, o gasto fica `.pending`, sem `syncError` e sem contar
    /// tentativa, e os bytes cifrados ficam — a nota sobe quando a chave
    /// voltar, sem passar pelo `erroNotaNaoAbre`.
    @Test func notaComChaveInacessivelEsperaSemFalhar() async throws {
        let falso = KeychainFalso(statusBusca: errSecInteractionNotAllowed)
        let crypto = ComprovanteCrypto(keychain: falso)

        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 25,
            periodo: "01/09 - 03/09", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        let gasto = GastosDia(valor: 25, titulo: "Jantar", categoria: .ALIMENTACAO, dia: dia)
        let bytesNota = Data([0xAA, 0xBB, 0xCC])
        gasto.comprovanteDataCriptografado = bytesNota
        ctx.insert(gasto)
        try ctx.save()

        let agora = Date()
        let syncActor = SyncActor(modelContainer: container, api: api, crypto: crypto)
        let restantes = await syncActor.sync(agora: agora, userId: userId)

        #expect(restantes == 1)
        // O gasto em si sobe; a nota, não — e o Keychain não foi gravado.
        #expect(api.chamadas == [.postCiclo, .postDiasLote, .postGasto])
        #expect(!api.chamadas.contains(.uploadComprovante))
        #expect(falso.chamadasAdicionar == 0)

        let lido = try lerGasto()
        #expect(lido.backendId != nil)
        #expect(lido.syncStatus == .pending)
        #expect(lido.syncError == nil)
        #expect(lido.tentativas == 0)
        #expect(lido.comprovanteDataCriptografado == bytesNota)
        let proxima = try #require(lido.proximaTentativaEm)
        #expect(abs(proxima.timeIntervalSince(agora) - 60) < 1)
    }
}
