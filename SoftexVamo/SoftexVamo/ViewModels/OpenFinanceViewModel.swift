//
//  OpenFinanceViewModel.swift
//  SoftSpend
//

import Foundation
import Combine
import SwiftData
import os

@MainActor
final class OpenFinanceViewModel: ObservableObject {
    @Published var cartoes: [CartaoOpenFinance] = []
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published var ultimoResumo: String?

    var modelContext: ModelContext?
    weak var errorManager: ErrorManager?

    private let logger = Logger(subsystem: "br.com.softspend", category: "OpenFinanceViewModel")

    private var userId: String {
        AuthService.shared.currentUser?.id ?? ""
    }

    private func showError(_ error: Error) {
        logger.error("OpenFinance error: \(error.localizedDescription, privacy: .public)")
        errorManager?.show(error: error)
    }

    private func salvarLocal() {
        do {
            try modelContext?.save()
        } catch {
            showError(APIError.serverError(
                message: "Erro ao salvar dados do Open Finance: \(error.localizedDescription)",
                requestId: "-",
                statusCode: 500
            ))
        }
    }

    private func carregarLocais() {
        guard let modelContext, !userId.isEmpty else { return }
        let descriptor = FetchDescriptor<CartaoOpenFinance>(
            predicate: #Predicate { $0.userId == userId },
            sortBy: [SortDescriptor(\.backendId)]
        )
        cartoes = (try? modelContext.fetch(descriptor)) ?? []
    }

    func carregarDados() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        carregarLocais()
        guard NetworkMonitor.shared.isConnected else { return }
        await carregarRemoto()
    }

    func sincronizarTudo() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard NetworkMonitor.shared.isConnected else {
            showError(APIError.serverError(
                message: "Você precisa estar online para sincronizar a fatura.",
                requestId: "-",
                statusCode: 0
            ))
            return
        }

        do {
            let conexoes = try await NetworkManager.shared.fetchOpenFinanceConnections()
            var cartoesImportados = 0
            var faturasImportadas = 0
            var transacoesImportadas = 0
            var conciliacoes = 0

            for conexao in conexoes {
                let resultado = try await NetworkManager.shared.sincronizarOpenFinanceItem(itemId: conexao.itemId)
                cartoesImportados += resultado.cartoes
                faturasImportadas += resultado.faturas
                transacoesImportadas += resultado.transacoes
                conciliacoes += resultado.conciliacoes
            }

            ultimoResumo = conexoes.isEmpty
                ? "Nenhum cartão corporativo linkado ainda."
                : "\(cartoesImportados) cartão(ões), \(faturasImportadas) fatura(s), \(transacoesImportadas) transação(ões) e \(conciliacoes) vínculo(s) atualizados."

            await carregarRemoto()
        } catch {
            showError(error)
        }
    }

    private func carregarRemoto() async {
        do {
            let cardsDTO = try await NetworkManager.shared.fetchOpenFinanceCards()
            var cartoesSalvos: [CartaoOpenFinance] = []

            for dto in cardsDTO {
                let cartao = salvarOuAtualizarCartao(dto)
                cartoesSalvos.append(cartao)

                let faturasDTO = try await NetworkManager.shared.fetchOpenFinanceBills(cartaoId: dto.id)
                let faturasIds = Set(faturasDTO.map(\.id))
                for faturaDTO in faturasDTO {
                    _ = salvarOuAtualizarFatura(faturaDTO, cartao: cartao)
                }
                removerFaturasAusentes(do: cartao, idsRemotos: faturasIds)

                let transacoesDTO = try await NetworkManager.shared.fetchOpenFinanceTransactions(cartaoId: dto.id)
                let transacoesIds = Set(transacoesDTO.map(\.id))
                for transacaoDTO in transacoesDTO {
                    _ = salvarOuAtualizarTransacao(transacaoDTO, cartao: cartao)
                }
                removerTransacoesAusentes(do: cartao, idsRemotos: transacoesIds)
            }

            removerCartoesAusentes(idsRemotos: Set(cardsDTO.map(\.id)))
            try await sincronizarMatchesLocais()
            salvarLocal()
            carregarLocais()
        } catch {
            showError(error)
        }
    }

    func carregarFatura(_ fatura: FaturaCartao) async {
        guard NetworkMonitor.shared.isConnected else { return }
        do {
            let detalhe = try await NetworkManager.shared.fetchOpenFinanceBill(faturaId: fatura.backendId)
            atualizarFatura(fatura, com: detalhe)

            let idsRemotos = Set(detalhe.transacoes.map(\.id))
            for transacaoDTO in detalhe.transacoes {
                _ = salvarOuAtualizarTransacao(transacaoDTO, cartao: fatura.cartao, fatura: fatura)
            }
            removerTransacoesAusentes(da: fatura, idsRemotos: idsRemotos)
            try await sincronizarMatchesLocais()
            salvarLocal()
            carregarLocais()
        } catch {
            showError(error)
        }
    }

    func confirmarMatch(da transacao: TransacaoCartao) async {
        guard let matchId = transacao.matchBackendId else { return }
        do {
            let match = try await NetworkManager.shared.confirmarOpenFinanceMatch(matchId: matchId)
            aplicarMatch(match)
            salvarLocal()
        } catch {
            showError(error)
        }
    }

    func removerMatch(da transacao: TransacaoCartao) async {
        guard let matchId = transacao.matchBackendId else { return }
        do {
            let match = try await NetworkManager.shared.removerOpenFinanceMatch(matchId: matchId)
            limparMatch(match)
            salvarLocal()
        } catch {
            showError(error)
        }
    }

    private func sincronizarMatchesLocais() async throws {
        guard let modelContext else { return }
        let matches = try await NetworkManager.shared.fetchOpenFinanceMatches()
        let idsRemotos = Set(matches.map(\.id))

        let gastosDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.openFinanceMatchBackendId != nil && $0.deletadoEm == nil }
        )
        let gastosComMatch = (try? modelContext.fetch(gastosDescriptor)) ?? []
        for gasto in gastosComMatch where gasto.dia?.ciclo?.userId == userId {
            if let matchId = gasto.openFinanceMatchBackendId, !idsRemotos.contains(matchId) {
                gasto.limparOpenFinanceMatch()
            }
        }

        let transacoesDescriptor = FetchDescriptor<TransacaoCartao>(
            predicate: #Predicate { $0.userId == userId && $0.matchBackendId != nil }
        )
        let transacoesComMatch = (try? modelContext.fetch(transacoesDescriptor)) ?? []
        for transacao in transacoesComMatch {
            if let matchId = transacao.matchBackendId, !idsRemotos.contains(matchId) {
                transacao.limparMatch()
            }
        }

        for match in matches {
            aplicarMatch(match)
        }
    }

    private func aplicarMatch(_ match: ExpenseTransactionMatchResponse) {
        guard let modelContext else { return }

        let gastoId: Int? = match.gastoId
        let gastoDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.backendId == gastoId }
        )
        if let gasto = try? modelContext.fetch(gastoDescriptor).first {
            gasto.aplicarOpenFinanceStatus(match.status, match: match)
        }

        let transacaoDescriptor = FetchDescriptor<TransacaoCartao>(
            predicate: #Predicate { $0.backendId == match.cartaoTransacaoId }
        )
        if let transacao = try? modelContext.fetch(transacaoDescriptor).first {
            transacao.aplicarMatch(match)
        }
    }

    private func limparMatch(_ match: ExpenseTransactionMatchResponse) {
        guard let modelContext else { return }

        let gastoId: Int? = match.gastoId
        let gastoDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.backendId == gastoId }
        )
        if let gasto = try? modelContext.fetch(gastoDescriptor).first {
            gasto.limparOpenFinanceMatch()
        }

        let transacaoDescriptor = FetchDescriptor<TransacaoCartao>(
            predicate: #Predicate { $0.backendId == match.cartaoTransacaoId }
        )
        if let transacao = try? modelContext.fetch(transacaoDescriptor).first {
            transacao.limparMatch()
        }
    }

    private func salvarOuAtualizarCartao(_ dto: CreditCardAccountResponse) -> CartaoOpenFinance {
        let descriptor = FetchDescriptor<CartaoOpenFinance>(
            predicate: #Predicate { $0.backendId == dto.id && $0.userId == userId }
        )
        let cartao = (try? modelContext?.fetch(descriptor).first) ?? nil
        if let cartao {
            atualizarCartao(cartao, com: dto)
            return cartao
        }

        let novo = CartaoOpenFinance(from: dto, userId: userId)
        modelContext?.insert(novo)
        return novo
    }

    private func atualizarCartao(_ cartao: CartaoOpenFinance, com dto: CreditCardAccountResponse) {
        cartao.conexaoBackendId = dto.conexaoId
        cartao.accountId = dto.accountId
        cartao.institutionName = dto.institutionName
        cartao.name = dto.name
        cartao.marketingName = dto.marketingName
        cartao.numberLast4 = dto.numberLast4
        cartao.currencyCode = dto.currencyCode
        cartao.balance = dto.balance
        cartao.creditLimit = dto.creditLimit
        cartao.availableCreditLimit = dto.availableCreditLimit
        cartao.minimumPayment = dto.minimumPayment
        cartao.balanceCloseDate = dto.balanceCloseDate
        cartao.balanceDueDate = dto.balanceDueDate
        cartao.brand = dto.brand
        cartao.level = dto.level
        cartao.status = dto.status
        cartao.atualizadoEm = .now
    }

    private func salvarOuAtualizarFatura(_ dto: CreditCardBillResponse, cartao: CartaoOpenFinance) -> FaturaCartao {
        let descriptor = FetchDescriptor<FaturaCartao>(
            predicate: #Predicate { $0.backendId == dto.id && $0.userId == userId }
        )
        let fatura = (try? modelContext?.fetch(descriptor).first) ?? nil
        if let fatura {
            atualizarFatura(fatura, com: dto)
            fatura.cartao = cartao
            return fatura
        }

        let nova = FaturaCartao(from: dto, userId: userId, cartao: cartao)
        modelContext?.insert(nova)
        return nova
    }

    private func atualizarFatura(_ fatura: FaturaCartao, com dto: CreditCardBillResponse) {
        fatura.billId = dto.billId
        fatura.dueDate = dto.dueDate
        fatura.closingDate = dto.closingDate
        fatura.totalAmount = dto.totalAmount
        fatura.currencyCode = dto.currencyCode
        fatura.minimumPaymentAmount = dto.minimumPaymentAmount
        fatura.allowsInstallments = dto.allowsInstallments
        fatura.atualizadoEm = .now
    }

    private func atualizarFatura(_ fatura: FaturaCartao, com dto: CreditCardBillDetailResponse) {
        fatura.billId = dto.billId
        fatura.dueDate = dto.dueDate
        fatura.closingDate = dto.closingDate
        fatura.totalAmount = dto.totalAmount
        fatura.currencyCode = dto.currencyCode
        fatura.minimumPaymentAmount = dto.minimumPaymentAmount
        fatura.allowsInstallments = dto.allowsInstallments
        fatura.atualizadoEm = .now
    }

    private func salvarOuAtualizarTransacao(
        _ dto: CreditCardTransactionResponse,
        cartao: CartaoOpenFinance?,
        fatura: FaturaCartao? = nil
    ) -> TransacaoCartao {
        let descriptor = FetchDescriptor<TransacaoCartao>(
            predicate: #Predicate { $0.backendId == dto.id && $0.userId == userId }
        )
        let faturaDestino = fatura ?? buscarFaturaLocal(dto.faturaId)
        let transacao = (try? modelContext?.fetch(descriptor).first) ?? nil
        if let transacao {
            atualizarTransacao(transacao, com: dto, cartao: cartao, fatura: faturaDestino)
            return transacao
        }

        let nova = TransacaoCartao(from: dto, userId: userId, cartao: cartao, fatura: faturaDestino)
        modelContext?.insert(nova)
        return nova
    }

    private func atualizarTransacao(
        _ transacao: TransacaoCartao,
        com dto: CreditCardTransactionResponse,
        cartao: CartaoOpenFinance?,
        fatura: FaturaCartao?
    ) {
        transacao.transactionId = dto.transactionId
        transacao.descricao = dto.description
        transacao.descricaoRaw = dto.descriptionRaw
        transacao.merchantName = dto.merchantName
        transacao.amount = dto.amount
        transacao.amountInAccountCurrency = dto.amountInAccountCurrency
        transacao.currencyCode = dto.currencyCode
        transacao.date = dto.date
        transacao.category = dto.category
        transacao.status = dto.status
        transacao.type = dto.type
        transacao.providerCode = dto.providerCode
        transacao.providerId = dto.providerId
        transacao.cartao = cartao
        transacao.fatura = fatura
        transacao.aplicarMatch(dto.openFinanceMatch)
        transacao.atualizadoEm = .now
    }

    private func buscarFaturaLocal(_ backendId: Int?) -> FaturaCartao? {
        guard let backendId, let modelContext else { return nil }
        let descriptor = FetchDescriptor<FaturaCartao>(
            predicate: #Predicate { $0.backendId == backendId && $0.userId == userId }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func removerCartoesAusentes(idsRemotos: Set<Int>) {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<CartaoOpenFinance>(
            predicate: #Predicate { $0.userId == userId }
        )
        for cartao in (try? modelContext.fetch(descriptor)) ?? [] where !idsRemotos.contains(cartao.backendId) {
            modelContext.delete(cartao)
        }
    }

    private func removerFaturasAusentes(do cartao: CartaoOpenFinance, idsRemotos: Set<Int>) {
        guard let modelContext else { return }
        for fatura in cartao.faturas where !idsRemotos.contains(fatura.backendId) {
            modelContext.delete(fatura)
        }
    }

    private func removerTransacoesAusentes(do cartao: CartaoOpenFinance, idsRemotos: Set<Int>) {
        guard let modelContext else { return }
        for transacao in cartao.transacoes where !idsRemotos.contains(transacao.backendId) {
            modelContext.delete(transacao)
        }
    }

    private func removerTransacoesAusentes(da fatura: FaturaCartao, idsRemotos: Set<Int>) {
        guard let modelContext else { return }
        for transacao in fatura.transacoes where !idsRemotos.contains(transacao.backendId) {
            modelContext.delete(transacao)
        }
    }
}
