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

    /// O carimbo é fixo em UTC, não no fuso do aparelho: quem viaja de fuso
    /// não pode gerar nome fora de ordem (a poda apagaria a cópia mais nova
    /// e guardaria uma velha). 2026-07-21 01:30 UTC dá "20260721-013000"; em
    /// UTC-3 o mesmo instante sairia "20260720-223000", um nome que ordena
    /// antes do de um instante anterior em UTC. `TimeZone.current` não é
    /// mutado — estado global do processo flakaria testes em paralelo; o
    /// formatador de UTC-3 ao lado mostra o que o fuso fixo evita.
    @Test func carimboEhUtcIndependenteDoFusoDoAparelho() {
        #expect(QuarentenaArquivo.carimbo.timeZone == TimeZone(identifier: "UTC"))

        let data = Date(timeIntervalSince1970: 1_784_597_400) // 2026-07-21 01:30 UTC
        #expect(QuarentenaArquivo.carimbo.string(from: data) == "20260721-013000")

        let fusoMenosTres = DateFormatter()
        fusoMenosTres.locale = Locale(identifier: "en_US_POSIX")
        fusoMenosTres.timeZone = TimeZone(identifier: "America/Sao_Paulo")
        fusoMenosTres.dateFormat = "yyyyMMdd-HHmmss"
        #expect(fusoMenosTres.string(from: data) == "20260720-223000")
    }

    /// Datas crescentes geram carimbos em ordem alfabética crescente — é o
    /// que faz `sorted().dropLast(5)` da poda guardar as cópias mais novas.
    @Test func carimbosDeDatasCrescentesOrdenamPeloNome() {
        let base = Date(timeIntervalSince1970: 1_784_597_400)
        let carimbos = (0..<5)
            .map { base.addingTimeInterval(TimeInterval($0) * 90_000) } // 25 h, cruza dias
            .map { QuarentenaArquivo.carimbo.string(from: $0) }
        #expect(Set(carimbos).count == 5)
        #expect(carimbos == carimbos.sorted())
    }
}
