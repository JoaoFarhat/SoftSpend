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
}
