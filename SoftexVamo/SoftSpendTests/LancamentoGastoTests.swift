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

    /// Título só com espaços ou quebra de linha (colado da notificação, por
    /// exemplo) não libera o Salvar: antes `podeSalvar` aparava só
    /// `.whitespaces`, o envio aparava com `.whitespacesAndNewlines` e o
    /// servidor devolvia 422, deixando o gasto retentando com backoff.
    @Test func tituloSoComEspacosOuQuebraDeLinhaNaoLiberaSalvar() {
        let r = RascunhoGasto(dia: DiaSoftex(data: .now, saldo: 100))
        r.valorTexto = "10,00"

        r.titulo = "\n"
        #expect(r.podeSalvar == false)
        r.titulo = "  "
        #expect(r.podeSalvar == false)
        r.titulo = " \n "
        #expect(r.podeSalvar == false)

        r.titulo = "Almoço"
        #expect(r.podeSalvar == true)
    }

    // MARK: - Teto de valor do servidor

    /// `max_digits=10, decimal_places=2` no `valor` do gasto: R$ 99.999.999,99
    /// salva; acima o servidor devolve 422 e o gasto retentaria para sempre,
    /// então o Salvar desliga e o motivo aparece no formulário.
    @Test func valorNoTetoDoServidorLiberaSalvar() {
        let r = RascunhoGasto(dia: DiaSoftex(data: .now, saldo: 100))
        r.titulo = "Almoço"
        r.valorTexto = "99.999.999,99"

        #expect(r.podeSalvar == true)
        #expect(r.erroValor == nil)
    }

    @Test func valorAcimaDoTetoDoServidorBloqueiaEAvisa() {
        let r = RascunhoGasto(dia: DiaSoftex(data: .now, saldo: 100))
        r.titulo = "Almoço"
        r.valorTexto = "100.000.000,00"

        #expect(r.podeSalvar == false)
        #expect(r.erroValor == "O valor máximo é R$ 99.999.999,99")
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

    // MARK: - NotaFiscal.codificar

    /// Imagem só de ruído em tons de cinza: o JPEG quase não comprime e,
    /// sem canal de croma, o tamanho não depende do subsampling do encoder —
    /// ~0,4 B/px em qualidade baixa, então 6000² (~36 MP) passa do teto.
    private func imagemDeRuido(lado: Int) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: lado * lado)
        arc4random_buf(&bytes, bytes.count)
        let provedor = CGDataProvider(data: Data(bytes) as CFData)!
        let imagem = CGImage(
            width: lado, height: lado,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: lado,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provedor,
            decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: imagem)
    }

    /// Foto que nem na qualidade 0,4 cabe no teto: `codificar` reduz a
    /// resolução em passos de 0,75 até o JPEG ficar abaixo de 9 MB — e o
    /// resultado continua sendo uma imagem válida (era o buraco em que a
    /// nota de 5–9 MB nunca subia: o app mandava e o servidor dava 413).
    @Test func notaQueNaoCabeNaMenorQualidadeDesceResolucao() throws {
        let original = imagemDeRuido(lado: 6000)
        // Pré-condição do cenário: o ruído passa do teto mesmo na qualidade mínima.
        let piorQualidade = try #require(original.jpegData(compressionQuality: 0.4))
        #expect(piorQualidade.count > NotaFiscal.tamanhoMaximo)

        let dados = try #require(NotaFiscal.codificar(original))

        #expect(dados.count <= NotaFiscal.tamanhoMaximo)
        let decodificada = try #require(UIImage(data: dados))
        #expect(decodificada.size.width < original.size.width)
        #expect(decodificada.size.height < original.size.height)
    }

    /// Nota que já cabe: só a conversão para JPEG, sem perda de resolução.
    @Test func notaPequenaMantemResolucao() throws {
        let original = imagemDeRuido(lado: 120)

        let dados = try #require(NotaFiscal.codificar(original))
        let decodificada = try #require(UIImage(data: dados))

        #expect(decodificada.size == original.size)
    }
}
