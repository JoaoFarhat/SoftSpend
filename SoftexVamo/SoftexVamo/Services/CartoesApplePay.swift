//
//  CartoesApplePay.swift
//  SoftexVamo
//
//  Cartões que já chegaram pela ação "Registrar gasto" e a chave liga/desliga
//  de cada um no Perfil (§1.10 de docs/cartao-sem-open-finance.md).
//

import Foundation
import os

/// Cartão que já chegou pela ação "Registrar gasto". O `nome` é o `cartao`
/// do intent aparado; compra sem nome de cartão entra como `nomePadrao`.
nonisolated struct CartaoApplePay: Codable, Identifiable, Equatable, Sendable {
    var userId: String
    var nome: String
    /// Nasce ligado; desligado, a compra é ignorada antes de gravar ou ir
    /// para a fila. Desligar não apaga os gastos já lançados.
    var ligado: Bool
    /// Última compra vista; ordena a lista do Perfil, mais recentes primeiro.
    var vistoEm: Date

    /// O nome é único dentro do usuário e a lista do Perfil é por usuário.
    var id: String { nome }
}

/// Lista de cartões conhecidos em `Application Support/cartoes-apple-pay.json`
/// — fora do SwiftData pelo mesmo motivo da `ComprasAguardandoViagem`: uma
/// lista pequena não justifica congelar o schema V1 e criar o V2.
///
/// Mesmas regras de arquivo da fila: proteção padrão do iOS (a ação roda com o
/// aparelho trancado), escrita atômica e ler+regravar serializado por `trava`.
/// Arquivo ausente lê como lista vazia; corrompido vai para
/// `.corrompido-<data>` (os cartões dos outros usuários não se perdem num
/// arquivo que dá para recuperar). Arquivo que existe mas não lê faz
/// `registrarChegada` **lançar**: ler como vazio deixaria a gravação apagar a
/// lista inteira — e sem a lista não dá para saber se o cartão está
/// desligado.
final class CartoesApplePay {
    /// Nome guardado quando a automação não manda o cartão (ou manda vazio).
    static let nomePadrao = "Cartão sem nome"

    /// Teto do nome guardado: a automação manda texto livre e a lista do
    /// Perfil não precisa de mais que isso para identificar o cartão.
    static let tamanhoMaximoNome = 60

    /// Teto de cartões por usuário. Chegando o 21º, sai o de `vistoEm` mais
    /// antigo **que esteja ligado** — um desligado nunca sai, porque ao
    /// voltar pela ação entraria ligado de novo, desfazendo a escolha do
    /// usuário. Se os 20 estiverem desligados, a lista passa de 20.
    static let maximoPorUsuario = 20

    static let shared = CartoesApplePay()

    private static let logger = Logger(subsystem: "br.com.softspend", category: "CartoesApplePay")

    /// Serializa ler+regravar o arquivo inteiro.
    private let trava = NSLock()

    let arquivo: URL

    init(arquivo: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.arquivo = arquivo ?? dir.appendingPathComponent("cartoes-apple-pay.json")
    }

    /// `cartao` do `RegistrarGastoIntent` vira o nome guardado: aparado,
    /// cortado em `tamanhoMaximoNome` caracteres, e vazio ou ausente vira
    /// `nomePadrao`.
    static func nomeNormalizado(_ cartao: String?) -> String {
        let limpo = (cartao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cortado = String(limpo.prefix(tamanhoMaximoNome))
        return cortado.isEmpty ? nomePadrao : cortado
    }

    /// Cartões do usuário, mais recentes primeiro (a lista do Perfil). Os de
    /// outros usuários ficam no arquivo, intocados e escondidos.
    func ler(userId: String) -> [CartaoApplePay] {
        todos().filter { $0.userId == userId }
            .sorted { $0.vistoEm != $1.vistoEm ? $0.vistoEm > $1.vistoEm : $0.nome < $1.nome }
    }

    /// Todos os cartões, de todos os usuários. Falha na leitura devolve lista
    /// vazia, sem derrubar o app.
    func todos() -> [CartaoApplePay] {
        trava.lock()
        defer { trava.unlock() }
        do {
            return try todosTrancado()
        } catch {
            Self.logger.error("Não leu os cartões: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Marca a chegada de uma compra do cartão: nome novo entra **ligado**,
    /// conhecido só atualiza `vistoEm`. Devolve se o cartão está ligado — o
    /// `registrar` ignora a compra quando `false`. **Lança** quando a leitura
    /// falha: sem a lista não dá para saber se o cartão está desligado,
    /// então a ação responde "lance no app" em vez de gravar a compra que o
    /// usuário mandou ignorar. Na gravação, lança só para cartão novo (ele
    /// sumiria da lista); para cartão conhecido o `vistoEm` é cosmético —
    /// só sai no log e o `ligado` lido é devolvido, sem impedir a compra.
    @discardableResult
    func registrarChegada(nome: String, userId: String, vistoEm: Date = .now) throws -> Bool {
        trava.lock()
        defer { trava.unlock() }
        var lista = try todosTrancado()
        if let i = lista.firstIndex(where: { $0.userId == userId && $0.nome == nome }) {
            let ligado = lista[i].ligado
            lista[i].vistoEm = vistoEm
            do {
                try gravar(lista)
            } catch {
                Self.logger.error("Não gravou o vistoEm do cartão: \(error.localizedDescription, privacy: .public)")
            }
            return ligado
        }
        if let vitima = cartaoParaSair(da: lista, userId: userId) {
            lista.remove(at: vitima)
        }
        lista.append(CartaoApplePay(userId: userId, nome: nome, ligado: true, vistoEm: vistoEm))
        try gravar(lista)
        return true
    }

    /// Com a lista do usuário já no teto, escolhe o índice do cartão ligado
    /// com `vistoEm` mais antigo para sair; `nil` quando ainda cabe ou quando
    /// todos são desligados (nunca saem — voltariam ligados sozinhos).
    private func cartaoParaSair(da lista: [CartaoApplePay], userId: String) -> Int? {
        let doUsuario = lista.indices.filter { lista[$0].userId == userId }
        guard doUsuario.count >= Self.maximoPorUsuario else { return nil }
        return doUsuario.filter { lista[$0].ligado }
            .min { lista[$0].vistoEm < lista[$1].vistoEm }
    }

    /// Liga ou desliga o cartão (a chave do Perfil). Falha na leitura ou na
    /// gravação só sai no log e deixa a lista como estava — nunca grava uma
    /// lista vazia por cima de um arquivo ilegível.
    func definirLigado(nome: String, userId: String, ligado: Bool) {
        trava.lock()
        defer { trava.unlock() }
        var lista: [CartaoApplePay]
        do {
            lista = try todosTrancado()
        } catch {
            Self.logger.error("Não leu os cartões para ligar/desligar: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let i = lista.firstIndex(where: { $0.userId == userId && $0.nome == nome }) else { return }
        lista[i].ligado = ligado
        do {
            try gravar(lista)
        } catch {
            Self.logger.error("Não gravou os cartões depois de ligar/desligar: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tira da lista todos os cartões do usuário — excluir a conta apaga os
    /// dados locais dela (docs/publicacao.md §2, "Exclusão de conta"). Os de
    /// outros usuários ficam. Mesmas regras de falha do `definirLigado`: só
    /// loga e deixa o arquivo como está.
    func removerTodos(userId: String) {
        trava.lock()
        defer { trava.unlock() }
        var lista: [CartaoApplePay]
        do {
            lista = try todosTrancado()
        } catch {
            Self.logger.error("Não leu os cartões para remover todos: \(error.localizedDescription, privacy: .public)")
            return
        }
        let restantes = lista.filter { $0.userId != userId }
        guard restantes.count != lista.count else { return }
        do {
            try gravar(restantes)
        } catch {
            Self.logger.error("Não gravou os cartões depois de remover todos: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Arquivo (sempre chamado sob `trava`) — mesmas regras da fila

    /// Lê o arquivo. Ausente lê como lista vazia. Corrompido (JSON que não
    /// decodifica) é movido para `….corrompido-<data>` e lê como lista vazia.
    /// Arquivo que existe mas não lê (permissão, I/O) **lança**.
    private func todosTrancado() throws -> [CartaoApplePay] {
        let dados: Data
        do {
            dados = try Data(contentsOf: arquivo)
        } catch {
            guard FileManager.default.fileExists(atPath: arquivo.path) else {
                return []
            }
            throw error
        }
        guard let lista = try? JSONDecoder().decode([CartaoApplePay].self, from: dados) else {
            try quarentenar()
            return []
        }
        return lista
    }

    /// Move o arquivo ilegível para `<nome>.corrompido-<yyyyMMdd-HHmmss>`
    /// (nome único). Se o move falha, lança — o arquivo ruim não pode ficar
    /// para ser sobrescrito na próxima gravação.
    private func quarentenar() throws {
        let copia = arquivo.appendingPathExtension("corrompido-\(Self.carimbo.string(from: .now))")
        do {
            try FileManager.default.moveItem(at: arquivo, to: copia)
            Self.logger.error("Lista de cartões corrompida movida para \(copia.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("Lista de cartões corrompida; não deu para mover: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static let carimbo: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func gravar(_ lista: [CartaoApplePay]) throws {
        let dados = try JSONEncoder().encode(lista)
        try dados.write(to: arquivo, options: .atomic)
    }
}
