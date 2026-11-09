import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// Serializado: os testes mexem na mesma chave de `UserDefaults`. Cada um guarda
/// o valor que havia, apaga e restaura no fim, para não vazar para o app.
@Suite(.serialized)
@MainActor
struct ConsentimentoTests {
    private let chave = "consentimentoLeituraAutomatica"

    /// Guarda o valor atual da chave, apaga e devolve como restaurá-lo.
    private func isolar() -> () -> Void {
        let padrao = UserDefaults.standard
        let salvo = padrao.object(forKey: chave)
        padrao.removeObject(forKey: chave)
        return { [chave] in
            if let salvo { padrao.set(salvo, forKey: chave) } else { padrao.removeObject(forKey: chave) }
        }
    }

    @Test func comecaSemResposta() {
        let restaurar = isolar()
        defer { restaurar() }
        #expect(Consentimento.leituraAutomatica == nil)
    }

    @Test func guardaPermissao() {
        let restaurar = isolar()
        defer { restaurar() }
        Consentimento.leituraAutomatica = true
        #expect(Consentimento.leituraAutomatica == true)
        #expect(UserDefaults.standard.object(forKey: chave) as? Bool == true)
    }

    @Test func guardaRecusa() {
        let restaurar = isolar()
        defer { restaurar() }
        Consentimento.leituraAutomatica = false
        #expect(Consentimento.leituraAutomatica == false)
    }

    @Test func nilApagaAResposta() {
        let restaurar = isolar()
        defer { restaurar() }
        Consentimento.leituraAutomatica = true
        Consentimento.leituraAutomatica = nil
        #expect(Consentimento.leituraAutomatica == nil)
        #expect(UserDefaults.standard.object(forKey: chave) == nil)
    }

    @Test func suiteInjetadaNaoTocaOPadrao() throws {
        let restaurar = isolar()
        defer { restaurar() }
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
