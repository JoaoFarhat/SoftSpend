//
//  FeaturesDTO.swift
//  SoftSpend
//

import Foundation

nonisolated struct FeaturesResponse: Codable, Sendable {
    let openFinance: Bool

    enum CodingKeys: String, CodingKey {
        case openFinance = "open_finance"
    }
}
