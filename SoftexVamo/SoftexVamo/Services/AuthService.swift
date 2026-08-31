//
//  AuthService.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import Foundation
import Combine

@MainActor
final class AuthService: ObservableObject {

    static let shared = AuthService()

    @Published var currentUser: UserModel?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    var errorManager: ErrorManager?

    private let userKey = "user_data"

    init() {
        checkAuthentication()
    }

    func checkAuthentication() {
        if KeychainManager.getAccessToken() != nil,
           let userData = UserDefaults.standard.data(forKey: userKey),
           let dto = try? JSONDecoder().decode(UserDTO.self, from: userData) {
            self.currentUser = UserModel(from: dto)
            self.isAuthenticated = true
        }
    }

    func login(email: String, senha: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let dados = LoginRequest(email: email, senha: senha)
            let authResponse = try await NetworkManager.shared.login(dados: dados)
            await saveUser(authResponse)
        } catch {
            let message = (error as? APIError)?.localizedDescription ?? "Email ou senha invalidos"
            errorMessage = message
            errorManager?.show(title: "Erro no login", message: message)
        }

        isLoading = false
    }

    func register(nome: String, username: String, email: String, senha: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let dados = RegisterRequest(nome: nome, username: username, email: email, senha: senha)
            let authResponse = try await NetworkManager.shared.register(dados: dados)
            await saveUser(authResponse)
        } catch {
            let message = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            errorMessage = message
            errorManager?.show(title: "Erro no cadastro", message: message)
        }

        isLoading = false
    }

    func deleteAccount() async {
        isLoading = true
        errorMessage = nil

        do {
            try await NetworkManager.shared.deleteAccount()
            // A conta (e seus refresh tokens, via cascade) ja foi removida no
            // backend, entao nao ha o que revogar.
            logout(revogandoNoServidor: false)
        } catch {
            let message = (error as? APIError)?.localizedDescription ?? "Não foi possível excluir a conta. Tente novamente."
            errorMessage = message
            errorManager?.show(title: "Erro ao excluir conta", message: message)
        }

        isLoading = false
    }

    /// Encerra a sessão local imediatamente e, opcionalmente, revoga o refresh
    /// token no backend em segundo plano.
    ///
    /// A limpeza local é síncrona de propósito: se dependesse da resposta da
    /// rede, o usuário continuaria "logado" na UI por até 8s (ou indefinidamente
    /// se estivesse offline).
    func logout(revogandoNoServidor: Bool = true) {
        let refreshToken = KeychainManager.getRefreshToken()

        KeychainManager.deleteAllTokens()
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
        currentUser = nil
        isAuthenticated = false

        guard revogandoNoServidor, let refreshToken else { return }

        Task.detached {
            try? await NetworkManager.shared.logout(refreshToken: refreshToken)
        }
    }

    private func saveUser(_ response: AuthResponse) async {
        let user = UserModel(
            id: response.id,
            nome: response.nome,
            username: response.username,
            email: response.email
        )

        self.currentUser = user
        self.isAuthenticated = true

        KeychainManager.saveAccessToken(response.accessToken)
        KeychainManager.saveRefreshToken(response.refreshToken)

        let dto = UserDTO(id: response.id, nome: response.nome, username: response.username, email: response.email)
        if let userData = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(userData, forKey: self.userKey)
        }
    }
}
