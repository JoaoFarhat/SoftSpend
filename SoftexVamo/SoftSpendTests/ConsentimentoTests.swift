import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Serializado: os testes mexem na mesma chave de `UserDefaults`, que é
/// apagada antes e depois de cada um para não vazar para o app nem para outros testes.
@Suite(.serialized)
@MainActor
struct ConsentimentoTests {
    private let chave = "consentimentoLeituraAutomatica"

    private func limpar() {
        UserDefaults.standard.removeObject(forKey: chave)
    }

    @Test func comecaSemResposta() {
        limpar()
        defer { limpar() }
        #expect(Consentimento.leituraAutomatica == nil)
    }

    @Test func guardaPermissao() {
        limpar()
        defer { limpar() }
        Consentimento.leituraAutomatica = true
        #expect(Consentimento.leituraAutomatica == true)
        #expect(UserDefaults.standard.object(forKey: chave) as? Bool == true)
    }

    @Test func guardaRecusa() {
        limpar()
        defer { limpar() }
        Consentimento.leituraAutomatica = false
        #expect(Consentimento.leituraAutomatica == false)
    }

    @Test func nilApagaAResposta() {
        limpar()
        defer { limpar() }
        Consentimento.leituraAutomatica = true
        Consentimento.leituraAutomatica = nil
        #expect(Consentimento.leituraAutomatica == nil)
        #expect(UserDefaults.standard.object(forKey: chave) == nil)
    }

    @Test func suiteInjetadaNaoTocaOPadrao() throws {
        limpar()
        defer { limpar() }
        let nome = "ConsentimentoTests.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: nome))
        defer { suite.removePersistentDomain(forName: nome) }

        #expect(Consentimento.leitura(em: suite) == nil)
        Consentimento.gravar(false, em: suite)
        #expect(Consentimento.leitura(em: suite) == false)
        #expect(Consentimento.leituraAutomatica == nil)
    }
}

@MainActor
struct SobraDepoisTests {
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    func resumo(gastosHoje: [String]) throws -> (ResumoViagem, ModelContainer) {
        let container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let cal = Calendar.current
        let hoje = cal.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 12))!
        let ciclo = CicloSoftex(valor_total: 2700, gasto_total: 0, periodo: "", diaria: 450, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)
        for n in 20...25 {
            let dia = DiaSoftex(data: cal.date(from: DateComponents(year: 2026, month: 7, day: n))!, saldo: 450)
            ctx.insert(dia)
            dia.ciclo = ciclo
            if n == 23 {
                for valor in gastosHoje {
                    let g = GastosDia(valor: dec(valor), titulo: "Gasto", categoria: .OUTROS, dia: dia)
                    ctx.insert(g)
                }
            }
        }
        return (ResumoViagem(ciclo: ciclo, hoje: hoje, calendario: cal), container)
    }

    @Test func sobraDepoisDoGasto() throws {
        let (r, _) = try resumo(gastosHoje: ["104.60"])
        #expect(sobraDepois(de: dec("43.10"), resumo: r) == dec("302.30"))
    }

    @Test func passaDaDiariaFicaNegativo() throws {
        let (r, _) = try resumo(gastosHoje: ["104.60", "300.00"])
        #expect(sobraDepois(de: dec("100.00"), resumo: r) == dec("-54.60"))
    }
}
