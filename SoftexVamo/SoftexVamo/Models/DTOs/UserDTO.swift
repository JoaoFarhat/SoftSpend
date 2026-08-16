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

nonisolated struct AuthResponse: Codable, Sendable {
    let id: String
    let nome: String
    let username: String
    let email: String
    let token: String
}
