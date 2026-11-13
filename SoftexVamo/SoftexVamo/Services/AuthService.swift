//
//  AuthService.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import Foundation
import Combine
import SwiftData
import os

@MainActor
final class AuthService: ObservableObject {

    static let shared = AuthService()

    @Published var currentUser: UserModel?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    var errorManager: ErrorManager?

    private static let logger = Logger(subsystem: "br.com.softspend", category: "AuthService")

    /// Costura de teste: o `DELETE /auth/conta`. Em produção é o
    /// `NetworkManager`; nos testes, uma closure que falha ou retorna.
    var deletarContaNoServidor: () async throws -> Void = {
        try await NetworkManager.shared.deleteAccount()
    }

    /// Costura de teste: a limpeza local depois do DELETE (exigência da Apple,
    /// docs/publicacao.md §2, "Exclusão de conta"). Em produção roda no
    /// `mainContext` do `BancoLocal.container`, o mesmo das telas.
    var apagarDadosLocais: (String) throws -> Void = { userId in
        try ApagarDadosLocais.apagar(userId: userId, contexto: BancoLocal.container.mainContext)
    }

    private let userKey = "user_data"

    init() {
        checkAuthentication()
    }

    /// Só lê, nunca apaga: seguro repetir quando a cena fica `.active` — a
    /// ação do Apple Pay pode ter acordado o app com o iPhone trancado, quando
    /// o token do Keychain é ilegível (§1.3 de docs/cartao-sem-open-finance.md).
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
            // Só no formulário (LoginView mostra `errorMessage`): sem alerta em dobro.
            errorMessage = message
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
            // Só no formulário (RegisterView mostra `errorMessage`): sem alerta em dobro.
            errorMessage = message
        }

        isLoading = false
    }

    func deleteAccount() async {
        isLoading = true
        errorMessage = nil

        do {
            try await deletarContaNoServidor()

            // Só depois do DELETE dar certo: apaga os dados locais da conta —
            // exigência da Apple (docs/publicacao.md §2). Falha na limpeza só
            // sai no log: a conta já não existe no servidor, não há o que
            // desfazer, e o logout acontece do mesmo jeito. O `user_data` é o
            // fallback para o app que ainda não repovoou `currentUser` (foi
            // acordado pela ação do Apple Pay com o iPhone trancado).
            if let userId = currentUser?.id ?? UsuarioSalvo.id() {
                do {
                    try apagarDadosLocais(userId)
                } catch {
                    Self.logger.error("Falha ao apagar dados locais da conta: \(error.localizedDescription, privacy: .public)")
                }
            }

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
