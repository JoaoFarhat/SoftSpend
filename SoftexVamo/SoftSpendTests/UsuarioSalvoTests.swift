import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// §1.3 e §1.9 de docs/cartao-sem-open-finance.md: o `userId` vem do
/// `user_data` do UserDefaults — legível com o iPhone trancado, ao contrário
/// do token do Keychain (que é `WhenUnlockedThisDeviceOnly`).
@MainActor
struct UsuarioSalvoTests {

    func bancoComViagem(userId: String, hoje: Date) throws -> ModelContext {
        let container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 300, gasto_total: 0,
            periodo: "", diaria: 100, titulo: "Cuiabá, MT", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: hoje), saldo: 100)
        dia.ciclo = ciclo
        ctx.insert(dia)
        try ctx.save()
        return ctx
    }

    func filaTemp() -> ComprasAguardandoViagem {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ComprasAguardandoViagem(url: dir.appendingPathComponent("fila.json"))
    }

    @Test func comUserDataESemTokenDevolveIdEGrava() throws {
        let defaults = UserDefaults(suiteName: "teste-usuario-salvo-\(UUID().uuidString)")!
        let dto = UserDTO(id: "u-9", nome: "Ana", username: "ana", email: "ana@a.com")
        defaults.set(try JSONEncoder().encode(dto), forKey: UsuarioSalvo.chave)

        // Sem nenhum token no Keychain, o id vem do user_data.
        #expect(UsuarioSalvo.id(em: defaults) == "u-9")

        // E a regra grava o gasto com esse id, sem depender do AuthService.
        let agora = Date()
        let ctx = try bancoComViagem(userId: "u-9", hoje: agora)
        let resultado = try RegistroApplePay.registrar(
            valorTexto: "R$ 5,00", estabelecimento: "CAFE", cartao: nil,
            userId: UsuarioSalvo.id(em: defaults),
            em: ctx, agora: agora, calendario: .current, fila: filaTemp()
        )
        guard case .gravado = resultado else {
            Issue.record("esperava .gravado, veio \(String(describing: resultado))")
            return
        }
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).count == 1)
    }

    @Test func semUserDataRecusaENaoGrava() throws {
        let defaults = UserDefaults(suiteName: "teste-usuario-salvo-\(UUID().uuidString)")!
        #expect(UsuarioSalvo.id(em: defaults) == nil)

        let ctx = try bancoComViagem(userId: "u-9", hoje: Date())
        let resultado = try RegistroApplePay.registrar(
            valorTexto: "R$ 5,00", estabelecimento: "CAFE", cartao: nil,
            userId: UsuarioSalvo.id(em: defaults),
            em: ctx, calendario: .current, fila: filaTemp()
        )
        #expect(resultado == .recusado(.semUsuario))
        #expect(try ctx.fetch(FetchDescriptor<GastosDia>()).isEmpty)
    }

    @Test func userDataInvalidoDevolveNil() throws {
        let defaults = UserDefaults(suiteName: "teste-usuario-salvo-\(UUID().uuidString)")!
        defaults.set(Data("não é json".utf8), forKey: UsuarioSalvo.chave)
        #expect(UsuarioSalvo.id(em: defaults) == nil)
    }
}
