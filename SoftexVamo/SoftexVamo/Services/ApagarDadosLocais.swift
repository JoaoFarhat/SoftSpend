//
//  ApagarDadosLocais.swift
//  SoftexVamo
//
//  Limpeza local ao excluir a conta (docs/publicacao.md §2, "Exclusão de
//  conta pelo app"): depois do DELETE /auth/conta dar certo, o aparelho não
//  pode continuar guardando os dados dela.
//

import Foundation
import SwiftData

/// Apaga **todos** os dados locais de um `userId`. Chamado pelo
/// `AuthService.deleteAccount` só depois do `DELETE /auth/conta` dar certo —
/// falhou no servidor, nada local sai.
///
/// Os dados dos outros usuários do aparelho ficam intocados: cada usuário só
/// vê os próprios dados (filtro por `userId`), então a limpeza é por usuário,
/// nunca um `delete(model:)` geral.
///
/// Como a conta já não existe no servidor, não há o que sincronizar: os itens
/// são apagados localmente mesmo marcados `.pending`/`deletadoEm` — o sync
/// nunca mais vai rodar para esse usuário.
///
/// Fica no isolamento padrão (`MainActor`), como `RegistroApplePay` e os
/// stores da fila/cartões: a exclusão de conta é uma ação de tela e o
/// `UserModel` não é `nonisolated`.
enum ApagarDadosLocais {
    /// Tira do `contexto` tudo que é do `userId`:
    ///
    /// - os `CicloSoftex` — a cascata leva dias, gastos e os comprovantes
    ///   criptografados (o blob mora na linha do gasto);
    /// - os modelos do Open Finance — o módulo está desligado, mas qualquer
    ///   dado dele já gravado também é da conta;
    /// - o `UserModel` dela;
    ///
    /// e depois tira o `userId` da fila de compras e da lista de cartões do
    /// Apple Pay (arquivos JSON fora do SwiftData, com as mesmas regras de
    /// falha deles: leitura/gravação ruim só sai no log, nunca sobrescreve).
    ///
    /// Lança o erro do `fetch`/`save` do SwiftData. O chamador decide o que
    /// fazer — no `deleteAccount` a falha só vai para o log, porque a conta já
    /// não existe no servidor e não há o que desfazer.
    static func apagar(userId: String, contexto: ModelContext,
                       fila: ComprasAguardandoViagem = .shared,
                       cartoes: CartoesApplePay = .shared) throws {
        let ciclos = try contexto.fetch(FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.userId == userId }
        ))
        for ciclo in ciclos {
            contexto.delete(ciclo)
        }

        // Transações e faturas também são filtradas por `userId` (e não só
        // apagadas pela cascata do cartão) porque um registro órfão sem o
        // cartão pai continuaria guardando dado da conta.
        for transacao in try contexto.fetch(FetchDescriptor<TransacaoCartao>(
            predicate: #Predicate { $0.userId == userId }
        )) {
            contexto.delete(transacao)
        }
        for fatura in try contexto.fetch(FetchDescriptor<FaturaCartao>(
            predicate: #Predicate { $0.userId == userId }
        )) {
            contexto.delete(fatura)
        }
        for cartao in try contexto.fetch(FetchDescriptor<CartaoOpenFinance>(
            predicate: #Predicate { $0.userId == userId }
        )) {
            contexto.delete(cartao)
        }

        for usuario in try contexto.fetch(FetchDescriptor<UserModel>(
            predicate: #Predicate { $0.id == userId }
        )) {
            contexto.delete(usuario)
        }

        try contexto.save()

        fila.removerTodos(userId: userId)
        cartoes.removerTodos(userId: userId)
    }
}
