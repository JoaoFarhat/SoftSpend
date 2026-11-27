import Testing
import Foundation
@testable import SoftSpend

/// Regra de arquivo compartilhada pela fila "sem viagem" e pela lista de
/// cartões do Apple Pay (`Services/ArquivoJSONGuardado.swift`): arquivo
/// temporário por teste.
@MainActor
struct ArquivoJSONGuardadoTests {
    struct ItemDeTeste: Codable, Equatable {
        var id: Int
        var nome: String
    }

    let arquivo: URL
    let guarda: ArquivoJSONGuardado<ItemDeTeste>

    init() {
        arquivo = FileManager.default.temporaryDirectory
            .appendingPathComponent("guarda-\(UUID().uuidString).json")
        guarda = ArquivoJSONGuardado(arquivo: arquivo, nomeNoLog: "Lista de teste")
    }

    private func corrompidos() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: arquivo.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("\(arquivo.lastPathComponent).corrompido-")
        }
    }

    @Test func arquivoAusenteLeComoListaVazia() throws {
        #expect(try guarda.ler() == [])
    }

    /// JSON que não decodifica vai para `.corrompido-*` e lê como lista vazia
    /// — o arquivo recuperável não é sobrescrito.
    @Test func corrompidoVaiParaQuarentenaELeComoVazio() throws {
        try Data("lixo não-json".utf8).write(to: arquivo)

        #expect(try guarda.ler() == [])

        let backups = try corrompidos()
        try #require(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == "lixo não-json")
        #expect(!FileManager.default.fileExists(atPath: arquivo.path))
    }

    /// Duas quarentenas seguidas (mesmo segundo do carimbo) geram dois
    /// arquivos e nenhuma leitura lança — sem o uuid curto no nome, o segundo
    /// `moveItem` caía em destino já existente e o erro subia para a ação.
    @Test func duasQuarentenasNoMesmoSegundoGeramDoisArquivosENaoLancam() throws {
        try Data("lixo 1".utf8).write(to: arquivo)
        #expect(try guarda.ler() == [])

        try Data("lixo 2".utf8).write(to: arquivo)
        #expect(try guarda.ler() == [])

        let backups = try corrompidos()
        #expect(backups.count == 2)
        #expect(!FileManager.default.fileExists(atPath: arquivo.path))
        let conteudos = try Set(backups.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(conteudos == ["lixo 1", "lixo 2"])
    }

    @Test func gravarELerIdaEVolta() throws {
        let itens = [ItemDeTeste(id: 1, nome: "um"), ItemDeTeste(id: 2, nome: "dois")]

        try guarda.gravar(itens)

        #expect(try guarda.ler() == itens)
        // Sobrevive a uma instância nova no mesmo arquivo (leu o JSON).
        let relida = ArquivoJSONGuardado<ItemDeTeste>(arquivo: arquivo, nomeNoLog: "Lista de teste")
        #expect(try relida.ler() == itens)
    }
}
