import Foundation
@testable import SoftSpend

/// API de fatura falsa para testar o `ImportarFaturaViewModel` sem rede:
/// devolve a prévia e o detalhe configurados, grava as chamadas na ordem e
/// falha sob comando. `marcar(_:)` deixa o teste anotar outros passos (ex.: a
/// criação de gasto) na mesma linha do tempo.
nonisolated final class FakeFaturaAPI: FaturaAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var _chamadas: [String] = []
    private var _enviada: FaturaLida?
    private var _senhas: [String?] = []
    private var _cicloIds: [Int?] = []
    private var _confirmados: [Int] = []
    private var _removidos: [Int] = []
    private var _conciliacoes = 0

    var lida: FaturaLida = FaturaLida()
    var detalhe: CreditCardBillDetailResponse = CreditCardBillDetailResponse(
        id: 42, cartaoId: 1, billId: "fatura:teste", dueDate: nil,
        closingDate: nil, totalAmount: nil, currencyCode: "BRL",
        minimumPaymentAmount: nil, allowsInstallments: nil, transacoes: []
    )
    var erroAoLer: Error?
    var erroAoGravar: Error?
    /// Atraso opcional antes de responder a leitura — simula servidor
    /// lento, para testar o cancelamento da leitura em voo.
    var atrasoLeitura: Duration?

    var chamadas: [String] { lock.lock(); defer { lock.unlock() }; return _chamadas }
    var enviada: FaturaLida? { lock.lock(); defer { lock.unlock() }; return _enviada }
    var senhas: [String?] { lock.lock(); defer { lock.unlock() }; return _senhas }
    var cicloIds: [Int?] { lock.lock(); defer { lock.unlock() }; return _cicloIds }
    var confirmados: [Int] { lock.lock(); defer { lock.unlock() }; return _confirmados }
    var removidos: [Int] { lock.lock(); defer { lock.unlock() }; return _removidos }
    var conciliacoes: Int { lock.lock(); defer { lock.unlock() }; return _conciliacoes }

    func marcar(_ passo: String) {
        lock.lock()
        _chamadas.append(passo)
        lock.unlock()
    }

    func lerFatura(
        arquivo: Data, nomeArquivo: String, tipo: ArquivoFatura.Tipo,
        senha: String?, cicloId: Int?
    ) async throws -> FaturaLida {
        lock.lock()
        _chamadas.append("ler")
        _senhas.append(senha)
        _cicloIds.append(cicloId)
        let erro = erroAoLer
        let atraso = atrasoLeitura
        lock.unlock()
        if let erro { throw erro }
        if let atraso { try? await Task.sleep(for: atraso) }
        return lida
    }

    func gravarFatura(_ lida: FaturaLida) async throws -> CreditCardBillDetailResponse {
        lock.lock()
        _chamadas.append("gravar")
        let erro = erroAoGravar
        lock.unlock()
        if let erro { throw erro }
        lock.lock()
        _enviada = lida
        lock.unlock()
        return detalhe
    }

    func conciliarFatura(faturaId: Int) async throws -> CreditCardBillDetailResponse {
        lock.lock()
        _chamadas.append("conciliar")
        _conciliacoes += 1
        lock.unlock()
        return detalhe
    }

    /// O `gastoId` do match configurado no `detalhe` (0 se não houver) —
    /// como o servidor, que devolve o vínculo atualizado.
    private func gastoId(doMatchId matchId: Int) -> Int {
        detalhe.transacoes.first {
            $0.openFinanceMatch?.id == matchId
        }?.openFinanceMatch?.gastoId ?? 0
    }

    func confirmarMatchFatura(matchId: Int) async throws -> ExpenseTransactionMatchResponse {
        lock.lock()
        _chamadas.append("confirmar")
        _confirmados.append(matchId)
        lock.unlock()
        return ExpenseTransactionMatchResponse(
            id: matchId, gastoId: gastoId(doMatchId: matchId), cartaoTransacaoId: 1,
            providerTransactionId: nil, transactionDescription: nil,
            transactionAmount: nil, transactionDate: nil,
            status: "CONFIRMED", score: 90, method: "RULES",
            confirmedByUser: true, matchedAt: .now
        )
    }

    func removerMatchFatura(matchId: Int) async throws -> ExpenseTransactionMatchResponse {
        lock.lock()
        _chamadas.append("remover")
        _removidos.append(matchId)
        lock.unlock()
        return ExpenseTransactionMatchResponse(
            id: matchId, gastoId: gastoId(doMatchId: matchId), cartaoTransacaoId: 1,
            providerTransactionId: nil, transactionDescription: nil,
            transactionAmount: nil, transactionDate: nil,
            status: "PENDENTE", score: 90, method: "RULES",
            confirmedByUser: false, matchedAt: .now
        )
    }
}
