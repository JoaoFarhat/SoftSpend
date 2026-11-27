//
//  ArquivoJSONGuardado.swift
//  SoftexVamo
//
//  Regra de arquivo das listas JSON fora do SwiftData — a fila "sem viagem"
//  das compras do Apple Pay e a lista de cartões (§1.5 e §1.10 de
//  docs/cartao-sem-open-finance.md).
//

import Foundation
import os

/// Lê e grava um arquivo JSON que guarda uma lista de `Item`. As regras,
/// iguais nos dois usos (fila e cartões):
///
/// - **Ausente lê como lista vazia**, sem derrubar o app.
/// - **Existe mas não lê** (permissão, I/O) **lança**: ler como vazio deixaria
///   a próxima gravação escrever `[]` por cima e a lista inteira — de todos
///   os usuários do aparelho — se perderia.
/// - **JSON que não decodifica** é movido para quarentena
///   (`<nome>.corrompido-<yyyyMMdd-HHmmss>-<uuid curto>`) e lê como lista
///   vazia — o corrompido fica guardado, recuperável, em vez de sobrescrito.
///   O uuid curto no fim do nome é o que torna o destino único: só o carimbo
///   de segundo fazia dois arquivos corrompidos no mesmo segundo darem
///   `moveItem` num destino que já existe, e a leitura lançava ("lance no
///   app") sem motivo.
/// - **Move da quarentena que falha lança** — o arquivo ruim não pode ficar
///   para ser sobrescrito na próxima gravação.
/// - `gravar` é atômico (`.atomic`).
///
/// O tipo não serializa nada: quem usa segura a própria trava (ler+regravar o
/// arquivo inteiro não pode correr duas vezes ao mesmo tempo).
nonisolated struct ArquivoJSONGuardado<Item: Codable>: Sendable {
    let arquivo: URL

    /// Nome no log de quarentena (ex.: "Fila", "Lista de cartões"), para a
    /// mensagem continuar dizendo de qual arquivo se trata.
    let nomeNoLog: String

    private static let logger = Logger(subsystem: "br.com.softspend", category: "ArquivoJSONGuardado")

    init(arquivo: URL, nomeNoLog: String) {
        self.arquivo = arquivo
        self.nomeNoLog = nomeNoLog
    }

    /// Lê a lista. Ausente devolve `[]`; existe e não lê lança; JSON inválido
    /// vai para quarentena e devolve `[]` (move que falha lança).
    func ler() throws -> [Item] {
        let dados: Data
        do {
            dados = try Data(contentsOf: arquivo)
        } catch {
            guard FileManager.default.fileExists(atPath: arquivo.path) else {
                return []
            }
            throw error
        }
        guard let lista = try? JSONDecoder().decode([Item].self, from: dados) else {
            try quarentenar()
            return []
        }
        return lista
    }

    func gravar(_ itens: [Item]) throws {
        let dados = try JSONEncoder().encode(itens)
        try dados.write(to: arquivo, options: .atomic)
    }

    /// Move o arquivo ilegível para
    /// `<nome>.corrompido-<yyyyMMdd-HHmmss>-<uuid curto>` (nome único: dois
    /// corrompidos no mesmo segundo não dividem destino). Se o move falha,
    /// lança — o arquivo ruim não pode ficar para ser sobrescrito na próxima
    /// gravação.
    private func quarentenar() throws {
        let copia = QuarentenaArquivo.destino(para: arquivo, em: .now)
        do {
            try FileManager.default.moveItem(at: arquivo, to: copia)
            Self.logger.error("\(self.nomeNoLog, privacy: .public) corrompida movida para \(copia.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("\(self.nomeNoLog, privacy: .public) corrompida; não deu para mover: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        QuarentenaArquivo.podar(de: arquivo)
    }
}
