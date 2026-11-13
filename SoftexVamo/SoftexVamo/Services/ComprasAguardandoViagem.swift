import Foundation
import os

/// Compra do Apple Pay que chegou sem viagem aberta nem dia local de hoje
/// (§1.5 de `docs/cartao-sem-open-finance.md`). Fica na fila até o usuário
/// lançar numa viagem ou descartar — nunca sai sozinha por tempo.
nonisolated struct CompraAguardandoViagem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var userId: String
    var valor: Decimal
    var estabelecimento: String
    var cartao: String?
    var categoria: Categoria
    var recebidaEm: Date
}

/// A fila "sem viagem" do Apple Pay (§1.5).
///
/// Fica fora do SwiftData de propósito: um `@Model` novo exigiria congelar o
/// V1 e criar o V2 com migração, custo e risco grandes para uma lista pequena
/// e passageira. É um JSON em `Application Support/compras-apple-pay.json`,
/// por usuário, com teto de 50 itens — passando, a mais antiga sai.
///
/// A escrita é atômica e o arquivo usa a proteção padrão do iOS (disponível
/// depois do primeiro desbloqueio), para a ação rodar com o aparelho trancado.
/// Arquivo ausente ou corrompido vira lista vazia, sem derrubar o app.
nonisolated struct ComprasAguardandoViagem: Sendable {
    static let compartilhada = ComprasAguardandoViagem()
    static let teto = 50

    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.url = support.appendingPathComponent("compras-apple-pay.json")
        }
    }

    /// Os itens do usuário, da mais antiga para a mais nova.
    func itens(do userId: String) -> [CompraAguardandoViagem] {
        ler().filter { $0.userId == userId }.sorted { $0.recebidaEm < $1.recebidaEm }
    }

    /// Guarda a compra no fim da fila do usuário; passando do teto, a mais antiga sai.
    func adicionar(_ compra: CompraAguardandoViagem) {
        var todos = ler()
        todos.append(compra)
        let doUsuario = todos.filter { $0.userId == compra.userId }
        if doUsuario.count > Self.teto,
           let maisAntiga = doUsuario.min(by: { $0.recebidaEm < $1.recebidaEm }) {
            todos.removeAll { $0.id == maisAntiga.id }
        }
        gravar(todos)
    }

    /// Tira o item da fila (depois de lançado ou descartado pelo usuário).
    func remover(id: UUID) {
        gravar(ler().filter { $0.id != id })
    }

    private func ler() -> [CompraAguardandoViagem] {
        guard let data = try? Data(contentsOf: url),
              let itens = try? JSONDecoder().decode([CompraAguardandoViagem].self, from: data)
        else { return [] }
        return itens
    }

    private func gravar(_ itens: [CompraAguardandoViagem]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(itens)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("ComprasAguardandoViagem: falha ao gravar a fila: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "br.com.softspend", category: "ComprasAguardandoViagem")
}
