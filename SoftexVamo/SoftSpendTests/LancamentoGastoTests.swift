import Testing
import Foundation
import UIKit
@testable import SoftSpend

/// `.serialized` porque os testes de leitura mexem na chave real de
/// consentimento (mesmo cuidado de `BloqueiosAssinaturaTests`: guarda e
/// restaura).
@Suite(.serialized)
@MainActor
struct LancamentoGastoTests {
    func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    func valor(_ texto: String) -> Decimal {
        let r = RascunhoGasto(dia: nil)
        r.valorTexto = texto
        return r.valor
    }

    /// O teclado decimal digita "." em aparelhos em inglês e "," em pt-BR.
    @Test func valorAceitaPontoEVirgula() {
        #expect(valor("43.10") == dec("43.10"))
        #expect(valor("43,10") == dec("43.10"))
        #expect(valor("43.1") == dec("43.1"))
        #expect(valor("1.234,56") == dec("1234.56"))
    }

    @Test func valorArredondaEInvalidoVale0() {
        #expect(valor("12,345") == dec("12.35"))
        #expect(valor("") == 0)
        #expect(valor("abc") == 0)
    }

    // MARK: - Leitura por IA (costuras lerLocal/extrair)

    /// Liga `Consentimento.leituraAutomatica` (chave real de `.standard`) e
    /// devolve o restaurador, como `BloqueiosAssinaturaTests.permitirLeitura`.
    private func permitirLeitura() -> () -> Void {
        let padrao = UserDefaults.standard
        let salvo = padrao.object(forKey: Consentimento.chave)
        Consentimento.leituraAutomatica = true
        return {
            if let salvo { padrao.set(salvo, forKey: Consentimento.chave) }
            else { padrao.removeObject(forKey: Consentimento.chave) }
        }
    }

    /// PNG 8x8: `comprimirParaOCR` devolve dados para ela (`UIImage()` não tem).
    private func imagemTeste() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// Acesso desconhecido (estado nunca carregado) deixa a leitura passar
    /// (§3.5): quem decide no envio é o servidor.
    private func acessoLivre() -> AssinaturaViewModel {
        AssinaturaViewModel(
            loja: FakeLojaAssinatura(), api: FakeAssinaturaAPI(),
            usuarioLogado: { "usuario-1" }, sincronizar: {}
        )
    }

    /// 429 `daily_ai_limit` (teto diário, limite_ia.py): aviso próprio, e a
    /// leitura feita no aparelho antes da chamada fica nos campos.
    @Test func limiteDiarioIAAvisaEMantemLeituraLocal() async {
        let restaurar = permitirLeitura()
        defer { restaurar() }
        var tituloAplicado: String?
        var valorAplicado: Decimal?

        let aviso = await LeituraComprovante.ler(
            imagemTeste(), acesso: acessoLivre(),
            lerLocal: { _ in
                GastoLocalExtraido(titulo: "Padaria", valor: 10, categoria: .ALIMENTACAO)
            },
            extrair: { _ in
                throw APIError.serverError(
                    message: "daily_ai_limit", requestId: "-", statusCode: 429)
            },
            aplicar: { titulo, valor, _ in
                tituloAplicado = titulo
                valorAplicado = valor
            }
        )

        #expect(aviso == LeituraComprovante.avisoLimiteDiarioIA)
        // Os campos da leitura no aparelho não foram apagados pelo 429.
        #expect(tituloAplicado == "Padaria")
        #expect(valorAplicado == 10)
    }

    /// Outro 429 (por minuto, slowapi) mantém o aviso genérico.
    @Test func outro429MantemAvisoGenerico() async {
        let restaurar = permitirLeitura()
        defer { restaurar() }

        let aviso = await LeituraComprovante.ler(
            imagemTeste(), acesso: acessoLivre(),
            lerLocal: { _ in GastoLocalExtraido() },
            extrair: { _ in
                throw APIError.serverError(
                    message: "Rate limit exceeded: 20 per 1 minute",
                    requestId: "-", statusCode: 429)
            },
            aplicar: { _, _, _ in }
        )

        #expect(aviso == "Não foi possível ler o comprovante. Preencha os campos.")
    }
}
