import Testing
import Foundation
@testable import SoftSpend

/// `EstadoEnvio` traduz `syncStatus`/`syncError` do gasto para o que a
/// interface mostra: nada quando enviado, `icloud.slash` aguardando,
/// triângulo nas falhas e a falha final por 404 (T4) com cara própria.
struct EstadoEnvioTests {
    @Test func enviado() {
        let gasto = GastosDia(valor: 10, titulo: "Táxi", categoria: .TRANSPORTE)
        gasto.syncStatus = .synced
        #expect(EstadoEnvio.de(gasto) == .enviado)
        #expect(EstadoEnvio.de(gasto).simbolo == nil)
    }

    @Test func aguardando() {
        // Gasto novo já nasce `.pending`; `.syncing` também é espera.
        let gasto = GastosDia(valor: 10, titulo: "Táxi", categoria: .TRANSPORTE)
        #expect(EstadoEnvio.de(gasto) == .aguardando)
        gasto.syncStatus = .syncing
        #expect(EstadoEnvio.de(gasto) == .aguardando)
        #expect(EstadoEnvio.de(gasto).simbolo == "icloud.slash")
    }

    @Test func falhou() {
        let gasto = GastosDia(valor: 10, titulo: "Táxi", categoria: .TRANSPORTE)
        gasto.syncStatus = .failed
        gasto.syncError = "sem conexão com o servidor"
        #expect(EstadoEnvio.de(gasto) == .falhou("sem conexão com o servidor"))
        #expect(EstadoEnvio.de(gasto).detalhe == "sem conexão com o servidor")
    }

    @Test func apagadoEmOutroAparelho() {
        // O texto fixo do `syncError` identifica a falha final por 404 (T4).
        let gasto = GastosDia(valor: 10, titulo: "Táxi", categoria: .TRANSPORTE)
        gasto.syncStatus = .failed
        gasto.syncError = SyncActor.erroApagadoEmOutroAparelho
        #expect(EstadoEnvio.de(gasto) == .apagadoEmOutroAparelho)
    }

    @Test func textoPendentes() {
        #expect(textoAlteracoesAguardando(1) == "1 alteração aguardando envio")
        #expect(textoAlteracoesAguardando(3) == "3 alterações aguardando envio")
    }
}
