//
//  ComprasAguardandoViagem.swift
//  SoftexVamo
//
//  Fila "sem viagem" das compras do Apple Pay (§1.5 de
//  docs/cartao-sem-open-finance.md).
//

import Foundation
import os

/// Compra do Apple Pay que chegou sem viagem aberta. Fica na fila até o usuário
/// lançar numa viagem ou descartar; nunca sai sozinha por tempo.
nonisolated struct CompraAguardandoViagem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var userId: String
    var valor: Decimal
    var estabelecimento: String
    var cartao: String?
    var categoria: Categoria
    var recebidaEm: Date
}

/// A fila é um arquivo JSON em `Application Support/compras-apple-pay.json`,
/// com escrita atômica — fora do SwiftData de propósito: mudar um `@Model`
/// exigiria congelar o schema V1 e criar o V2 com migração, custo e risco
/// grandes para uma lista pequena e passageira.
///
/// O arquivo usa a proteção padrão do iOS (disponível depois do primeiro
/// desbloqueio), para a ação "Registrar gasto" rodar com o aparelho trancado.
/// Arquivo ausente lê como lista vazia, sem derrubar o app. Arquivo corrompido
/// é movido para `compras-apple-pay.json.corrompido-<data>-<uuid>` e lê como
/// lista vazia (`QuarentenaArquivo`; a poda deixa só as 5 cópias mais novas) —
/// sobrescrever direto perderia os itens de todos os usuários.
/// Arquivo que existe mas não lê (permissão, I/O) faz `adicionar`/`remover`
/// abortarem: ler como vazio deixaria a próxima gravação apagar a fila
/// inteira. A regra de arquivo é a `ArquivoJSONGuardado`, a mesma da lista
/// de cartões.
///
/// Toda leitura e gravação passa por `trava`: `adicionar`/`remover` leem e
/// regravam o arquivo inteiro e, sem serializar, ação e folha mexendo juntas
/// na fila perderiam itens.
final class ComprasAguardandoViagem {
    /// Teto de itens por usuário; passando, a mais antiga sai.
    static let tetoPorUsuario = 50

    static let shared = ComprasAguardandoViagem()

    private static let logger = Logger(subsystem: "br.com.softspend", category: "ComprasAguardandoViagem")

    /// Serializa ler+regravar o arquivo inteiro.
    private let trava = NSLock()

    let arquivo: URL

    /// Regra de ler/gravar/quarentenar o JSON (sempre chamada sob `trava`).
    private let guarda: ArquivoJSONGuardado<CompraAguardandoViagem>

    init(arquivo: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.arquivo = arquivo ?? dir.appendingPathComponent("compras-apple-pay.json")
        self.guarda = ArquivoJSONGuardado(arquivo: self.arquivo, nomeNoLog: "Fila")
    }

    /// Itens do usuário. Os de outros usuários ficam no arquivo, intocados e
    /// escondidos — tudo filtra por `userId`.
    func ler(userId: String) -> [CompraAguardandoViagem] {
        todas().filter { $0.userId == userId }
    }

    func todas() -> [CompraAguardandoViagem] {
        trava.lock()
        defer { trava.unlock() }
        do {
            return try guarda.ler()
        } catch {
            Self.logger.error("Não leu a fila: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// O `id` ainda está na fila? Conferido antes do "Lançar" gravar: a lista
    /// da folha é uma cópia e um toque duplo lançaria a mesma compra duas vezes.
    /// Falha na leitura devolve `false` — o `lancar` vira no-op em vez de criar
    /// um gasto sem conseguir tirar o item da fila.
    func contem(id: UUID) -> Bool {
        trava.lock()
        defer { trava.unlock() }
        return ((try? guarda.ler()) ?? []).contains { $0.id == id }
    }

    /// Guarda a compra e **lança** quando a gravação falha — `registrar`
    /// responde erro ("lance no app") em vez de "guardado" com a compra perdida.
    func adicionar(_ compra: CompraAguardandoViagem) throws {
        trava.lock()
        defer { trava.unlock() }
        var lista = try guarda.ler()
        lista.append(compra)

        let doUsuario = lista.filter { $0.userId == compra.userId }
        let excedente = doUsuario.count - Self.tetoPorUsuario
        if excedente > 0 {
            let maisAntigas = Set(doUsuario
                .sorted { $0.recebidaEm < $1.recebidaEm }
                .prefix(excedente)
                .map(\.id))
            lista.removeAll { maisAntigas.contains($0.id) }
        }

        try guarda.gravar(lista)
    }

    /// Tira o item da fila. Falha na leitura ou na gravação só sai no log e
    /// deixa o item — o usuário pode tentar de novo; nunca some compra sem
    /// querer (nem grava uma lista "vazia" por cima de um arquivo ilegível).
    func remover(id: UUID) {
        trava.lock()
        defer { trava.unlock() }
        var lista: [CompraAguardandoViagem]
        do {
            lista = try guarda.ler()
        } catch {
            Self.logger.error("Não leu a fila para remover: \(error.localizedDescription, privacy: .public)")
            return
        }
        lista.removeAll { $0.id == id }
        do {
            try guarda.gravar(lista)
        } catch {
            Self.logger.error("Não gravou a fila depois de remover: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tira da fila todos os itens do usuário — excluir a conta apaga os
    /// dados locais dela (docs/publicacao.md §2, "Exclusão de conta"). Os de
    /// outros usuários ficam. Mesmas regras de falha do `remover(id:)`: só
    /// loga e deixa o arquivo como está.
    func removerTodos(userId: String) {
        trava.lock()
        defer { trava.unlock() }
        var lista: [CompraAguardandoViagem]
        do {
            lista = try guarda.ler()
        } catch {
            Self.logger.error("Não leu a fila para remover todos: \(error.localizedDescription, privacy: .public)")
            return
        }
        let restantes = lista.filter { $0.userId != userId }
        guard restantes.count != lista.count else { return }
        do {
            try guarda.gravar(restantes)
        } catch {
            Self.logger.error("Não gravou a fila depois de remover todos: \(error.localizedDescription, privacy: .public)")
        }
    }
}
