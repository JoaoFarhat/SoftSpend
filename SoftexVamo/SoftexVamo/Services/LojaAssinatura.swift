//
//  LojaAssinatura.swift
//  SoftSpend
//
//  I1 de docs/assinatura.md §3.2. ÚNICO arquivo do app que importa StoreKit:
//  o resto do app (e os testes, com uma loja falsa) fala com a loja pelo
//  `LojaAssinaturaProtocolo`, que só usa os tipos simples deste arquivo.
//  Compra real só no Mac (Xcode) e no TestFlight.
//

import Foundation
import StoreKit
import SwiftUI
import os

// MARK: - Tipos sem StoreKit

/// Os dois produtos do grupo de assinatura "SoftSpend" (§3.2; permanentes,
/// não dá para trocar depois de criados na App Store Connect).
nonisolated enum ProdutoAssinatura {
    static let mensal = "br.com.softspend.app.assinatura.mensal"
    static let anual = "br.com.softspend.app.assinatura.anual"
    static let todos = [mensal, anual]

    static func periodo(de produtoId: String) -> PeriodoPlano? {
        switch produtoId {
        case mensal: return .mensal
        case anual: return .anual
        default: return nil
        }
    }
}

nonisolated enum PeriodoPlano: String, Sendable, Equatable {
    case mensal
    case anual

    var nome: String { self == .mensal ? "Mensal" : "Anual" }
    /// Duração mostrada na tela de planos (exigência da regra 3.1.2).
    var duracao: String { self == .mensal ? "1 mês" : "1 ano" }
    var porPeriodo: String { self == .mensal ? "por mês" : "por ano" }
    var ordem: Int { self == .mensal ? 0 : 1 }
}

nonisolated enum UnidadeOferta: Sendable, Equatable {
    case dia, semana, mes, ano
}

/// Oferta introdutória grátis, com a duração vinda da App Store (nunca
/// escrita no código).
nonisolated struct OfertaGratis: Sendable, Equatable {
    let valor: Int
    let unidade: UnidadeOferta

    /// "14 dias", "1 mês", "1 ano". Semanas viram dias: a App Store Connect
    /// só oferece "2 semanas", e a decisão do produto fala em 14 dias.
    var texto: String {
        switch unidade {
        case .dia: return valor == 1 ? "1 dia" : "\(valor) dias"
        case .semana: return valor * 7 == 1 ? "1 dia" : "\(valor * 7) dias"
        case .mes: return valor == 1 ? "1 mês" : "\(valor) meses"
        case .ano: return valor == 1 ? "1 ano" : "\(valor) anos"
        }
    }
}

nonisolated struct PlanoLoja: Identifiable, Sendable, Equatable {
    let id: String
    let periodo: PeriodoPlano
    /// `Product.displayPrice` (já na moeda da conta da App Store).
    let preco: String
    /// Só preenchida se a pessoa é elegível ao teste grátis.
    let testeGratis: OfertaGratis?

    /// "Depois, R$ 14,90 por mês".
    var textoDepoisDoTeste: String { "Depois, \(preco) \(periodo.porPeriodo)" }
}

/// Transação verificada pelo StoreKit, pronta para ir ao servidor.
/// `finalizar` chama `transaction.finish()` e só pode rodar depois que o
/// servidor aceitou a compra (§3.2).
nonisolated struct TransacaoLoja: Identifiable, Sendable {
    let id: UInt64
    let produtoId: String
    let jws: String
    let appAccountToken: UUID?
    let finalizar: @Sendable () async -> Void
}

nonisolated enum ResultadoCompraLoja: Sendable {
    /// A Apple aprovou e a transação foi verificada.
    case aprovada(TransacaoLoja)
    /// "Pergunte antes de comprar" ou outra aprovação pendente.
    case pendente
    case cancelada
    /// Resultado `.unverified`: tratado como falha, nada destrava.
    case naoVerificada
}

nonisolated enum ErroLoja: Error, Equatable {
    case produtoIndisponivel
    case cancelado
}

/// O que o app usa da App Store. Implementado por `LojaAppStore` (StoreKit 2)
/// e, nos testes, por `SoftSpendTests/FakeLojaAssinatura.swift`.
@MainActor
protocol LojaAssinaturaProtocolo: AnyObject {
    /// Os planos à venda, mensal antes do anual. Lista vazia = loja sem os
    /// produtos (rede, contrato ou configuração).
    func carregarPlanos() async throws -> [PlanoLoja]
    func comprar(planoId: String, appAccountToken: UUID) async throws -> ResultadoCompraLoja
    /// `AppStore.sync()`; lança `ErroLoja.cancelado` se a pessoa desistiu do login.
    func sincronizarComAppStore() async throws
    /// `Transaction.currentEntitlements` (só os produtos do SoftSpend).
    func direitosAtuais() async -> [TransacaoLoja]
    /// `Transaction.unfinished`: compras que o servidor ainda não aceitou.
    func naoFinalizadas() async -> [TransacaoLoja]
    /// `Transaction.updates`: renovações, compras de outro aparelho, aprovação
    /// do "Pergunte antes de comprar".
    func atualizacoes() -> AsyncStream<TransacaoLoja>
}

// MARK: - StoreKit 2

final class LojaAppStore: LojaAssinaturaProtocolo {
    private var produtos: [String: Product] = [:]
    private let logger = Logger(subsystem: "br.com.softspend", category: "LojaAssinatura")

    func carregarPlanos() async throws -> [PlanoLoja] {
        let lista = try await Product.products(for: ProdutoAssinatura.todos)
        var planos: [PlanoLoja] = []
        for produto in lista {
            guard let periodo = ProdutoAssinatura.periodo(de: produto.id) else { continue }
            produtos[produto.id] = produto
            planos.append(PlanoLoja(
                id: produto.id,
                periodo: periodo,
                preco: produto.displayPrice,
                testeGratis: await Self.testeGratis(de: produto)
            ))
        }
        logger.info("carregarPlanos: \(planos.count, privacy: .public) plano(s)")
        return planos.sorted { $0.periodo.ordem < $1.periodo.ordem }
    }

    /// A oferta introdutória grátis, só se a pessoa ainda é elegível (a Apple
    /// decide: uma vez por grupo e por Apple ID).
    private static func testeGratis(de produto: Product) async -> OfertaGratis? {
        guard let assinatura = produto.subscription,
              let intro = assinatura.introductoryOffer,
              intro.paymentMode == .freeTrial else { return nil }
        let elegivel = await assinatura.isEligibleForIntroOffer
        guard elegivel else { return nil }
        let unidade: UnidadeOferta
        switch intro.period.unit {
        case .day: unidade = .dia
        case .week: unidade = .semana
        case .month: unidade = .mes
        case .year: unidade = .ano
        @unknown default: return nil
        }
        return OfertaGratis(valor: intro.period.value, unidade: unidade)
    }

    func comprar(planoId: String, appAccountToken: UUID) async throws -> ResultadoCompraLoja {
        var produto = produtos[planoId]
        if produto == nil {
            produto = try await Product.products(for: [planoId]).first
        }
        guard let produto else { throw ErroLoja.produtoIndisponivel }

        let resultado = try await produto.purchase(options: [.appAccountToken(appAccountToken)])
        switch resultado {
        case .success(let verificacao):
            guard let transacao = Self.transacao(de: verificacao) else {
                logger.error("comprar: transação não verificada")
                return .naoVerificada
            }
            return .aprovada(transacao)
        case .pending:
            return .pendente
        case .userCancelled:
            return .cancelada
        @unknown default:
            return .cancelada
        }
    }

    func sincronizarComAppStore() async throws {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            throw ErroLoja.cancelado
        }
    }

    func direitosAtuais() async -> [TransacaoLoja] {
        var lista: [TransacaoLoja] = []
        for await verificacao in StoreKit.Transaction.currentEntitlements {
            if let transacao = Self.transacao(de: verificacao) { lista.append(transacao) }
        }
        return lista
    }

    func naoFinalizadas() async -> [TransacaoLoja] {
        var lista: [TransacaoLoja] = []
        for await verificacao in StoreKit.Transaction.unfinished {
            if let transacao = Self.transacao(de: verificacao) { lista.append(transacao) }
        }
        return lista
    }

    func atualizacoes() -> AsyncStream<TransacaoLoja> {
        AsyncStream { continuation in
            let tarefa = Task.detached {
                for await verificacao in StoreKit.Transaction.updates {
                    if let transacao = LojaAppStore.transacao(de: verificacao) {
                        continuation.yield(transacao)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in tarefa.cancel() }
        }
    }

    /// Só transação verificada e de um produto do SoftSpend; `.unverified`
    /// nunca destrava nada (vira `nil`).
    nonisolated static func transacao(
        de verificacao: VerificationResult<StoreKit.Transaction>
    ) -> TransacaoLoja? {
        guard case .verified(let transacao) = verificacao,
              ProdutoAssinatura.periodo(de: transacao.productID) != nil else { return nil }
        return TransacaoLoja(
            id: transacao.id,
            produtoId: transacao.productID,
            jws: verificacao.jwsRepresentation,
            appAccountToken: transacao.appAccountToken,
            finalizar: { await transacao.finish() }
        )
    }
}

// MARK: - SwiftUI

extension View {
    /// Folha "Gerenciar assinatura" da App Store (trocar de plano, cancelar).
    /// Fica aqui para as telas não precisarem importar StoreKit.
    func gerenciarAssinatura(isPresented: Binding<Bool>) -> some View {
        manageSubscriptionsSheet(isPresented: isPresented)
    }
}
