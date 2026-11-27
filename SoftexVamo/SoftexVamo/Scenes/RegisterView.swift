//
//  RegisterView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import SwiftUI
import CryptoKit

/// `username` do cadastro, derivado do e-mail (o campo "Nome de usuário" saiu
/// da tela, mas o servidor ainda exige `username`, de 3 a 50 caracteres e único).
///
/// Parte antes do "@" (sem acento, em minúsculas, só letras, números, "." e "_",
/// cortada para caber) + "_" + os 6 primeiros hex do SHA-256 do e-mail inteiro
/// (sem espaços em volta, minúsculo). O sufixo separa e-mails com a mesma parte
/// local em domínios diferentes ("joao@empresa.com" × "joao@gmail.com") e é
/// sempre o mesmo para o mesmo e-mail.
nonisolated func usernameDoEmail(_ email: String) -> String {
    let normal = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let local = normal.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""

    let filtrado = local.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
        .lowercased()
        .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }

    let hash = SHA256.hash(data: Data(normal.utf8))
    let sufixo = String(hash.map { String(format: "%02x", $0) }.joined().prefix(6))

    // 50 = base + "_" + 6 hex. Sem base, "usuario" (o total fica sempre entre 3 e 50).
    let base = filtrado.isEmpty ? "usuario" : String(filtrado.prefix(50 - 1 - sufixo.count))
    return "\(base)_\(sufixo)"
}

/// Tela 2: criar conta. Nome, e-mail, senha e confirmação; o `username` sai do e-mail.
struct RegisterView: View {

    @ObservedObject var authService = AuthService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var nome: String = ""
    @State private var email: String = ""
    @State private var senha: String = ""
    @State private var confirmarSenha: String = ""

    /// Volta ao login com o e-mail preenchido (quando o e-mail já tem conta).
    /// Sem ela (demonstração, preview), só fecha a tela.
    var entrarComEmail: ((String) -> Void)?
    /// Abre o "Esqueci minha senha" com o e-mail do cadastro (o e-mail já tem conta).
    var esqueciSenha: ((String) -> Void)?

    init(nome: String = "", email: String = "", senha: String = "",
         entrarComEmail: ((String) -> Void)? = nil,
         esqueciSenha: ((String) -> Void)? = nil) {
        self.entrarComEmail = entrarComEmail
        self.esqueciSenha = esqueciSenha
        _nome = State(initialValue: nome)
        _email = State(initialValue: email)
        _senha = State(initialValue: senha)
        _confirmarSenha = State(initialValue: senha)
    }

    private var regra: RegraSenha { RegraSenha(senha: senha) }
    private var emailAparado: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var senhaValida: Bool { regra.valida }

    private var isFormValid: Bool {
        !nome.isEmpty &&
        !email.isEmpty &&
        senhaValida &&
        senha == confirmarSenha
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Espaco.g) {
                        Text("Criar conta")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(Tema.texto)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, Espaco.p)

                        CampoAcesso(rotulo: "Nome completo", texto: $nome)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)

                        CampoAcesso(rotulo: "E-mail", texto: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: email) { _, _ in
                                // O aviso "já tem conta" era do e-mail anterior.
                                if authService.emailJaCadastrado { authService.errorMessage = nil }
                            }

                        CampoAcesso(rotulo: "Senha", texto: $senha, seguro: true)
                            .textContentType(.newPassword)

                        // Os requisitos aparecem enquanto a senha não atende a todos.
                        if !senha.isEmpty && !senhaValida {
                            RequisitosSenha(regra: regra)
                        }

                        CampoAcesso(rotulo: "Confirmar senha", texto: $confirmarSenha, seguro: true)
                            .textContentType(.newPassword)

                        if !confirmarSenha.isEmpty && senha != confirmarSenha {
                            Text("Senhas não conferem")
                                .font(.footnote)
                                .foregroundStyle(Tema.estouro)
                        }

                        // Alinhada à borda dos campos, como no esboço.
                        Text("Você entra com o e-mail e a senha.")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoFraco)

                        if let error = authService.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(Tema.estouro)
                        }

                        if authService.emailJaCadastrado {
                            HStack(spacing: Espaco.g) {
                                Button {
                                    if let entrarComEmail {
                                        entrarComEmail(emailAparado)
                                    } else {
                                        dismiss()
                                    }
                                } label: {
                                    Text("Entrar com este e-mail").fontWeight(.semibold)
                                }

                                if let esqueciSenha {
                                    Button {
                                        esqueciSenha(emailAparado)
                                    } label: {
                                        Text("Esqueci minha senha").fontWeight(.semibold)
                                    }
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(Tema.marcaTexto)
                        }
                    }
                    .padding(.horizontal, Espaco.g + 4)
                    .padding(.top, Espaco.p)
                    .larguraLegivel()
                }
                .scrollDismissesKeyboard(.interactively)

                BotaoPrincipalCarregando("Criar conta", carregando: authService.isLoading) {
                    Task {
                        await authService.register(nome: nome, username: usernameDoEmail(email),
                                                   email: email, senha: senha)
                        if authService.isAuthenticated {
                            dismiss()
                        }
                    }
                }
                .disabled(authService.isLoading || !isFormValid)
                .opacity(authService.isLoading || !isFormValid ? 0.5 : 1)
                .padding(.horizontal, Espaco.g + 4)
                .padding(.top, Espaco.p)
                .larguraLegivel()

                // Aceite exigido pela loja (docs/publicacao.md §2): os links abrem no Safari.
                Text(textoAceite)
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
                    .tint(Tema.marcaTexto)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Espaco.g + 4)
                    .padding(.vertical, Espaco.p)
                    .larguraLegivel()
            }
            .background(Tema.fundo.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                            Text("Entrar")
                        }
                    }
                    .accessibilityLabel("Voltar para entrar")
                }
            }
            .tint(Tema.marcaTexto)
        }
    }

    /// "Ao criar a conta, você concorda com os Termos de Uso e a Política de
    /// Privacidade." com os dois títulos como links (`LinksLegais`).
    private var textoAceite: AttributedString {
        let fonte = "Ao criar a conta, você concorda com os " +
            "[Termos de Uso](\(LinksLegais.termos.absoluteString)) e a " +
            "[Política de Privacidade](\(LinksLegais.privacidade.absoluteString))."
        return (try? AttributedString(markdown: fonte)) ?? AttributedString(fonte)
    }

}

/// Lista de requisitos da senha, marcando os já atendidos (cadastro e senha nova).
struct RequisitosSenha: View {
    let regra: RegraSenha

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            requisito("Mínimo 8 caracteres", atende: regra.temMinimo)
            requisito("Uma letra maiúscula", atende: regra.temMaiuscula)
            requisito("Uma letra minúscula", atende: regra.temMinuscula)
            requisito("Um número", atende: regra.temNumero)
            requisito("Um caractere especial (!@#$...)", atende: regra.temEspecial)
        }
    }

    private func requisito(_ texto: String, atende: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: atende ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .accessibilityHidden(true)
            Text(texto)
                .font(.caption)
        }
        .foregroundStyle(atende ? Tema.ok : Tema.textoFraco)
        .accessibilityElement(children: .combine)
        .accessibilityValue(atende ? "atendido" : "não atendido")
    }
}

/// Campo das telas de acesso: rótulo pequeno sobre o texto, num bloco de superfície.
struct CampoAcesso: View {
    let rotulo: String
    @Binding var texto: String
    var seguro: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rotulo)
                .font(.footnote)
                .foregroundStyle(Tema.textoFraco)
                .accessibilityHidden(true)
            Group {
                if seguro {
                    SecureField("", text: $texto)
                } else {
                    TextField("", text: $texto)
                }
            }
            .font(.body)
            .foregroundStyle(Tema.texto)
            .accessibilityLabel(rotulo)
        }
        .padding(.horizontal, Espaco.g + 4)
        .padding(.vertical, Espaco.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous))
    }
}

/// `BotaoPrincipal` que mostra um indicador no lugar do título enquanto carrega.
struct BotaoPrincipalCarregando: View {
    let titulo: String
    let carregando: Bool
    let acao: () -> Void

    init(_ titulo: String, carregando: Bool, acao: @escaping () -> Void) {
        self.titulo = titulo
        self.carregando = carregando
        self.acao = acao
    }

    var body: some View {
        BotaoPrincipal(carregando ? " " : titulo, acao: acao)
            .overlay {
                if carregando {
                    ProgressView().tint(Tema.sobreCor)
                }
            }
            .accessibilityLabel(carregando ? "\(titulo), carregando" : titulo)
    }
}

#Preview("Claro") { RegisterView().preferredColorScheme(.light) }
#Preview("Escuro") { RegisterView().preferredColorScheme(.dark) }
