import Testing
import Foundation
@testable import SoftSpend

/// A chave das notas fiscais nunca é trocada por erro passageiro do Keychain:
/// só é criada quando o armazém diz que ela não existe, e só com "adicionar"
/// (nunca apagar e gravar outra).
struct ComprovanteCryptoTests {
    let nota = Data("nota fiscal do almoço".utf8)

    /// iPhone trancado: as duas operações lançam `keyNotAvailable` e nenhuma
    /// chave nova é criada (a antiga continua guardada).
    @Test func chaveIndisponivelLancaSemCriarOutra() throws {
        let antiga = ArmazemDeChaveFalso.chaveAleatoria()
        let armazem = ArmazemDeChaveFalso(chave: antiga)
        let crypto = ComprovanteCrypto(armazem: armazem)
        let cifrada = try crypto.criptografar(nota)

        armazem.indisponivel = true

        #expect(throws: ComprovanteCryptoError.keyNotAvailable) { try crypto.criptografar(nota) }
        #expect(throws: ComprovanteCryptoError.keyNotAvailable) { try crypto.descriptografar(cifrada) }
        #expect(armazem.adicionadas.isEmpty)
        #expect(armazem.chave == antiga)

        // Destrancou: a nota antiga abre com a mesma chave.
        armazem.indisponivel = false
        #expect(try crypto.descriptografar(cifrada) == nota)
    }

    /// Sem chave: cria uma e a reutiliza nas chamadas seguintes.
    @Test func semChaveCriaUmaEReutiliza() throws {
        let armazem = ArmazemDeChaveFalso()
        let crypto = ComprovanteCrypto(armazem: armazem)

        let primeira = try crypto.criptografar(nota)
        #expect(armazem.adicionadas.count == 1)
        let criada = try #require(armazem.chave)
        #expect(criada.count == 32)

        let segunda = try crypto.criptografar(nota)
        #expect(armazem.adicionadas.count == 1)
        #expect(armazem.chave == criada)
        #expect(try crypto.descriptografar(primeira) == nota)
        #expect(try crypto.descriptografar(segunda) == nota)
    }

    /// Chave guardada: é usada sem tentar adicionar outra.
    @Test func chaveExistenteEUsadaSemAdicionar() throws {
        let existente = ArmazemDeChaveFalso.chaveAleatoria()
        let armazem = ArmazemDeChaveFalso(chave: existente)
        let crypto = ComprovanteCrypto(armazem: armazem)

        let cifrada = try crypto.criptografar(nota)
        #expect(try crypto.descriptografar(cifrada) == nota)
        #expect(armazem.adicionadas.isEmpty)

        // Cifrou mesmo com a chave existente: outro crypto com o mesmo armazém abre.
        let outro = ComprovanteCrypto(armazem: ArmazemDeChaveFalso(chave: existente))
        #expect(try outro.descriptografar(cifrada) == nota)
    }

    /// Corrida: outra thread criou a chave entre a busca e o add. O add volta
    /// `errSecDuplicateItem`, a chave é relida e a que está lá é usada.
    @Test func chaveDuplicadaReleEUsaAExistente() throws {
        let armazem = ArmazemDeChaveFalso()
        let daOutraThread = ArmazemDeChaveFalso.chaveAleatoria()
        armazem.outraChamadaCriaAntes(daOutraThread)
        let crypto = ComprovanteCrypto(armazem: armazem)

        let cifrada = try crypto.criptografar(nota)

        #expect(armazem.adicionadas.count == 1)
        #expect(armazem.chave == daOutraThread)
        let comAChaveDaOutra = ComprovanteCrypto(armazem: ArmazemDeChaveFalso(chave: daOutraThread))
        #expect(try comAChaveDaOutra.descriptografar(cifrada) == nota)
    }

    /// Ida e volta devolve os mesmos bytes (inclusive vazio e grande).
    @Test func idaEVoltaDevolveOsMesmosBytes() throws {
        let crypto = ComprovanteCrypto(armazem: ArmazemDeChaveFalso(chave: ArmazemDeChaveFalso.chaveAleatoria()))
        let grande = Data((0..<200_000).map { UInt8($0 % 251) })
        for original in [nota, Data(), grande] {
            let cifrada = try crypto.criptografar(original)
            #expect(cifrada != original)
            #expect(try crypto.descriptografar(cifrada) == original)
        }
    }

    /// No `GastosDia`: chave indisponível lança (nota guardada, tentar depois);
    /// bytes que não abrem com a chave atual devolvem `nil`.
    @Test func lerComprovanteDistingueChaveIndisponivelDeBytesIlegiveis() throws {
        let armazem = ArmazemDeChaveFalso(chave: ArmazemDeChaveFalso.chaveAleatoria())
        let crypto = ComprovanteCrypto(armazem: armazem)
        let gasto = GastosDia(valor: 10, titulo: "Café", categoria: .ALIMENTACAO)

        #expect(try gasto.lerComprovante(crypto: crypto) == nil)

        gasto.comprovanteDataCriptografado = try crypto.criptografar(nota)
        #expect(try gasto.lerComprovante(crypto: crypto) == nota)

        armazem.indisponivel = true
        #expect(throws: ComprovanteCryptoError.keyNotAvailable) { try gasto.lerComprovante(crypto: crypto) }
        armazem.indisponivel = false

        let outraChave = ComprovanteCrypto(armazem: ArmazemDeChaveFalso(chave: ArmazemDeChaveFalso.chaveAleatoria()))
        #expect(try gasto.lerComprovante(crypto: outraChave) == nil)
        gasto.comprovanteDataCriptografado = Data([1, 2, 3])
        #expect(try gasto.lerComprovante(crypto: crypto) == nil)
    }
}
