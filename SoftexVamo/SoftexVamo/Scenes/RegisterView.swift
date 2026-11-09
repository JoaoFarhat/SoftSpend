//
//  RegisterView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import SwiftUI

/// `username` do cadastro, derivado do e-mail (o campo "Nome de usuário" saiu
/// da tela, mas o servidor ainda exige `username`, de 3 a 50 caracteres e único).
///
/// Parte antes do "@", sem acento, em minúsculas, só com letras, números, "." e
/// "_". Curta demais (menos de 3), ganha o primeiro pedaço do domínio
/// ("jo@empresa.com" → "jo.empresa"); se ainda faltar, completa com "_".
nonisolated func usernameDoEmail(_ email: String) -> String {
    let limpo = email.trimmingCharacters(in: .whitespacesAndNewlines)
    let partes = limpo.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)

    func filtrar(_ texto: String) -> String {
        texto.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }
    }

    var nome = filtrar(partes.first ?? "")
    if nome.count < 3, partes.count > 1 {
        let dominio = filtrar(partes[1].split(separator: ".").first.map(String.init) ?? "")
        if !dominio.isEmpty { nome = nome.isEmpty ? dominio : "\(nome).\(dominio)" }
    }
    while nome.count < 3 { nome += "_" }
    return String(nome.prefix(50))
}

/// Tela 2: criar conta. Nome, e-mail, senha e confirmação; o `username` sai do e-mail.
struct RegisterView: View {

    @ObservedObject var authService = AuthService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var nome: String = ""
    @State private var email: String = ""
    @State private var senha: String = ""
    @State private var confirmarSenha: String = ""

    init(nome: String = "", email: String = "", senha: String = "") {
        _nome = State(initialValue: nome)
        _email = State(initialValue: email)
        _senha = State(initialValue: senha)
        _confirmarSenha = State(initialValue: senha)
    }

    private var senhaTemMinimo: Bool { senha.count >= 8 }
    private var senhaTemMaiuscula: Bool { senha.contains(where: { $0.isUppercase }) }
    private var senhaTemMinuscula: Bool { senha.contains(where: { $0.isLowercase }) }
    private var senhaTemNumero: Bool { senha.contains(where: { $0.isNumber }) }
    private var senhaTemEspecial: Bool { senha.contains(where: { "!@#$%^&*()_+-=[]{}|;:',.<>?/~`".contains($0) }) }
    private var senhaValida: Bool { senhaTemMinimo && senhaTemMaiuscula && senhaTemMinuscula && senhaTemNumero && senhaTemEspecial }

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

                        CampoAcesso(rotulo: "Senha", texto: $senha, seguro: true)
                            .textContentType(.newPassword)

                        // Os requisitos aparecem enquanto a senha não atende a todos.
                        if !senha.isEmpty && !senhaValida {
                            VStack(alignment: .leading, spacing: 4) {
                                senhaRequisito("Mínimo 8 caracteres", atende: senhaTemMinimo)
                                senhaRequisito("Uma letra maiúscula", atende: senhaTemMaiuscula)
                                senhaRequisito("Uma letra minúscula", atende: senhaTemMinuscula)
                                senhaRequisito("Um número", atende: senhaTemNumero)
                                senhaRequisito("Um caractere especial (!@#$...)", atende: senhaTemEspecial)
                            }
                            .padding(.horizontal, Espaco.g + 4)
                        }

                        CampoAcesso(rotulo: "Confirmar senha", texto: $confirmarSenha, seguro: true)
                            .textContentType(.newPassword)

                        if !confirmarSenha.isEmpty && senha != confirmarSenha {
                            Text("Senhas não conferem")
                                .font(.footnote)
                                .foregroundStyle(Tema.estouro)
                                .padding(.horizontal, Espaco.g + 4)
                        }

                        Text("O nome de usuário saiu: o e-mail já identifica a conta.")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoFraco)
                            .padding(.horizontal, Espaco.g + 4)

                        if let error = authService.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(Tema.estouro)
                                .padding(.horizontal, Espaco.g + 4)
                        }
                    }
                    .padding(.horizontal, Espaco.g + 4)
                    .padding(.top, Espaco.p)
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
                .padding(.vertical, Espaco.p)
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

    private func senhaRequisito(_ texto: String, atende: Bool) -> some View {
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
