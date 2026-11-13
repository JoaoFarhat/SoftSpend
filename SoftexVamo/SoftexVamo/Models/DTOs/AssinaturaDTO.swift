//
//  AssinaturaDTO.swift
//  SoftSpend
//
//  Corpo do `GET /api/assinatura` e do `POST /api/assinatura/transacoes`
//  (docs/assinatura.md §2.3 e AS1). O servidor é a única autoridade sobre o
//  acesso: o app só lê `tem_acesso`, nunca decide pelo StoreKit.
//

import Foundation

nonisolated struct AssinaturaResponse: Codable, Sendable, Equatable {
    /// `none`, `trial`, `active`, `grace`, `billing_retry`, `expired` ou `revoked`.
    let status: String
    let temAcesso: Bool
    let expiraEm: Date?
    /// Id do produto na App Store (mensal ou anual), quando já houve compra.
    let produto: String?
    /// Vai na compra (`appAccountToken`) para o servidor ligar a compra à conta.
    let appAccountToken: String

    enum CodingKeys: String, CodingKey {
        case status
        case temAcesso = "tem_acesso"
        case expiraEm = "expira_em"
        case produto
        case appAccountToken = "app_account_token"
    }
}

nonisolated extension AssinaturaResponse {
    /// Decodificação própria só para `expira_em`: o servidor grava UTC sem fuso
    /// e o Python serializa com microssegundos ("2026-11-13T12:00:00.123000"),
    /// formato que o `JSONDecoder` compartilhado não aceita. Uma data ilegível
    /// vira `nil` em vez de derrubar o corpo inteiro (o acesso vem de
    /// `tem_acesso`, não da data).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        temAcesso = try c.decode(Bool.self, forKey: .temAcesso)
        produto = try c.decodeIfPresent(String.self, forKey: .produto)
        appAccountToken = try c.decode(String.self, forKey: .appAccountToken)
        if let data = try? c.decodeIfPresent(Date.self, forKey: .expiraEm) {
            expiraEm = data
        } else if let texto = try? c.decodeIfPresent(String.self, forKey: .expiraEm) {
            expiraEm = Self.lerData(texto)
        } else {
            expiraEm = nil
        }
    }

    /// Lê "yyyy-MM-ddTHH:mm:ss[.ffffff][Z|±hh:mm]"; sem fuso = UTC.
    static func lerData(_ texto: String) -> Date? {
        var base = texto
        var fuso = ""
        if let ponto = texto.firstIndex(of: ".") {
            base = String(texto[..<ponto])
            fuso = String(texto[texto.index(after: ponto)...].drop(while: { $0.isNumber }))
        } else if texto.count > 19 {
            base = String(texto.prefix(19))
            fuso = String(texto.dropFirst(19))
        }
        if fuso.isEmpty || fuso == "Z" {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f.date(from: base)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: base + fuso)
    }
}

nonisolated struct TransacaoAssinaturaRequest: Codable, Sendable {
    /// `jwsRepresentation` da transação do StoreKit 2.
    let jws: String
}
