import Foundation

nonisolated enum ExportFormato: String, Sendable, CaseIterable {
    case pdf
    case csv

    var extensao: String { rawValue }
}

nonisolated enum ExportComprovantes: String, Sendable {
    /// Autocontido: a imagem vai embutida no PDF.
    case imagem
    /// Geração instantânea, mas os links expiram junto com a URL pré-assinada.
    case link
    case nenhum
}

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

    /// A sugestão de e-mail do teclado do iPhone costuma deixar um espaço no
    /// fim do endereço; o app já manda o e-mail aparado (o servidor também apara).
    init(nome: String, username: String, email: String, senha: String) {
        self.nome = nome
        self.username = username
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senha = senha
    }
}

nonisolated struct LoginRequest: Codable, Sendable {
    let email: String
    let senha: String

    init(email: String, senha: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senha = senha
    }
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
