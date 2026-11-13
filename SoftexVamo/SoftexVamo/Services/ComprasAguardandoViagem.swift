//
//  ComprasAguardandoViagem.swift
//  SoftexVamo
//
//  Fila "sem viagem" das compras do Apple Pay (§1.5 de
//  docs/cartao-sem-open-finance.md).
//

import Foundation

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
/// Arquivo ausente ou corrompido lê como lista vazia, sem derrubar o app.
final class ComprasAguardandoViagem {
    /// Teto de itens por usuário; passando, a mais antiga sai.
    static let tetoPorUsuario = 50

    static let shared = ComprasAguardandoViagem()

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
        guard let dados = try? Data(contentsOf: arquivo),
              let lista = try? JSONDecoder().decode([CompraAguardandoViagem].self, from: dados)
        else { return [] }
        return lista
    }

    func adicionar(_ compra: CompraAguardandoViagem) {
        var lista = todas()
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

        gravar(lista)
    }

    func remover(id: UUID) {
        var lista = todas()
        lista.removeAll { $0.id == id }
        gravar(lista)
    }

    private func gravar(_ lista: [CompraAguardandoViagem]) {
        guard let dados = try? JSONEncoder().encode(lista) else { return }
        try? dados.write(to: arquivo, options: .atomic)
    }
}
