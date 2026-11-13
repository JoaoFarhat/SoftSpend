import Foundation
import os

/// Compra do Apple Pay recebida pela ação de Atalhos sem uma viagem aberta
/// para lançá-la (§1.5 de docs/cartao-sem-open-finance.md).
///
/// Fila fora do SwiftData: mexer num `@Model` exigiria congelar o V1 e criar o
/// V2 com migração — custo e risco demais para uma lista pequena e passageira.
/// A fila é um JSON em `Application Support/compras-apple-pay.json`, por
/// usuário. Nunca sai sozinha por tempo: só quando o usuário lança ou descarta.
nonisolated struct CompraAguardandoViagem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var userId: String
    var valor: Decimal
    var estabelecimento: String
    var cartao: String?
    var categoria: Categoria
    var recebidaEm: Date
}

/// Lê e grava a fila com escrita atômica. Arquivo corrompido vira lista vazia,
/// sem derrubar o app.
final class ComprasAguardandoViagem {
    /// Máximo de itens por usuário; passando, os mais antigos dele saem.
    static let teto = 50
    /// A fila de produção: `Application Support/compras-apple-pay.json`.
    static let padrao = ComprasAguardandoViagem()

    private let urlArquivo: URL
    private let logger = Logger(subsystem: "br.com.softspend", category: "ComprasAguardandoViagem")

    /// `diretorio` é injetável para os testes (um diretório temporário por teste).
    init(diretorio: URL? = nil) {
        let base = diretorio
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.urlArquivo = base.appendingPathComponent("compras-apple-pay.json")
    }

    /// Os itens do usuário, do mais antigo para o mais novo. Itens de outro
    /// usuário ficam intocados e escondidos.
    func ler(userId: String) -> [CompraAguardandoViagem] {
        lerTodas()
            .filter { $0.userId == userId }
            .sorted { $0.recebidaEm < $1.recebidaEm }
    }

    /// Entra na fila. Passando do teto dele, as mais antigas do mesmo usuário saem.
    func guardar(_ compra: CompraAguardandoViagem) {
        var itens = lerTodas()
        itens.append(compra)
        while let maisAntiga = maisAntiga(compra.userId, em: itens),
              itens.filter({ $0.userId == compra.userId }).count > Self.teto {
            itens.removeAll { $0.id == maisAntiga.id }
        }
        gravar(itens)
    }

    /// Sai da fila (lançada ou descartada). O id é do item, não do usuário:
    /// remover só é chamado com itens já filtrados pelo usuário logado.
    func remover(id: UUID) {
        var itens = lerTodas()
        itens.removeAll { $0.id == id }
        gravar(itens)
    }

    private func maisAntiga(_ userId: String, em itens: [CompraAguardandoViagem]) -> CompraAguardandoViagem? {
        itens.filter { $0.userId == userId }.min { $0.recebidaEm < $1.recebidaEm }
    }

    private func lerTodas() -> [CompraAguardandoViagem] {
        guard let dados = try? Data(contentsOf: urlArquivo) else { return [] }
        do {
            return try JSONDecoder().decode([CompraAguardandoViagem].self, from: dados)
        } catch {
            logger.error("Fila de compras corrompida, ignorando: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func gravar(_ itens: [CompraAguardandoViagem]) {
        do {
            let dados = try JSONEncoder().encode(itens)
            // Atômica: a ação de Atalhos e o app podem gravar quase juntos.
            // A proteção padrão do iOS deixa o arquivo disponível depois do
            // primeiro desbloqueio — a ação roda com o aparelho trancado.
            try dados.write(to: urlArquivo, options: [.atomic])
        } catch {
            logger.error("Falha ao gravar a fila de compras: \(error.localizedDescription, privacy: .public)")
        }
    }
}
