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

    /// Costura de teste: `POST /auth/login` e `POST /auth/register`.
    var entrarNoServidor: (LoginRequest) async throws -> AuthResponse = {
        try await NetworkManager.shared.login(dados: $0)
    }
    var registrarNoServidor: (RegisterRequest) async throws -> AuthResponse = {
        try await NetworkManager.shared.register(dados: $0)
    }

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

    /// Costura de teste: a gravação do par de tokens na entrada (login e
    /// cadastro, §1.2 de docs/keychain-login.md). Refresh primeiro, access
    /// depois — como na renovação; se o refresh recusa, o access nem tenta.
    var gravarParDeTokens: (String, String) -> ResultadoGravacaoToken = { refreshToken, accessToken in
        let refresh = KeychainManager.saveRefreshToken(refreshToken)
        guard refresh == .gravou else { return refresh }
        return KeychainManager.saveAccessToken(accessToken)
    }

    /// Costura de teste: a limpeza do Keychain — o `deleteAllTokens` do
    /// logout e do fail-closed da §1.2.
    var apagarTokensDoKeychain: () -> Void = { KeychainManager.deleteAllTokens() }

    /// Costura de teste: o descarte do par de tokens pendente em memória do
    /// `NetworkManager` (§1.1, regra 5). Roda em toda saída de sessão.
    var descartarTokensEmMemoria: () -> Void = {
        NetworkManager.shared.descartarParDeTokensPendente()
    }

    /// Costura de teste: a revogação do refresh token no servidor, em
    /// segundo plano (`POST /auth/logout`, sem esperar resposta — §1.2 e
    /// §1.3).
    var revogarSessaoNoServidor: (String) -> Void = { refreshToken in
        Task.detached {
            try? await NetworkManager.shared.logout(refreshToken: refreshToken)
        }
    }

    /// Costura de teste: a leitura do refresh token para a revogação do
    /// logout (§1.3). Olha o par pendente ANTES do Keychain (§1.1): com
    /// pendente, o Keychain ainda tem o refresh antigo — já trocado no
    /// servidor — e revogá-lo seria reuso. Só `.achou` devolve um token —
    /// `.indisponivel`, `.ilegivel` e `.naoExiste` não têm o que mandar.
    var lerRefreshTokenParaRevogar: () -> String? = {
        NetworkManager.shared.buscarRefreshToken().token
    }

    /// Mensagem de erro dos formulários de entrada (login e cadastro).
    /// `APIError` devolve a frase que o servidor mandou (como sempre foi);
    /// `URLError` de falta de rede vira "sem conexão" — antes o login dizia
    /// "Email ou senha invalidos" até sem internet, e a pessoa podia trocar
    /// a senha à toa; qualquer outro erro recebe a frase genérica.
    nonisolated static func mensagemDeErroDeEntrada(_ erro: Error) -> String {
        if let apiError = erro as? APIError {
            return apiError.localizedDescription
        }
        if let urlError = erro as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                return "Sem conexão com o servidor. Confira a internet e tente de novo."
            default:
                break
            }
        }
        return "Não foi possível entrar agora. Tente de novo."
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
            let authResponse = try await entrarNoServidor(dados)
            await saveUser(
                authResponse,
                mensagemSeNaoGravar: "Não foi possível guardar seu login neste iPhone. Reinicie o iPhone e tente de novo."
            )
        } catch {
            // Só no formulário (LoginView mostra `errorMessage`): sem alerta em dobro.
            errorMessage = Self.mensagemDeErroDeEntrada(error)
        }

        isLoading = false
    }

    func register(nome: String, username: String, email: String, senha: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let dados = RegisterRequest(nome: nome, username: username, email: email, senha: senha)
            let authResponse = try await registrarNoServidor(dados)
            await saveUser(
                authResponse,
                mensagemSeNaoGravar: "Sua conta foi criada, mas não foi possível guardar o login neste iPhone. Reinicie o iPhone e entre com seu e-mail e senha."
            )
        } catch {
            // Só no formulário (RegisterView mostra `errorMessage`): sem alerta em dobro.
            errorMessage = Self.mensagemDeErroDeEntrada(error)
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
    /// Toda saída de sessão descarta o par pendente em memória antes de
    /// apagar o Keychain (§1.1, regra 5), e a revogação no servidor só sai
    /// quando o refresh token pôde ser lido — `.indisponivel` não tem o que
    /// mandar (§1.3). A leitura vem ANTES do descarte: o pendente vale como
    /// o cofre e o refresh que ele guarda é o atual — o do Keychain já foi
    /// trocado, e revogá-lo contaria como reuso.
    func logout(revogandoNoServidor: Bool = true) {
        let refreshToken = lerRefreshTokenParaRevogar()
        descartarTokensEmMemoria()

        apagarTokensDoKeychain()
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.removeObject(forKey: "ultimo_ciclo_cache")
        currentUser = nil
        isAuthenticated = false

        guard revogandoNoServidor, let refreshToken else { return }

        revogarSessaoNoServidor(refreshToken)
    }

    /// Logout local por `.ilegivel` (§2.2 de docs/keychain-login.md): a
    /// mesma limpeza do `logout(revogandoNoServidor: false)` — quem falhou
    /// foi a leitura local, não o servidor — mais a mensagem que a tela de
    /// entrada mostra para explicar a saída.
    func logoutPorLoginIlegivel() {
        logout(revogandoNoServidor: false)
        errorMessage = APIError.loginIlegivel.localizedDescription
    }

    /// Grava o par de tokens ANTES de marcar a pessoa como autenticada
    /// (§1.2 de docs/keychain-login.md): ela acabou de digitar a senha e o
    /// iPhone está destrancado — uma recusa do Keychain aqui é anormal e
    /// fecha o acesso (fail-closed). Recusou: apaga o que gravou, revoga a
    /// sessão nova no servidor em segundo plano e mostra
    /// `mensagemSeNaoGravar` — a tela de entrada continua, sem `isAuthenticated`.
    private func saveUser(_ response: AuthResponse, mensagemSeNaoGravar: String) async {
        let gravacao = gravarParDeTokens(response.refreshToken, response.accessToken)
        guard gravacao == .gravou else {
            if case .recusou(let status) = gravacao {
                Self.logger.error("Keychain recusou gravar o login: status \(status, privacy: .public)")
            }
            apagarTokensDoKeychain()
            revogarSessaoNoServidor(response.refreshToken)
            errorMessage = mensagemSeNaoGravar
            return
        }

        let user = UserModel(
            id: response.id,
            nome: response.nome,
            username: response.username,
            email: response.email
        )

        self.currentUser = user
        self.isAuthenticated = true

        let dto = UserDTO(id: response.id, nome: response.nome, username: response.username, email: response.email)
        if let userData = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(userData, forKey: self.userKey)
        }
    }
}
