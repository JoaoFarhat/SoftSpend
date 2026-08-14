import Foundation

struct UserDTO: Codable {
    let id: Int
    let nome: String
    let username: String
    let email: String
}

struct RegisterRequest: Codable {
    let nome: String
    let username: String
    let email: String
    let senha: String
}

struct LoginRequest: Codable {
    let email: String
    let senha: String
}

struct AuthResponse: Codable {
    let id: Int
    let nome: String
    let username: String
    let email: String
    let token: String
}
