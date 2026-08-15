import Foundation

nonisolated struct APIErrorResponse: Codable, Sendable {
    let error: String?
    let request_id: String?
}


