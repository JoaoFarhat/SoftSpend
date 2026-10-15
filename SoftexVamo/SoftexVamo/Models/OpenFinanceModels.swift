//
//  OpenFinanceModels.swift
//  SoftSpend
//

import Foundation
import SwiftData
import SwiftUI

nonisolated enum OpenFinanceMatchStatus: String, Codable, Sendable {
    case pendente = "PENDENTE"
    case autoMatched = "AUTO_MATCHED"
    case review = "REVIEW"
    case confirmed = "CONFIRMED"

    var titulo: String {
        switch self {
        case .pendente: return "Aguardando fatura"
        case .autoMatched: return "Na fatura"
        case .review: return "Revisar"
        case .confirmed: return "Confirmado"
        }
    }

    var icon: String {
        switch self {
        case .pendente: return "clock"
        case .autoMatched: return "link"
        case .review: return "exclamationmark.circle"
        case .confirmed: return "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .pendente: return Color("textSecondary")
        case .autoMatched: return .green
        case .review: return .orange
        case .confirmed: return .appPurple
        }
    }
}

@Model
nonisolated final class CartaoOpenFinance {
    @Attribute(.unique) var backendId: Int
    var userId: String
    var conexaoBackendId: Int
    var accountId: String
    var institutionName: String?
    var name: String?
    var marketingName: String?
    var numberLast4: String?
    var currencyCode: String?
    var balance: Decimal?
    var creditLimit: Decimal?
    var availableCreditLimit: Decimal?
    var minimumPayment: Decimal?
    var balanceCloseDate: Date?
    var balanceDueDate: Date?
    var brand: String?
    var level: String?
    var status: String?
    var atualizadoEm: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \FaturaCartao.cartao)
    var faturas: [FaturaCartao]

    @Relationship(deleteRule: .cascade, inverse: \TransacaoCartao.cartao)
    var transacoes: [TransacaoCartao]

    init(
        backendId: Int,
        userId: String,
        conexaoBackendId: Int,
        accountId: String,
        institutionName: String? = nil,
        name: String? = nil,
        marketingName: String? = nil,
        numberLast4: String? = nil,
        currencyCode: String? = nil,
        balance: Decimal? = nil,
        creditLimit: Decimal? = nil,
        availableCreditLimit: Decimal? = nil,
        minimumPayment: Decimal? = nil,
        balanceCloseDate: Date? = nil,
        balanceDueDate: Date? = nil,
        brand: String? = nil,
        level: String? = nil,
        status: String? = nil,
        faturas: [FaturaCartao] = [],
        transacoes: [TransacaoCartao] = []
    ) {
        self.backendId = backendId
        self.userId = userId
        self.conexaoBackendId = conexaoBackendId
        self.accountId = accountId
        self.institutionName = institutionName
        self.name = name
        self.marketingName = marketingName
        self.numberLast4 = numberLast4
        self.currencyCode = currencyCode
        self.balance = balance
        self.creditLimit = creditLimit
        self.availableCreditLimit = availableCreditLimit
        self.minimumPayment = minimumPayment
        self.balanceCloseDate = balanceCloseDate
        self.balanceDueDate = balanceDueDate
        self.brand = brand
        self.level = level
        self.status = status
        self.faturas = faturas
        self.transacoes = transacoes
    }

    convenience init(from dto: CreditCardAccountResponse, userId: String) {
        self.init(
            backendId: dto.id,
            userId: userId,
            conexaoBackendId: dto.conexaoId,
            accountId: dto.accountId,
            institutionName: dto.institutionName,
            name: dto.name,
            marketingName: dto.marketingName,
            numberLast4: dto.numberLast4,
            currencyCode: dto.currencyCode,
            balance: dto.balance,
            creditLimit: dto.creditLimit,
            availableCreditLimit: dto.availableCreditLimit,
            minimumPayment: dto.minimumPayment,
            balanceCloseDate: dto.balanceCloseDate,
            balanceDueDate: dto.balanceDueDate,
            brand: dto.brand,
            level: dto.level,
            status: dto.status
        )
    }

    var titulo: String {
        marketingName ?? name ?? institutionName ?? "Cartão corporativo"
    }

    var numeroMascarado: String {
        numberLast4.map { "•••• \($0)" } ?? "Cartão"
    }
}

@Model
nonisolated final class FaturaCartao {
    @Attribute(.unique) var backendId: Int
    var userId: String
    var billId: String
    var dueDate: Date?
    var closingDate: Date?
    var totalAmount: Decimal?
    var currencyCode: String?
    var minimumPaymentAmount: Decimal?
    var allowsInstallments: Bool?
    var cartao: CartaoOpenFinance?
    var atualizadoEm: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \TransacaoCartao.fatura)
    var transacoes: [TransacaoCartao]

    init(
        backendId: Int,
        userId: String,
        billId: String,
        dueDate: Date? = nil,
        closingDate: Date? = nil,
        totalAmount: Decimal? = nil,
        currencyCode: String? = nil,
        minimumPaymentAmount: Decimal? = nil,
        allowsInstallments: Bool? = nil,
        cartao: CartaoOpenFinance? = nil,
        transacoes: [TransacaoCartao] = []
    ) {
        self.backendId = backendId
        self.userId = userId
        self.billId = billId
        self.dueDate = dueDate
        self.closingDate = closingDate
        self.totalAmount = totalAmount
        self.currencyCode = currencyCode
        self.minimumPaymentAmount = minimumPaymentAmount
        self.allowsInstallments = allowsInstallments
        self.cartao = cartao
        self.transacoes = transacoes
    }

    convenience init(from dto: CreditCardBillResponse, userId: String, cartao: CartaoOpenFinance? = nil) {
        self.init(
            backendId: dto.id,
            userId: userId,
            billId: dto.billId,
            dueDate: dto.dueDate,
            closingDate: dto.closingDate,
            totalAmount: dto.totalAmount,
            currencyCode: dto.currencyCode,
            minimumPaymentAmount: dto.minimumPaymentAmount,
            allowsInstallments: dto.allowsInstallments,
            cartao: cartao
        )
    }

    convenience init(from dto: CreditCardBillDetailResponse, userId: String, cartao: CartaoOpenFinance? = nil) {
        self.init(
            backendId: dto.id,
            userId: userId,
            billId: dto.billId,
            dueDate: dto.dueDate,
            closingDate: dto.closingDate,
            totalAmount: dto.totalAmount,
            currencyCode: dto.currencyCode,
            minimumPaymentAmount: dto.minimumPaymentAmount,
            allowsInstallments: dto.allowsInstallments,
            cartao: cartao
        )
    }

    var periodo: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        let fechamento = closingDate.map { formatter.string(from: $0) } ?? "--/--"
        let vencimento = dueDate.map { formatter.string(from: $0) } ?? "--/--"
        return "Fecha \(fechamento) · Vence \(vencimento)"
    }
}

@Model
nonisolated final class TransacaoCartao {
    @Attribute(.unique) var backendId: Int
    var userId: String
    var transactionId: String
    var descricao: String?
    var descricaoRaw: String?
    var merchantName: String?
    var amount: Decimal?
    var amountInAccountCurrency: Decimal?
    var currencyCode: String?
    var date: Date?
    var category: String?
    var status: String?
    var type: String?
    var providerCode: String?
    var providerId: String?
    var cartao: CartaoOpenFinance?
    var fatura: FaturaCartao?
    var matchBackendId: Int?
    var matchGastoBackendId: Int?
    var matchStatusRaw: String?
    var matchScore: Int?
    var matchConfirmedByUser: Bool = false
    var matchMethod: String?
    var atualizadoEm: Date = Date.now

    init(
        backendId: Int,
        userId: String,
        transactionId: String,
        descricao: String? = nil,
        descricaoRaw: String? = nil,
        merchantName: String? = nil,
        amount: Decimal? = nil,
        amountInAccountCurrency: Decimal? = nil,
        currencyCode: String? = nil,
        date: Date? = nil,
        category: String? = nil,
        status: String? = nil,
        type: String? = nil,
        providerCode: String? = nil,
        providerId: String? = nil,
        cartao: CartaoOpenFinance? = nil,
        fatura: FaturaCartao? = nil
    ) {
        self.backendId = backendId
        self.userId = userId
        self.transactionId = transactionId
        self.descricao = descricao
        self.descricaoRaw = descricaoRaw
        self.merchantName = merchantName
        self.amount = amount
        self.amountInAccountCurrency = amountInAccountCurrency
        self.currencyCode = currencyCode
        self.date = date
        self.category = category
        self.status = status
        self.type = type
        self.providerCode = providerCode
        self.providerId = providerId
        self.cartao = cartao
        self.fatura = fatura
    }

    convenience init(from dto: CreditCardTransactionResponse, userId: String, cartao: CartaoOpenFinance? = nil, fatura: FaturaCartao? = nil) {
        self.init(
            backendId: dto.id,
            userId: userId,
            transactionId: dto.transactionId,
            descricao: dto.description,
            descricaoRaw: dto.descriptionRaw,
            merchantName: dto.merchantName,
            amount: dto.amount,
            amountInAccountCurrency: dto.amountInAccountCurrency,
            currencyCode: dto.currencyCode,
            date: dto.date,
            category: dto.category,
            status: dto.status,
            type: dto.type,
            providerCode: dto.providerCode,
            providerId: dto.providerId,
            cartao: cartao,
            fatura: fatura
        )
        aplicarMatch(dto.openFinanceMatch)
    }

    var titulo: String {
        merchantName ?? descricao ?? descricaoRaw ?? "Transação do cartão"
    }

    @Transient
    var matchStatus: OpenFinanceMatchStatus? {
        matchStatusRaw.flatMap { OpenFinanceMatchStatus(rawValue: $0) }
    }

    func aplicarMatch(_ match: ExpenseTransactionMatchResponse?) {
        matchBackendId = match?.id
        matchGastoBackendId = match?.gastoId
        matchStatusRaw = match?.status
        matchScore = match?.score
        matchConfirmedByUser = match?.confirmedByUser ?? false
        matchMethod = match?.method
    }

    func limparMatch() {
        matchBackendId = nil
        matchGastoBackendId = nil
        matchStatusRaw = nil
        matchScore = nil
        matchConfirmedByUser = false
        matchMethod = nil
    }
}
