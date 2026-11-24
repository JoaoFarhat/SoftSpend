import Foundation
@testable import SoftSpend

/// Cifra falsa para o `SyncActor`: repassa os bytes sem cifrar de verdade e
/// pode simular o aparelho bloqueado — `chaveInacessivel = true` faz
/// `descriptografar` lançar `keyNotAvailable`, como o Keychain
/// `WhenUnlockedThisDeviceOnly` com o iPhone trancado.
nonisolated final class FakeCifrador: CifradorComprovante, @unchecked Sendable {
    var chaveInacessivel = false

    func criptografar(_ dados: Data) throws -> Data { dados }

    func descriptografar(_ dados: Data) throws -> Data {
        if chaveInacessivel { throw ComprovanteCryptoError.keyNotAvailable }
        return dados
    }
}
