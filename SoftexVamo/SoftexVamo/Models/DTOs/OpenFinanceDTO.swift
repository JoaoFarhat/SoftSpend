//
//  OpenFinanceDTO.swift
//  SoftSpend
//

import Foundation

nonisolated struct OpenFinanceConnectionResponse: Codable, Sendable {
    let id: Int
    let itemId: String
    let provider: String
    let institutionName: String?
    let status: String?
    let errorCode: String?
    let errorMessage: String?
    let lastSyncAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case provider
        case institutionName = "institution_name"
        case status
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case lastSyncAt = "last_sync_at"
    }
}

nonisolated struct CreditCardAccountResponse: Codable, Sendable {
    let id: Int
    let conexaoId: Int
    let accountId: String
    let institutionName: String?
    let name: String?
    let marketingName: String?
    let numberLast4: String?
    let currencyCode: String?
    let balance: Decimal?
    let creditLimit: Decimal?
    let availableCreditLimit: Decimal?
    let minimumPayment: Decimal?
    let balanceCloseDate: Date?
    let balanceDueDate: Date?
    let brand: String?
    let level: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case conexaoId = "conexao_id"
        case accountId = "account_id"
        case institutionName = "institution_name"
        case name
        case marketingName = "marketing_name"
        case numberLast4 = "number_last4"
        case currencyCode = "currency_code"
        case balance
        case creditLimit = "credit_limit"
        case availableCreditLimit = "available_credit_limit"
        case minimumPayment = "minimum_payment"
        case balanceCloseDate = "balance_close_date"
        case balanceDueDate = "balance_due_date"
        case brand
        case level
        case status
    }
}

nonisolated struct CreditCardBillResponse: Codable, Sendable {
    let id: Int
    let cartaoId: Int
    let billId: String
    let dueDate: Date?
    let closingDate: Date?
    let totalAmount: Decimal?
    let currencyCode: String?
    let minimumPaymentAmount: Decimal?
    let allowsInstallments: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case cartaoId = "cartao_id"
        case billId = "bill_id"
        case dueDate = "due_date"
        case closingDate = "closing_date"
        case totalAmount = "total_amount"
        case currencyCode = "currency_code"
        case minimumPaymentAmount = "minimum_payment_amount"
        case allowsInstallments = "allows_installments"
    }
}

nonisolated struct ExpenseTransactionMatchResponse: Codable, Sendable {
    let id: Int
    let gastoId: Int
    let cartaoTransacaoId: Int
    let providerTransactionId: String?
    let transactionDescription: String?
    let transactionAmount: Decimal?
    let transactionDate: Date?
    let status: String
    let score: Int
    let method: String
    let confirmedByUser: Bool
    let matchedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case gastoId = "gasto_id"
        case cartaoTransacaoId = "cartao_transacao_id"
        case providerTransactionId = "provider_transaction_id"
        case transactionDescription = "transaction_description"
        case transactionAmount = "transaction_amount"
        case transactionDate = "transaction_date"
        case status
        case score
        case method
        case confirmedByUser = "confirmed_by_user"
        case matchedAt = "matched_at"
    }
}

nonisolated struct CreditCardTransactionResponse: Codable, Sendable {
    let id: Int
    let cartaoId: Int
    let faturaId: Int?
    let transactionId: String
    let description: String?
    let descriptionRaw: String?
    let amount: Decimal?
    let amountInAccountCurrency: Decimal?
    let currencyCode: String?
    let date: Date?
    let category: String?
    let status: String?
    let type: String?
    let providerCode: String?
    let providerId: String?
    let merchantName: String?
    let creditCardMetadata: [String: JSONValue]?
    let openFinanceMatch: ExpenseTransactionMatchResponse?

    enum CodingKeys: String, CodingKey {
        case id
        case cartaoId = "cartao_id"
        case faturaId = "fatura_id"
        case transactionId = "transaction_id"
        case description
        case descriptionRaw = "description_raw"
        case amount
        case amountInAccountCurrency = "amount_in_account_currency"
        case currencyCode = "currency_code"
        case date
        case category
        case status
        case type
        case providerCode = "provider_code"
        case providerId = "provider_id"
        case merchantName = "merchant_name"
        case creditCardMetadata = "credit_card_metadata"
        case openFinanceMatch = "open_finance_match"
    }
}

nonisolated struct CreditCardBillDetailResponse: Codable, Sendable {
    let id: Int
    let cartaoId: Int
    let billId: String
    let dueDate: Date?
    let closingDate: Date?
    let totalAmount: Decimal?
    let currencyCode: String?
    let minimumPaymentAmount: Decimal?
    let allowsInstallments: Bool?
    let transacoes: [CreditCardTransactionResponse]

    enum CodingKeys: String, CodingKey {
        case id
        case cartaoId = "cartao_id"
        case billId = "bill_id"
        case dueDate = "due_date"
        case closingDate = "closing_date"
        case totalAmount = "total_amount"
        case currencyCode = "currency_code"
        case minimumPaymentAmount = "minimum_payment_amount"
        case allowsInstallments = "allows_installments"
        case transacoes
    }
}

nonisolated struct ImportacaoOpenFinanceResponse: Codable, Sendable {
    let itemId: String
    let cartoes: Int
    let faturas: Int
    let transacoes: Int
    let conciliacoes: Int

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case cartoes
        case faturas
        case transacoes
        case conciliacoes
    }
}

nonisolated enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON não suportado")
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
