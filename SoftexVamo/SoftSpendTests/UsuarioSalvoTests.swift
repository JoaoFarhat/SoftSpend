import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// `UsuarioSalvo.id()` (§1.3): o `userId` sai do `user_data` do UserDefaults —
/// **sem token no Keychain** — porque a ação do Apple Pay pode rodar com o
/// iPhone trancado e o token é ilegível nessa hora. Cada teste usa uma suíte
/// de UserDefaults própria (não a `standard` do app de teste).
@MainActor
struct UsuarioSalvoTests {
    let defaults: UserDefaults
    let container: ModelContainer
    let ctx: ModelContext
    let fila: ComprasAguardandoViagem
    let cal: Calendar
    let agora: Date
    let hoje: Date

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "teste-\(UUID().uuidString)"))
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        ctx = ModelContext(container)
        let arquivo = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-\(UUID().uuidString).json")
        fila = ComprasAguardandoViagem(arquivo: arquivo)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Cuiaba")!
        cal = c
        agora = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15))!
        hoje = cal.startOfDay(for: agora)
    }

    @Test func comUserDataSemTokenDevolveIdEGraça() throws {
        let dto = UserDTO(id: "u-9", nome: "João", username: "joao", email: "j@x.com")
        defaults.set(try JSONEncoder().encode(dto), forKey: UsuarioSalvo.chave)

        // Sem nenhum token salvo: o id sai do JSON, nada é lido do Keychain.
        let id = UsuarioSalvo.id(defaults: defaults)
        #expect(id == "u-9")

        let ciclo = CicloSoftex(userId: "u-9", valor_total: 700, gasto_total: 0,
                                periodo: "13/11 - 15/11", diaria: 100, titulo: "Cuiabá, MT")
        ciclo.criadoEm = agora
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: hoje, saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()

        let r = try RegistroApplePay.registrar(valor: "10,00", estabelecimento: "Padaria",
                                               userId: id, em: ctx, fila: fila,
                                               agora: agora, calendario: cal)
        guard case .gravado = r else {
            Issue.record("esperava .gravado, veio \(r)")
            return
        }
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).count == 1)
    }

    @Test func semUserDataRecusaENaoGrava() throws {
        #expect(UsuarioSalvo.id(defaults: defaults) == nil)

        let r = try RegistroApplePay.registrar(valor: "10,00", estabelecimento: "Padaria",
                                               userId: UsuarioSalvo.id(defaults: defaults),
                                               em: ctx, fila: fila, agora: agora, calendario: cal)
        #expect(r == .recusado(.semUsuario))
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
        #expect(fila.todas().isEmpty)
    }

    @Test func userDataCorrompidoRecusa() throws {
        defaults.set(Data("lixo".utf8), forKey: UsuarioSalvo.chave)
        #expect(UsuarioSalvo.id(defaults: defaults) == nil)
    }
}
