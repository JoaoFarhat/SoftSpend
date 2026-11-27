//
//  RedefinirSenhaViewModel.swift
//  SoftSpend
//
//  "Esqueci minha senha" em duas etapas: e-mail → código de 6 dígitos + senha
//  nova. O servidor responde igual com ou sem conta, então os textos dizem
//  "se houver uma conta". Depois de trocar a senha, entra direto com ela.
//

import Foundation
import Combine

@MainActor
final class RedefinirSenhaViewModel: ObservableObject {

    enum Etapa: Equatable {
        case email
        case codigo
        /// A senha mudou, mas entrar com ela falhou: a tela manda voltar ao login.
        case senhaAlterada
    }

    enum Texto {
        static let codigoInvalido = "Código incorreto ou expirado."
        static let codigoFormato = "O código tem 6 dígitos."
        static let emailInvalido = "Confira o e-mail informado."
        static let senhasDiferentes = "As senhas não conferem."
        static let senhaFraca = "A senha nova não atende aos requisitos."
        static let indisponivel = "A recuperação de senha ainda não está disponível. Tente mais tarde."
        static let muitasTentativas = "Muitas tentativas. Tente de novo em instantes."
        static let semConexao = "Sem conexão com o servidor. Confira a internet e tente de novo."
        static let inesperado = "Não foi possível concluir agora. Tente de novo."
    }

    static let codigoInvalidoServidor = "invalid_reset_code"
    static let emailIndisponivelServidor = "email_unavailable"

    @Published var email: String
    @Published var codigo: String = "" {
        didSet {
            // Só dígitos, no máximo 6 (colar "123 456" do e-mail também vale).
            let limpo = String(codigo.filter(\.isASCIIDigito).prefix(6))
            if limpo != codigo { codigo = limpo }
        }
    }
    @Published var novaSenha: String = ""
    @Published var confirmarSenha: String = ""

    @Published private(set) var etapa: Etapa = .email
    @Published private(set) var carregando = false
    @Published private(set) var erro: String?
    /// Último erro foi o código recusado: a tela oferece "Pedir novo código".
    @Published private(set) var codigoRecusado = false
    @Published private(set) var minutosValidade = 15
    @Published private(set) var segundosParaReenviar = 0

    private let api: RedefinicaoSenhaAPI
    private let entrar: @MainActor (String, String) async -> Bool
    private var contagem: Task<Void, Never>?

    init(
        email: String = "",
        api: RedefinicaoSenhaAPI = NetworkManager.shared,
        entrar: @escaping @MainActor (String, String) async -> Bool = { email, senha in
            await AuthService.shared.login(email: email, senha: senha)
            return AuthService.shared.isAuthenticated
        }
    ) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.api = api
        self.entrar = entrar
    }

    // MARK: Estado derivado

    var emailAparado: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var regra: RegraSenha { RegraSenha(senha: novaSenha) }
    var podeEnviarCodigo: Bool { !carregando && emailPareceValido }
    var podeReenviar: Bool { !carregando && segundosParaReenviar == 0 }
    var podeRedefinir: Bool {
        !carregando && codigo.count == 6 && regra.valida && novaSenha == confirmarSenha
    }

    private var emailPareceValido: Bool {
        let partes = emailAparado.split(separator: "@", omittingEmptySubsequences: false)
        return partes.count == 2 && !partes[0].isEmpty && partes[1].contains(".")
    }

    // MARK: Ações

    func enviarCodigo() async {
        guard emailPareceValido else {
            erro = Texto.emailInvalido
            return
        }
        await pedir()
    }

    func reenviarCodigo() async {
        guard podeReenviar else { return }
        codigo = ""
        await pedir()
    }

    func usarOutroEmail() {
        contagem?.cancel()
        segundosParaReenviar = 0
        codigo = ""
        novaSenha = ""
        confirmarSenha = ""
        erro = nil
        codigoRecusado = false
        etapa = .email
    }

    func redefinir() async {
        guard codigo.count == 6 else { erro = Texto.codigoFormato; return }
        guard regra.valida else { erro = Texto.senhaFraca; return }
        guard novaSenha == confirmarSenha else { erro = Texto.senhasDiferentes; return }

        carregando = true
        erro = nil
        codigoRecusado = false
        do {
            try await api.redefinirSenha(email: emailAparado, codigo: codigo, novaSenha: novaSenha)
        } catch {
            carregando = false
            mostrar(error)
            return
        }

        let senha = novaSenha
        let entrou = await entrar(emailAparado, senha)
        carregando = false
        limparSegredos()
        if !entrou { etapa = .senhaAlterada }
    }

    /// Apaga código e senhas da memória (ao sair da tela ou depois de trocar a senha).
    func limparSegredos() {
        contagem?.cancel()
        codigo = ""
        novaSenha = ""
        confirmarSenha = ""
    }

    // MARK: Apoio

    private func pedir() async {
        carregando = true
        erro = nil
        codigoRecusado = false
        do {
            let resposta = try await api.pedirCodigoRedefinicao(email: emailAparado)
            minutosValidade = max(1, resposta.expiresInSeconds / 60)
            iniciarContagem(resposta.resendAfterSeconds)
            etapa = .codigo
        } catch {
            mostrar(error)
        }
        carregando = false
    }

    private func iniciarContagem(_ segundos: Int) {
        contagem?.cancel()
        segundosParaReenviar = max(0, segundos)
        guard segundosParaReenviar > 0 else { return }
        contagem = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if self.segundosParaReenviar <= 1 {
                    self.segundosParaReenviar = 0
                    return
                }
                self.segundosParaReenviar -= 1
            }
        }
    }

    private func mostrar(_ error: Error) {
        if case let APIError.serverError(mensagem, _, status) = error {
            switch (status, mensagem) {
            case (400, Self.codigoInvalidoServidor):
                erro = Texto.codigoInvalido
                codigoRecusado = true
            case (503, Self.emailIndisponivelServidor):
                erro = Texto.indisponivel
            case (429, _):
                erro = Texto.muitasTentativas
            default:
                erro = mensagem.isEmpty ? Texto.inesperado : mensagem
            }
        } else if error is URLError {
            erro = Texto.semConexao
        } else {
            erro = Texto.inesperado
        }
    }
}

private extension Character {
    var isASCIIDigito: Bool { isASCII && isNumber }
}
