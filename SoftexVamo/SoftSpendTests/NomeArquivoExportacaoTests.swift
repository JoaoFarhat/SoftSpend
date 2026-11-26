import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// O título da viagem vira nome do arquivo temporário do relatório: "/" vira
/// subpasta inexistente e o `write` falha depois de o PDF já ter baixado, e
/// um título comprido pode passar do limite de nome de arquivo.
/// `nomeArquivoExportacao` só deixa letra, número, "-" e "_", corta em 60
/// caracteres e cai em "viagem" quando nada sobra.
@MainActor
struct NomeArquivoExportacaoTests {

    @Test func barraNoTituloNaoViraSubpasta() {
        let nome = CiclosViewModel.nomeArquivoExportacao(titulo: "SP 10/11", formato: .pdf)
        #expect(!nome.contains("/"))
        #expect(nome == "relatorio_SP-10-11.pdf")
    }

    @Test func tituloSoComInvalidosViraViagem() {
        #expect(CiclosViewModel.nomeArquivoExportacao(titulo: "///", formato: .pdf)
            == "relatorio_viagem.pdf")
        #expect(CiclosViewModel.nomeArquivoExportacao(titulo: "", formato: .csv)
            == "relatorio_viagem.csv")
    }

    @Test func acentosFicamNoNome() {
        // "ã" precomposto (U+00E3), como o teclado do iPhone digita.
        #expect(CiclosViewModel.nomeArquivoExportacao(titulo: "S\u{00E3}o Paulo", formato: .csv)
            == "relatorio_S\u{00E3}o-Paulo.csv")
    }

    @Test func tracosRepetidosEDasPontasSomem() {
        #expect(CiclosViewModel.nomeArquivoExportacao(titulo: " --Praia-- ", formato: .pdf)
            == "relatorio_Praia.pdf")
        #expect(CiclosViewModel.nomeArquivoExportacao(titulo: "ferias_2026", formato: .csv)
            == "relatorio_ferias_2026.csv")
    }

    @Test func tituloLongoComEmojiFicaCurto() {
        // 100 caracteres: 49 letras + espaço + 50 emoji.
        let titulo = String(repeating: "a", count: 49) + " "
            + String(repeating: "\u{1F389}", count: 50)
        #expect(titulo.count == 100)

        let nome = CiclosViewModel.nomeArquivoExportacao(titulo: titulo, formato: .pdf)

        #expect(nome.count <= 70)
        #expect(!nome.contains("/"))
        #expect(nome.hasPrefix("relatorio_"))
        #expect(nome.hasSuffix(".pdf"))
    }

    @Test func exportarComBarraNoTituloEscreveOArquivo() async throws {
        let api = FakeAssinaturaAPI()
        api.estado = AssinaturaResponse(
            status: "active", temAcesso: true, expiraEm: nil,
            produto: nil, appAccountToken: FakeAssinaturaAPI.token.uuidString)
        let assinatura = AssinaturaViewModel(
            loja: FakeLojaAssinatura(),
            api: api,
            usuarioLogado: { "usuario-1" },
            sincronizar: {}
        )
        await assinatura.carregarEstado()

        var envios = 0
        let vm = CiclosViewModel(estaConectado: { false })
        vm.pedirEnvio = { envios += 1 }
        vm.assinatura = assinatura
        let ciclo = CicloSoftex(valor_total: 600, gasto_total: 0, periodo: "",
                              diaria: 100, titulo: "SP/RJ", dias: [])
        ciclo.backendId = 7
        vm.atualCiclo = ciclo
        vm.exportarRemoto = { _, _, _ in Data([1, 2, 3]) }

        let resultado = try await vm.exportarCiclo(formato: .pdf)

        guard case .arquivo(let gerado) = resultado else {
            Issue.record("esperava .arquivo, veio \(resultado)")
            return
        }
        defer { try? FileManager.default.removeItem(at: gerado) }
        #expect(gerado.lastPathComponent == "relatorio_SP-RJ.pdf")
        #expect(FileManager.default.fileExists(atPath: gerado.path))
        #expect(try Data(contentsOf: gerado) == Data([1, 2, 3]))
    }
}
