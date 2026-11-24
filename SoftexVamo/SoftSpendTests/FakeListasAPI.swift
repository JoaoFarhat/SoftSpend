import Foundation
@testable import SoftSpend

/// API de listas falsa para testar o `CiclosViewModel` sem rede: devolve as
/// páginas de viagens configuradas na ordem das chamadas, grava o `antes_de`
/// de cada uma e responde `fetchDias` com a lista configurada.
nonisolated final class FakeListasAPI: ListasAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var _paginas: [[CicloSoftex]]
    private var _dias: [DiaSoftex]
    private var _antesDeChamados: [Int?] = []
    private var _limitChamados: [Int] = []
    private var _diasBuscados: [Int] = []

    /// `paginas[i]` é o que a i-ésima chamada de `fetchCicloResumo` devolve;
    /// acabadas as páginas, devolve vazio.
    init(paginas: [[CicloSoftex]], dias: [DiaSoftex] = []) {
        _paginas = paginas
        _dias = dias
    }

    /// `antes_de` de cada chamada de `fetchCicloResumo`, na ordem.
    var antesDeChamados: [Int?] { lock.lock(); defer { lock.unlock() }; return _antesDeChamados }
    var limitChamados: [Int] { lock.lock(); defer { lock.unlock() }; return _limitChamados }
    /// `cicloId` de cada chamada de `fetchDias`, na ordem.
    var diasBuscados: [Int] { lock.lock(); defer { lock.unlock() }; return _diasBuscados }

    func fetchCicloResumo(antesDe: Int?, skip: Int, limit: Int) async throws -> [CicloSoftex] {
        lock.lock()
        _antesDeChamados.append(antesDe)
        _limitChamados.append(limit)
        let pagina = _paginas.isEmpty ? [] : _paginas.removeFirst()
        lock.unlock()
        return pagina
    }

    func fetchDias(cicloId: Int, skip: Int, limit: Int) async throws -> [DiaSoftex] {
        lock.lock()
        _diasBuscados.append(cicloId)
        let dias = _dias
        lock.unlock()
        return dias
    }
}
