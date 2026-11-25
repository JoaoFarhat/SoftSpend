import Foundation

nonisolated struct APIErrorResponse: Codable, Sendable {
    let error: String?
    let request_id: String?
    /// Campos que o 422 de validação recusou (`loc` de cada erro, sem
    /// repetição — `Python/middlewares.py`). Opcional: servidor antigo e os
    /// outros erros não trazem a chave.
    let campos: [String]?
}


