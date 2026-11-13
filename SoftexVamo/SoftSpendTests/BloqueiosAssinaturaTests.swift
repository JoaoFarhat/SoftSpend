import Testing
import Foundation
import SwiftData
import UIKit
@testable import SoftSpend

/// I2b de docs/assinatura.md §3.5: os quatro gatilhos (nova viagem, ler com
/// IA, exportar, importar fatura) abrem a tela de planos quando o último
/// `GET /api/assinatura` conhecido diz `tem_acesso == false` — sem chamar a
/// rede. Com acesso (ou estado desconhecido) a ação segue; um 403
/// `subscription_required` direto abre os planos em vez de mostrar erro.
///
/// `.serialized` porque `lerComIa*` mexe na chave real de consentimento
/// (mesmo cuidado de `ConsentimentoTests`: guarda e restaura).
@Suite(.serialized)
@MainActor
struct BloqueiosAssinaturaTests {

    /// `AssinaturaViewModel` de teste: loja falsa e `GET /api/assinatura`
    /// falso, com o `tem_acesso` que o teste mandar.
    final class Fabrica {
        let api = FakeAssinaturaAPI()
        let vm: AssinaturaViewModel

        init() {
            vm = AssinaturaViewModel(
                loja: FakeLojaAssinatura(),
                api: api,
                usuarioLogado: { "usuario-1" },
                sincronizar: {}
            )
        }

        /// O servidor passa a responder este estado; `await vm.carregarEstado()`
        /// o traz para a memória.
        func responder(status: String = "none", temAcesso: Bool, expiraEm: Date? = nil) {
            api.estado = AssinaturaResponse(
                status: status, temAcesso: temAcesso, expiraEm: expiraEm,
                produto: nil, appAccountToken: FakeAssinaturaAPI.token.uuidString
            )
        }
    }

    /// Liga `Consentimento.leituraAutomatica` (chave real de `.standard`) e
    /// devolve o restaurador, como `ConsentimentoTests.isolar`.
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

    private func cicloTeste() -> CicloSoftex {
        let c = CicloSoftex(valor_total: 600, gasto_total: 0, periodo: "",
                            diaria: 100, titulo: "CuiabaMT", dias: [])
        c.backendId = 7
        return c
    }

    private func faturaVM(
        acesso: AssinaturaViewModel, api: FakeFaturaAPI
    ) -> ImportarFaturaViewModel {
        ImportarFaturaViewModel(
            ciclo: cicloTeste(), api: api,
            sincronizar: {},
            criarGasto: { _, _ in },
            acesso: acesso,
            defaults: UserDefaults(suiteName: "Bloqueios-\(UUID().uuidString)")!,
            tetoSync: .zero
        )
    }

    // MARK: A porta (§3.5)

    @Test func semAcessoExigirAbreOsPlanos() async {
        let f = Fabrica()
        f.responder(temAcesso: false)
        await f.vm.carregarEstado()

        #expect(!f.vm.exigirAcesso())
        #expect(f.vm.planosAbertos)
    }

    @Test func comAcessoEDesconhecidoExigirLibera() async {
        let f = Fabrica()
        // Nunca carregou: desconhecido deixa passar — o servidor decide no envio.
        #expect(f.vm.exigirAcesso())
        #expect(!f.vm.planosAbertos)

        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        #expect(f.vm.exigirAcesso())
        #expect(!f.vm.planosAbertos)
    }

    @Test func novaViagemBloqueadaEDemaisRotasLivres() async {
        let f = Fabrica()
        f.responder(temAcesso: false)
        await f.vm.carregarEstado()

        #expect(!f.vm.permiteAbrir(.novaViagem))
        #expect(f.vm.planosAbertos)

        f.vm.planosAbertos = false
        // Editar e as outras rotas ficam livres (§3.5).
        #expect(f.vm.permiteAbrir(.viagens))
        #expect(f.vm.permiteAbrir(.fecharViagem(UUID())))
        #expect(f.vm.permiteAbrir(.todosGastos(filtro: .todos)))
        #expect(!f.vm.planosAbertos)
    }

    // MARK: Ler com IA

    @Test func lerComIaSemAcessoAbrePlanosSemChamarRede() async {
        let f = Fabrica()
        f.responder(temAcesso: false)
        await f.vm.carregarEstado()
        let restaurar = permitirLeitura()
        defer { restaurar() }
        var leituraLocal = 0
        var rede = 0

        let aviso = await LeituraComprovante.ler(
            UIImage(), acesso: f.vm,
            lerLocal: { _ in leituraLocal += 1; return GastoLocalExtraido() },
            extrair: { _ in rede += 1; return .init(titulo: "X", valor: 1, categoria: .OUTROS) },
            aplicar: { _, _, _ in }
        )

        #expect(aviso == LeituraComprovante.avisoAssinatura)
        #expect(f.vm.planosAbertos)
        #expect(leituraLocal == 0)
        #expect(rede == 0)
    }

    @Test func lerComIaComAcessoChamaOServidor() async {
        let f = Fabrica()
        f.responder(status: "trial", temAcesso: true)
        await f.vm.carregarEstado()
        let restaurar = permitirLeitura()
        defer { restaurar() }
        var rede = 0
        var tituloLido: String?

        let aviso = await LeituraComprovante.ler(
            imagemTeste(), acesso: f.vm,
            lerLocal: { _ in GastoLocalExtraido() },
            extrair: { _ in
                rede += 1
                return GastoExtraidoResponse(titulo: "Padaria", valor: 10, categoria: .ALIMENTACAO)
            },
            aplicar: { titulo, _, _ in tituloLido = titulo }
        )

        #expect(aviso == nil)
        #expect(rede == 1)
        #expect(tituloLido == "Padaria")
        #expect(!f.vm.planosAbertos)
    }

    @Test func lerComIa403DiretoAbrePlanosSemErro() async {
        let f = Fabrica()
        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        let restaurar = permitirLeitura()
        defer { restaurar() }

        let aviso = await LeituraComprovante.ler(
            imagemTeste(), acesso: f.vm,
            lerLocal: { _ in GastoLocalExtraido() },
            extrair: { _ in
                throw APIError.serverError(
                    message: "subscription_required", requestId: "-", statusCode: 403)
            },
            aplicar: { _, _, _ in }
        )

        #expect(aviso == LeituraComprovante.avisoAssinatura)
        #expect(f.vm.planosAbertos)
    }

    // MARK: Exportar

    @Test func exportarSemAcessoAbrePlanosSemChamarRede() async throws {
        let f = Fabrica()
        f.responder(temAcesso: false)
        await f.vm.carregarEstado()
        let vm = CiclosViewModel()
        vm.assinatura = f.vm
        vm.atualCiclo = cicloTeste()
        var rede = 0
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1]) }

        let url = try await vm.exportarCiclo(formato: .pdf)

        #expect(url == nil)
        #expect(f.vm.planosAbertos)
        #expect(rede == 0)
    }

    @Test func exportarComAcessoGeraOArquivo() async throws {
        let f = Fabrica()
        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        let vm = CiclosViewModel()
        vm.assinatura = f.vm
        vm.atualCiclo = cicloTeste()
        var rede = 0
        vm.exportarRemoto = { _, _, _ in rede += 1; return Data([1, 2, 3]) }

        let url = try await vm.exportarCiclo(formato: .pdf)

        #expect(rede == 1)
        #expect(!f.vm.planosAbertos)
        let gerado = try #require(url)
        #expect(try Data(contentsOf: gerado) == Data([1, 2, 3]))
    }

    @Test func exportar403DiretoAbrePlanosSemErro() async throws {
        let f = Fabrica()
        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        let vm = CiclosViewModel()
        vm.assinatura = f.vm
        vm.atualCiclo = cicloTeste()
        vm.exportarRemoto = { _, _, _ in
            throw APIError.serverError(
                message: "subscription_required", requestId: "-", statusCode: 403)
        }

        let url = try await vm.exportarCiclo(formato: .csv)

        #expect(url == nil)
        #expect(f.vm.planosAbertos)
    }

    @Test func exportarOutroErroContinuaErro() async throws {
        let f = Fabrica()
        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        let vm = CiclosViewModel()
        vm.assinatura = f.vm
        vm.atualCiclo = cicloTeste()
        vm.exportarRemoto = { _, _, _ in
            throw APIError.serverError(message: "falhou", requestId: "-", statusCode: 500)
        }

        await #expect(throws: APIError.self) {
            _ = try await vm.exportarCiclo(formato: .pdf)
        }
        #expect(!f.vm.planosAbertos)
    }

    // MARK: Importar fatura

    @Test func importarFaturaSemAcessoAbrePlanosSemLer() async {
        let f = Fabrica()
        f.responder(temAcesso: false)
        await f.vm.carregarEstado()
        let apiFatura = FakeFaturaAPI()
        let vm = faturaVM(acesso: f.vm, api: apiFatura)

        #expect(vm.preparar(dados: Data([1]), tipo: .ofx, nome: "fatura.ofx"))
        await vm.ler()

        #expect(apiFatura.chamadas.isEmpty)
        #expect(f.vm.planosAbertos)
        #expect(vm.etapa == .escolhendo)
    }

    @Test func importarFaturaComAcessoLe() async {
        let f = Fabrica()
        f.responder(status: "trial", temAcesso: true)
        await f.vm.carregarEstado()
        let apiFatura = FakeFaturaAPI()
        let vm = faturaVM(acesso: f.vm, api: apiFatura)

        #expect(vm.preparar(dados: Data([1]), tipo: .ofx, nome: "fatura.ofx"))
        await vm.ler()

        #expect(apiFatura.chamadas == ["ler"])
        #expect(vm.etapa == .conferindo)
        #expect(!f.vm.planosAbertos)
    }

    @Test func importarFatura403DiretoAbrePlanosSemErro() async {
        let f = Fabrica()
        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        let apiFatura = FakeFaturaAPI()
        apiFatura.erroAoLer = APIError.serverError(
            message: "subscription_required", requestId: "-", statusCode: 403)
        let vm = faturaVM(acesso: f.vm, api: apiFatura)

        #expect(vm.preparar(dados: Data([1]), tipo: .ofx, nome: "fatura.ofx"))
        await vm.ler()

        #expect(vm.etapa == .escolhendo)
        #expect(f.vm.planosAbertos)
    }

    // MARK: O 403 e a faixa

    @Test func soO403DeSubscriptionRequiredEhDaAssinatura() {
        #expect(APIError.serverError(
            message: "subscription_required", requestId: "-", statusCode: 403).assinaturaNecessaria)
        #expect(!APIError.serverError(
            message: "outra coisa", requestId: "-", statusCode: 403).assinaturaNecessaria)
        #expect(!APIError.serverError(
            message: "subscription_required", requestId: "-", statusCode: 500).assinaturaNecessaria)
        #expect(!APIError.authentication.assinaturaNecessaria)
    }

    @Test func textoDaFaixaPorStatus() async throws {
        let f = Fabrica()
        // Desconhecido: sem faixa.
        #expect(f.vm.textoFaixa == nil)

        for status in ["grace", "billing_retry"] {
            f.responder(status: status, temAcesso: status == "grace")
            await f.vm.carregarEstado()
            #expect(f.vm.textoFaixa == "Seu pagamento falhou. Atualize a forma de pagamento.")
        }

        f.responder(status: "trial", temAcesso: true,
                    expiraEm: .now.addingTimeInterval(10 * 86_400))
        await f.vm.carregarEstado()
        let faixa = try #require(f.vm.textoFaixa)
        #expect(faixa.hasPrefix("Teste grátis até "))
        // "Teste grátis até DD/MM" (5 caracteres de data).
        #expect(faixa.count == "Teste grátis até ".count + 5)

        f.responder(status: "active", temAcesso: true)
        await f.vm.carregarEstado()
        #expect(f.vm.textoFaixa == nil)
    }
}
