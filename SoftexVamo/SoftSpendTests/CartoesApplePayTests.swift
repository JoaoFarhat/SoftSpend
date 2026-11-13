import Testing
import Foundation
@testable import SoftSpend

/// Lista JSON de cartões do Apple Pay com a chave liga/desliga do Perfil
/// (§1.10 de docs/cartao-sem-open-finance.md): arquivo temporário por teste.
@MainActor
struct CartoesApplePayTests {
    let arquivo: URL
    let cartoes: CartoesApplePay
    let userId = "u1"

    init() {
        arquivo = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartoes-\(UUID().uuidString).json")
        cartoes = CartoesApplePay(arquivo: arquivo)
    }

    @Test func nomeNormalizadoAparaECobreOVazio() {
        #expect(CartoesApplePay.nomeNormalizado("  Nubank  ") == "Nubank")
        #expect(CartoesApplePay.nomeNormalizado("Nubank") == "Nubank")
        #expect(CartoesApplePay.nomeNormalizado("") == "Cartão sem nome")
        #expect(CartoesApplePay.nomeNormalizado("   ") == "Cartão sem nome")
        #expect(CartoesApplePay.nomeNormalizado(nil) == "Cartão sem nome")
        #expect(CartoesApplePay.nomePadrao == "Cartão sem nome")
    }

    @Test func chegadaDeCartaoNovoEntraLigadoESobreviveReleitura() throws {
        #expect(cartoes.ler(userId: userId).isEmpty)

        let ligado = try cartoes.registrarChegada(
            nome: "Nubank", userId: userId,
            vistoEm: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(ligado)

        // Sobrevive a uma instância nova no mesmo arquivo (leu o JSON).
        let relida = CartoesApplePay(arquivo: arquivo)
        let lista = relida.ler(userId: userId)
        try #require(lista.count == 1)
        #expect(lista[0].nome == "Nubank")
        #expect(lista[0].ligado)
        #expect(lista[0].vistoEm == Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func chegadaRepetidaNaoDuplicaEAtualizaVistoEm() throws {
        try cartoes.registrarChegada(nome: "Nubank", userId: userId,
                                   vistoEm: Date(timeIntervalSince1970: 1))
        let maisRecente = Date(timeIntervalSince1970: 2)
        try cartoes.registrarChegada(nome: "Nubank", userId: userId, vistoEm: maisRecente)

        let lista = cartoes.ler(userId: userId)
        try #require(lista.count == 1)
        #expect(lista[0].vistoEm == maisRecente)
    }

    @Test func desligarEReligar() throws {
        try cartoes.registrarChegada(nome: "Nubank", userId: userId)
        cartoes.definirLigado(nome: "Nubank", userId: userId, ligado: false)
        #expect(cartoes.ler(userId: userId).first?.ligado == false)
        // Chegada com o cartão desligado avisa para ignorar.
        #expect(try cartoes.registrarChegada(nome: "Nubank", userId: userId) == false)

        cartoes.definirLigado(nome: "Nubank", userId: userId, ligado: true)
        #expect(cartoes.ler(userId: userId).first?.ligado == true)
        #expect(try cartoes.registrarChegada(nome: "Nubank", userId: userId) == true)
    }

    @Test func isolamentoPorUsuario() throws {
        try cartoes.registrarChegada(nome: "Nubank", userId: "u1")
        try cartoes.registrarChegada(nome: "Nubank", userId: "u2")
        cartoes.definirLigado(nome: "Nubank", userId: "u1", ligado: false)

        // Desligar para um usuário não mexe no cartão do outro.
        #expect(try cartoes.registrarChegada(nome: "Nubank", userId: "u1") == false)
        #expect(try cartoes.registrarChegada(nome: "Nubank", userId: "u2") == true)
        #expect(cartoes.ler(userId: "u1").count == 1)
        #expect(cartoes.ler(userId: "u2").count == 1)
        #expect(cartoes.todos().count == 2)
    }

    @Test func listaVemMaisRecentesPrimeiro() throws {
        try cartoes.registrarChegada(nome: "Antigo", userId: userId,
                                     vistoEm: Date(timeIntervalSince1970: 1))
        try cartoes.registrarChegada(nome: "Recente", userId: userId,
                                     vistoEm: Date(timeIntervalSince1970: 2))
        #expect(cartoes.ler(userId: userId).map(\.nome) == ["Recente", "Antigo"])
    }

    /// Arquivo corrompido lê como lista vazia e vai para quarentena — os
    /// cartões dos outros usuários não se perdem num arquivo recuperável.
    @Test func arquivoCorrompidoVaiParaQuarentenaELeComoVazio() throws {
        try Data("lixo não-json".utf8).write(to: arquivo)
        #expect(cartoes.todos().isEmpty)
        #expect(cartoes.ler(userId: userId).isEmpty)

        let backups = try FileManager.default.contentsOfDirectory(
            at: arquivo.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("\(arquivo.lastPathComponent).corrompido-")
        }
        try #require(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == "lixo não-json")
        #expect(!FileManager.default.fileExists(atPath: arquivo.path))

        // E continua funcionando: a próxima gravação cria um arquivo novo.
        try cartoes.registrarChegada(nome: "Nubank", userId: userId)
        #expect(cartoes.ler(userId: userId).count == 1)
    }

    /// Arquivo que existe mas não lê (permissão) não pode virar lista vazia:
    /// `registrarChegada` lança em vez de sobrescrever os cartões de todos os
    /// usuários, e `ler` segue devolvendo vazio sem derrubar o app.
    @Test func arquivoIlegivelFazRegistrarChegadaLancar() throws {
        try cartoes.registrarChegada(nome: "Nubank", userId: userId)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: arquivo.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: arquivo.path)
        }

        #expect(cartoes.ler(userId: userId).isEmpty)
        #expect(throws: (any Error).self) {
            try cartoes.registrarChegada(nome: "Inter", userId: userId)
        }

        // Voltou a permissão, a lista continua lá — nada foi sobrescrito.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: arquivo.path)
        #expect(cartoes.ler(userId: userId).map(\.nome) == ["Nubank"])
    }

    /// Pasta que não existe: a escrita atômica falha e `registrarChegada`
    /// lança — a ação responde "lance no app".
    @Test func registrarEmPastaInexistenteLanca() {
        let quebrada = CartoesApplePay(
            arquivo: FileManager.default.temporaryDirectory
                .appendingPathComponent("pasta-\(UUID().uuidString)")
                .appendingPathComponent("cartoes.json"))
        #expect(throws: (any Error).self) {
            try quebrada.registrarChegada(nome: "Nubank", userId: userId)
        }
        #expect(quebrada.ler(userId: userId).isEmpty)
    }

    /// Nome que a automação manda é texto livre: aparado e cortado em 60.
    @Test func nomeLongoECortadoEm60() {
        let longo = String(repeating: "x", count: 100)
        let esperado = String(repeating: "x", count: CartoesApplePay.tamanhoMaximoNome)
        #expect(CartoesApplePay.tamanhoMaximoNome == 60)
        #expect(CartoesApplePay.nomeNormalizado(longo) == esperado)
        #expect(CartoesApplePay.nomeNormalizado("  \(longo)  ") == esperado)
        #expect(CartoesApplePay.nomeNormalizado("Nubank") == "Nubank")
    }

    /// Pasta só de leitura: o arquivo lê, mas a escrita atômica não consegue
    /// criar o temporário. Cartão conhecido só perde o `vistoEm` (cosmético)
    /// e devolve o `ligado` lido — a compra de um cartão ligado não é
    /// impedida; cartão novo continua lançando, porque sumiria da lista.
    @Test func falhaDeGravacaoComCartaoConhecidoDevolveOLigadoLido() throws {
        let pasta = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let arquivoNaPasta = pasta.appendingPathComponent("cartoes.json")
        let naPasta = CartoesApplePay(arquivo: arquivoNaPasta)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: pasta.path)
            try? FileManager.default.removeItem(at: pasta)
        }

        try naPasta.registrarChegada(nome: "Nubank", userId: userId,
                                     vistoEm: Date(timeIntervalSince1970: 1))
        try naPasta.registrarChegada(nome: "Inter", userId: userId,
                                     vistoEm: Date(timeIntervalSince1970: 2))
        naPasta.definirLigado(nome: "Inter", userId: userId, ligado: false)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: pasta.path)

        // Ligado e desligado devolvem o valor lido, sem lançar.
        #expect(try naPasta.registrarChegada(nome: "Nubank", userId: userId,
                                             vistoEm: Date(timeIntervalSince1970: 99)))
        #expect(try naPasta.registrarChegada(nome: "Inter", userId: userId) == false)
        #expect(throws: (any Error).self) {
            try naPasta.registrarChegada(nome: "C6", userId: userId)
        }

        // Voltou a permissão: a lista está intacta e o vistoEm não foi gravado.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: pasta.path)
        let relida = CartoesApplePay(arquivo: arquivoNaPasta).ler(userId: userId)
        try #require(relida.count == 2)
        #expect(relida.first { $0.nome == "Nubank" }?.vistoEm == Date(timeIntervalSince1970: 1))
        #expect(relida.first { $0.nome == "Inter" }?.ligado == false)
    }

    /// Chegando o 21º, sai o de `vistoEm` mais antigo que esteja ligado; os
    /// desligados ficam — voltariam ligados sozinhos pela ação.
    @Test func vigesimoPrimeiroTiraOMaisAntigoLigadoEMantemDesligados() throws {
        for i in 1...CartoesApplePay.maximoPorUsuario {
            try cartoes.registrarChegada(
                nome: String(format: "Cartao%02d", i), userId: userId,
                vistoEm: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        // O mais antigo fica desligado: nunca sai.
        cartoes.definirLigado(nome: "Cartao01", userId: userId, ligado: false)

        try cartoes.registrarChegada(nome: "Cartao21", userId: userId,
                                     vistoEm: Date(timeIntervalSince1970: 21))

        let lista = cartoes.ler(userId: userId)
        try #require(lista.count == CartoesApplePay.maximoPorUsuario)
        let nomes = Set(lista.map(\.nome))
        // Saiu o mais antigo ligado; o desligado ficou e o novo entrou.
        #expect(!nomes.contains("Cartao02"))
        #expect(nomes.contains("Cartao01"))
        #expect(lista.first { $0.nome == "Cartao01" }?.ligado == false)
        #expect(nomes.contains("Cartao21"))
        #expect(nomes.contains("Cartao03") && nomes.contains("Cartao20"))
    }

    /// O teto é por usuário: o 21º do u1 não toca nos cartões do u2.
    @Test func tetoNaoTocaNosCartoesDeOutroUsuario() throws {
        for i in 1...CartoesApplePay.maximoPorUsuario {
            try cartoes.registrarChegada(
                nome: String(format: "Cartao%02d", i), userId: "u1",
                vistoEm: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        try cartoes.registrarChegada(nome: "Cartao01", userId: "u2",
                                     vistoEm: Date(timeIntervalSince1970: 1))

        try cartoes.registrarChegada(nome: "Cartao21", userId: "u1",
                                     vistoEm: Date(timeIntervalSince1970: 21))

        let doU1 = cartoes.ler(userId: "u1")
        #expect(doU1.count == CartoesApplePay.maximoPorUsuario)
        #expect(!doU1.contains { $0.nome == "Cartao01" })
        #expect(doU1.contains { $0.nome == "Cartao21" })

        let doU2 = cartoes.ler(userId: "u2")
        try #require(doU2.count == 1)
        #expect(doU2[0].nome == "Cartao01")
        #expect(cartoes.todos().count == CartoesApplePay.maximoPorUsuario + 1)
    }
}
