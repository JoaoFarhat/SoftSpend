import Testing
import Foundation
@testable import SoftSpend

/// Nome e poda dos `.corrompido-*` (`Services/QuarentenaArquivo.swift`):
/// pasta temporária por teste.
@MainActor
struct QuarentenaArquivoTests {
    let pasta: URL
    let arquivo: URL

    init() throws {
        pasta = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarentena-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        arquivo = pasta.appendingPathComponent("lista.json")
    }

    private func nomesNaPasta() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: pasta.path).sorted()
    }

    /// Mesmo carimbo (`agora` fixo): dois destinos gerados seguidos, como duas
    /// quarentenas no mesmo segundo, diferem pelo sufixo — sem o uuid curto
    /// o segundo `moveItem` caía em destino já existente e o erro subia.
    @Test func mesmoCarimboGeraDoisNomesDiferentes() throws {
        let agora = Date(timeIntervalSince1970: 1_780_000_000)

        let primeiro = QuarentenaArquivo.destino(para: arquivo, em: agora)
        try Data("lixo 1".utf8).write(to: arquivo)
        try FileManager.default.moveItem(at: arquivo, to: primeiro)

        let segundo = QuarentenaArquivo.destino(para: arquivo, em: agora)

        #expect(primeiro != segundo)
        // O carimbo é o mesmo nos dois — só o sufixo os separa.
        let prefixo = "\(arquivo.lastPathComponent).corrompido-"
        #expect(primeiro.lastPathComponent.dropFirst(prefixo.count).prefix(15)
            == segundo.lastPathComponent.dropFirst(prefixo.count).prefix(15))
    }

    /// A poda deixa só os `maximoGuardadas` mais novos (o carimbo ordena
    /// pelo nome) e não toca os outros arquivos da pasta.
    @Test func podaMantemSoOsCincoMaisNovos() throws {
        var nomes: [String] = []
        for i in 0..<7 {
            let nome = "\(arquivo.lastPathComponent).corrompido-2026112\(i)-000000-abcd"
            try Data("lixo \(i)".utf8).write(
                to: pasta.appendingPathComponent(nome))
            nomes.append(nome)
        }
        try Data("não é quarentena".utf8).write(to: arquivo)
        try Data("outro".utf8).write(to: pasta.appendingPathComponent("outro.json"))

        QuarentenaArquivo.podar(de: arquivo)

        let esperados = nomes.suffix(QuarentenaArquivo.maximoGuardadas)
            + [arquivo.lastPathComponent, "outro.json"]
        #expect(try nomesNaPasta() == esperados.sorted())
    }

    /// Menos de `maximoGuardadas` cópias: a poda não apaga nada. Pasta sem
    /// quarentena nenhuma também não lança.
    @Test func podaSemExcessoNaoApagaNada() throws {
        for i in 0..<3 {
            try Data("lixo".utf8).write(to: pasta.appendingPathComponent(
                "\(arquivo.lastPathComponent).corrompido-2026112\(i)-000000-abcd"))
        }

        QuarentenaArquivo.podar(de: arquivo)

        #expect(try nomesNaPasta().count == 3)

        let semPasta = pasta.appendingPathComponent("inexistente/lista.json")
        QuarentenaArquivo.podar(de: semPasta)
    }
}
