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
/// é movido para `compras-apple-pay.json.corrompido` e lê como lista vazia —
/// sobrescrever direto perderia os itens de todos os usuários.
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

    init(arquivo: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.arquivo = arquivo ?? dir.appendingPathComponent("compras-apple-pay.json")
    }

    /// Itens do usuário. Os de outros usuários ficam no arquivo, intocados e
    /// escondidos — tudo filtra por `userId`.
    func ler(userId: String) -> [CompraAguardandoViagem] {
        todas().filter { $0.userId == userId }
    }

    func todas() -> [CompraAguardandoViagem] {
        trava.lock()
        defer { trava.unlock() }
        return todasTrancado()
    }

    /// O `id` ainda está na fila? Conferido antes do "Lançar" gravar: a lista
    /// da folha é uma cópia e um toque duplo lançaria a mesma compra duas vezes.
    func contem(id: UUID) -> Bool {
        trava.lock()
        defer { trava.unlock() }
        return todasTrancado().contains { $0.id == id }
    }

    /// Guarda a compra e **lança** quando a gravação falha — `registrar`
    /// responde erro ("lance no app") em vez de "guardado" com a compra perdida.
    func adicionar(_ compra: CompraAguardandoViagem) throws {
        trava.lock()
        defer { trava.unlock() }
        var lista = todasTrancado()
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

        try gravar(lista)
    }

    /// Tira o item da fila. Falha na gravação só sai no log e deixa o item —
    /// o usuário pode tentar de novo; nunca some compra sem querer.
    func remover(id: UUID) {
        trava.lock()
        defer { trava.unlock() }
        var lista = todasTrancado()
        lista.removeAll { $0.id == id }
        do {
            try gravar(lista)
        } catch {
            Self.logger.error("Não gravou a fila depois de remover: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Arquivo (sempre chamado sob `trava`)

    /// Lê o arquivo. Corrompido (JSON que não decodifica) é movido para
    /// `….corrompido` — guarda os itens dos outros usuários em vez de
    /// sobrescrever — e lê como lista vazia.
    private func todasTrancado() -> [CompraAguardandoViagem] {
        guard let dados = try? Data(contentsOf: arquivo) else { return [] }
        guard let lista = try? JSONDecoder().decode([CompraAguardandoViagem].self, from: dados) else {
            quarentenar()
            return []
        }
        return lista
    }

    /// Move o arquivo ilegível para `<nome>.corrompido` (um só backup: um
    /// corrompido anterior sai). Falha no move fica no log e a leitura segue
    /// como lista vazia.
    private func quarentenar() {
        let copia = arquivo.appendingPathExtension("corrompido")
        do {
            try? FileManager.default.removeItem(at: copia)
            try FileManager.default.moveItem(at: arquivo, to: copia)
            Self.logger.error("Fila corrompida movida para \(copia.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("Fila corrompida; não deu para mover: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func gravar(_ lista: [CompraAguardandoViagem]) throws {
        let dados = try JSONEncoder().encode(lista)
        try dados.write(to: arquivo, options: .atomic)
    }
}
