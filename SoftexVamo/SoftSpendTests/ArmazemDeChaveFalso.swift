import Foundation
import Security
@testable import SoftSpend

/// Armazém de chave em memória, no lugar do Keychain.
///
/// `indisponivel` simula o iPhone trancado (`errSecInteractionNotAllowed`):
/// a chave guardada continua lá, só não é entregue. `outraChamadaCriaAntes`
/// simula a corrida: o próximo `adicionar` encontra uma chave criada por outra
/// thread e lança `errSecDuplicateItem`.
nonisolated final class ArmazemDeChaveFalso: ArmazemDeChave, @unchecked Sendable {
    private let lock = NSLock()
    private var _chave: Data?
    private var _indisponivel = false
    private var _chaveDaOutraChamada: Data?
    private var _adicionadas: [Data] = []
    private var _buscas = 0

    init(chave: Data? = nil) {
        _chave = chave
    }

    var chave: Data? { lock.withLock { _chave } }
    var adicionadas: [Data] { lock.withLock { _adicionadas } }
    var buscas: Int { lock.withLock { _buscas } }

    var indisponivel: Bool {
        get { lock.withLock { _indisponivel } }
        set { lock.withLock { _indisponivel = newValue } }
    }

    func outraChamadaCriaAntes(_ chave: Data) {
        lock.withLock { _chaveDaOutraChamada = chave }
    }

    func buscar() -> ResultadoBuscaChave {
        lock.withLock {
            _buscas += 1
            if _indisponivel { return .indisponivel(errSecInteractionNotAllowed) }
            guard let _chave else { return .naoExiste }
            return .achou(_chave)
        }
    }

    func adicionar(_ chave: Data) throws {
        try lock.withLock {
            _adicionadas.append(chave)
            if let outra = _chaveDaOutraChamada {
                _chaveDaOutraChamada = nil
                _chave = outra
                throw ErroDoArmazemDeChave(status: errSecDuplicateItem)
            }
            if _chave != nil {
                throw ErroDoArmazemDeChave(status: errSecDuplicateItem)
            }
            _chave = chave
        }
    }

    static func chaveAleatoria() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }
}
