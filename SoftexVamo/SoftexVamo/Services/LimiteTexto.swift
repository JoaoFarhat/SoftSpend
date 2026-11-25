//
//  LimiteTexto.swift
//  SoftexVamo
//

import Foundation

/// Limite de texto que o servidor impõe (`max_length` nos DTOs). Sem ele, um
/// título longo voltava 422 e o `SyncActor` retentava com backoff para sempre:
/// o gasto ou a viagem nunca subia.
///
/// `nonisolated`: o `SyncActor` (background) corta o título no corpo do
/// POST/PUT. Ver "Isolamento de actor" no `AGENTS.md`.
nonisolated enum LimiteTexto {
    /// Teto do `max_length` de `titulo` no servidor
    /// (`Python/dtos/gasto/gasto_request.py`, `Python/dtos/ciclo/ciclo_request.py`).
    static let tituloMaximo = 100

    /// Corta em `tituloMaximo` caracteres, sem mexer nos espaços: é o corte dos
    /// campos de texto — aparar as pontas engoliria o espaço digitado entre
    /// duas palavras.
    ///
    /// Conta como o servidor conta (o `len` do Python: pontos Unicode, não
    /// grafemas — uma bandeira 🇧🇷 vale 2). `unicodeScalars` mede igual.
    static func cortarTitulo(_ texto: String) -> String {
        guard texto.unicodeScalars.count > tituloMaximo else { return texto }
        var cortado = ""
        cortado.unicodeScalars.append(contentsOf: texto.unicodeScalars.prefix(tituloMaximo))
        return cortado
    }

    /// Apara espaços das pontas e corta em `tituloMaximo`: o que vai para o
    /// modelo e para o corpo das requisições.
    static func titulo(_ texto: String) -> String {
        cortarTitulo(texto.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Teto de valor que o servidor impõe (`max_digits=10, decimal_places=2` nos
/// DTOs). Sem ele, um zero a mais no gasto ou no total/diária da viagem
/// voltava 422 e o `SyncActor` retentava com backoff para sempre.
///
/// `nonisolated`: acessível de qualquer isolamento, como `LimiteTexto`.
nonisolated enum LimiteValor {
    /// Maior valor que cabe em `max_digits=10, decimal_places=2`
    /// (`Python/dtos/gasto/gasto_request.py`, `Python/dtos/ciclo/ciclo_request.py`):
    /// R$ 99.999.999,99.
    static let maximo = Decimal(string: "99999999.99")!

    /// Frase única do teto, mostrada no formulário da viagem e no do gasto.
    static let mensagem = "O valor máximo é R$ 99.999.999,99"
}
