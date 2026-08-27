//
//  Decimal+Extension.swift
//  SoftexVamo
//

import Foundation

extension Decimal {
    /// Formata o valor como moeda brasileira (R$).
    func formattedAsCurrency() -> String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: self)) ?? "R$ 0,00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.currencyCode = "BRL"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
