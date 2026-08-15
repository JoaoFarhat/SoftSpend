import Foundation

struct APIErrorResponse: Codable {
    let error: String?
    let request_id: String?
}


