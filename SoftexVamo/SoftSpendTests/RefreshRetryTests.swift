import Testing
import Foundation
@testable import SoftSpend

/// Conta as chamadas da operação e registra as esperas pedidas.
private actor Registro {
    var chamadas = 0
    var esperas: [Duration] = []

    func chamar() -> Int {
        chamadas += 1
        return chamadas
    }

    func esperar(_ d: Duration) {
        esperas.append(d)
    }
}

private func erroServidor(_ status: Int) -> APIError {
    .serverError(message: "x", requestId: "-", statusCode: status)
}

struct RefreshRetryTests {
    let esperas: [Duration] = [.seconds(1), .seconds(3)]

    @Test func esperasPadraoSao1sE3s() {
        #expect(esperasRefreshTransitorio == [.seconds(1), .seconds(3)])
    }

    @Test func classificaErrosTransitorios() {
        #expect(ehFalhaTransitoriaDeRefresh(URLError(.timedOut)))
        #expect(ehFalhaTransitoriaDeRefresh(URLError(.notConnectedToInternet)))
        #expect(ehFalhaTransitoriaDeRefresh(erroServidor(500)))
        #expect(ehFalhaTransitoriaDeRefresh(erroServidor(503)))
        #expect(!ehFalhaTransitoriaDeRefresh(erroServidor(401)))
        #expect(!ehFalhaTransitoriaDeRefresh(erroServidor(403)))
        #expect(!ehFalhaTransitoriaDeRefresh(erroServidor(422)))
        #expect(!ehFalhaTransitoriaDeRefresh(APIError.authentication))
        #expect(!ehFalhaTransitoriaDeRefresh(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))))
    }

    @Test func repeteEmURLError() async throws {
        let r = Registro()
        let valor = try await repetindoSeTransitorio(
            esperas: esperas,
            dormir: { await r.esperar($0) }
        ) { () async throws -> String in
            if await r.chamar() < 3 { throw URLError(.timedOut) }
            return "ok"
        }
        #expect(valor == "ok")
        #expect(await r.chamadas == 3)
        #expect(await r.esperas == [.seconds(1), .seconds(3)])
    }

    @Test func repeteEm500() async throws {
        let r = Registro()
        let valor = try await repetindoSeTransitorio(
            esperas: esperas,
            dormir: { await r.esperar($0) }
        ) { () async throws -> Int in
            if await r.chamar() == 1 { throw erroServidor(500) }
            return 42
        }
        #expect(valor == 42)
        #expect(await r.chamadas == 2)
        #expect(await r.esperas == [.seconds(1)])
    }

    @Test(arguments: [401, 403])
    func naoRepeteEm401ou403(status: Int) async {
        let r = Registro()
        await #expect(throws: APIError.self) {
            try await repetindoSeTransitorio(
                esperas: esperas,
                dormir: { await r.esperar($0) }
            ) { () async throws -> Int in
                _ = await r.chamar()
                throw erroServidor(status)
            }
        }
        #expect(await r.chamadas == 1)
        #expect(await r.esperas.isEmpty)
    }

    @Test func desisteApos3Tentativas() async {
        let r = Registro()
        await #expect(throws: URLError.self) {
            try await repetindoSeTransitorio(
                esperas: esperas,
                dormir: { await r.esperar($0) }
            ) { () async throws -> Int in
                _ = await r.chamar()
                throw URLError(.notConnectedToInternet)
            }
        }
        #expect(await r.chamadas == 3)
        #expect(await r.esperas == [.seconds(1), .seconds(3)])
    }

    @Test func sucessoDePrimeiraNaoEspera() async throws {
        let r = Registro()
        let valor = try await repetindoSeTransitorio(
            esperas: esperas,
            dormir: { await r.esperar($0) }
        ) { () async throws -> Bool in
            _ = await r.chamar()
            return true
        }
        #expect(valor)
        #expect(await r.chamadas == 1)
        #expect(await r.esperas.isEmpty)
    }
}
