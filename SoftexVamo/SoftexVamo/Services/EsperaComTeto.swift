//
//  EsperaComTeto.swift
//  SoftSpend
//
//  A espera com teto compartilhada pela leitura da fatura
//  (`ImportarFaturaViewModel`) e pela exportação do relatório
//  (`CiclosViewModel.exportarCiclo`).
//

import Foundation

/// Espera o fim de uma operação em background (hoje o `sync(forcar:)`),
/// no máximo `teto`.
///
/// Com a rede ruim a operação não pode segurar a tela — passado o teto o
/// fluxo segue. A operação **nunca é cancelada**: o `Task` dela continua
/// sozinho em background, porque cancelar um sync no meio marcaria os
/// itens em voo como `.failed` no `SyncActor`, um backoff que não
/// existiria sem a tela.
nonisolated enum EsperaComTeto {
    static func esperar(
        teto: Duration,
        operacao: @escaping @Sendable () async -> Void
    ) async {
        let corrida = CorridaDoTeto()
        await withCheckedContinuation { (continuacao: CheckedContinuation<Void, Never>) in
            Task {
                await operacao()
                if await corrida.responder() { continuacao.resume() }
            }
            Task {
                try? await Task.sleep(for: teto)
                if await corrida.responder() { continuacao.resume() }
            }
        }
    }
}

/// Quem vence a corrida do `esperar`: o primeiro `responder()` devolve
/// `true` e retoma a continuação; o segundo é no-op (uma
/// `CheckedContinuation` não pode ser retomada duas vezes).
private actor CorridaDoTeto {
    private var respondeu = false

    func responder() -> Bool {
        if respondeu { return false }
        respondeu = true
        return true
    }
}
