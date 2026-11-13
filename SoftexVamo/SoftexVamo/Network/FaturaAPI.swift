//
//  FaturaAPI.swift
//  SoftSpend
//

import Foundation

/// Chamadas de rede da importação de fatura por arquivo (§2.4 de
/// docs/cartao-sem-open-finance.md), usadas pelo `ImportarFaturaViewModel`.
///
/// Existe para o ViewModel ser testado com uma API falsa
/// (`SoftSpendTests/FakeFaturaAPI.swift`). Em produção quem implementa é o
/// `NetworkManager`, que é o padrão do `init`.
nonisolated protocol FaturaAPI: Sendable {
    /// `POST /api/faturas/ler` (multipart): só leitura — o servidor não grava
    /// nada. `senha` só para PDF protegido; `cicloId` liga a prévia da
    /// conciliação (dentro_da_viagem, dia_id, match).
    func lerFatura(
        arquivo: Data,
        nomeArquivo: String,
        tipo: ArquivoFatura.Tipo,
        senha: String?,
        cicloId: Int?
    ) async throws -> FaturaLida

    /// `POST /api/faturas`: grava a fatura e as compras mantidas na
    /// conferência, e já roda a conciliação no servidor.
    func gravarFatura(_ lida: FaturaLida) async throws -> CreditCardBillDetailResponse

    /// `POST /api/faturas/{id}/conciliar`: concilia de novo, depois que os
    /// gastos criados na conferência subiram.
    func conciliarFatura(faturaId: Int) async throws -> CreditCardBillDetailResponse

    /// `POST /api/faturas/matches/{id}/confirm` e `DELETE`: mesmo efeito das
    /// rotas do Open Finance. Usados depois do "Importar" para refazer os
    /// "Confirmar"/"Desvincular" decididos na conferência (a prévia não tem
    /// id de match; o vínculo é localizado pelo `gasto_id`).
    func confirmarMatchFatura(matchId: Int) async throws -> ExpenseTransactionMatchResponse
    func removerMatchFatura(matchId: Int) async throws -> ExpenseTransactionMatchResponse
}

nonisolated extension NetworkManager: FaturaAPI {}
