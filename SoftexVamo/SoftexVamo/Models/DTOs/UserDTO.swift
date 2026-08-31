import Foundation

nonisolated struct UserDTO: Codable, Sendable {
    let id: String
    let nome: String
    let username: String
    let email: String
}

nonisolated struct RegisterRequest: Codable, Sendable {
    let nome: String
    let username: String
    let email: String
    let senha: String
}

nonisolated struct LoginRequest: Codable, Sendable {
    let email: String
    let senha: String
}

nonisolated struct RefreshTokenRequest: Codable, Sendable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

nonisolated struct LogoutRequest: Codable, Sendable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

nonisolated struct AuthResponse: Codable, Sendable {
    let id: String
    let nome: String
    let username: String
    let email: String
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case id, nome, username, email
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
