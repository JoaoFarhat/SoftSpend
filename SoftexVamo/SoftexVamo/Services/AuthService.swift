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
    
    private var baseURL: String { APIConfig.shared.baseURL }
    private let userKey = "user_data"
    
    init() {
        checkAuthentication()
    }
    
    func checkAuthentication() {
        if let _ = KeychainManager.getToken(),
           let userData = UserDefaults.standard.data(forKey: userKey),
           let user = try? JSONDecoder().decode(UserModel.self, from: userData) {
            self.currentUser = user
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
            errorMessage = "Email ou senha invalidos"
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
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    func logout() {
        KeychainManager.deleteToken()
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
        currentUser = nil
        isAuthenticated = false
    }
    
    private func saveUser(_ response: AuthResponse) async {
        let user = UserModel(
            id: response.id,
            nome: response.nome,
            username: response.username,
            email: response.email,
        )
        
        self.currentUser = user
        self.isAuthenticated = true
        
        KeychainManager.saveToken(response.token)
        
        if let userData = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(userData, forKey: self.userKey)
        }
    }
}
