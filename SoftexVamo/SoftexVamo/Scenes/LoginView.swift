//
//  LoginView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import SwiftUI

/// Tela 1: entrar. Logo, frase, e-mail, senha, "Entrar" e o caminho para criar conta.
struct LoginView: View {

    @ObservedObject var authService = AuthService.shared
    @State private var email: String = ""
    @State private var senha: String = ""
    @State private var showRegister: Bool = false

    /// E-mail pré-preenchido (modo de demonstração, DEBUG).
    var emailInicial: String = ""
    var senhaInicial: String = ""

    private var bloqueado: Bool { authService.isLoading || email.isEmpty || senha.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 120)

                HStack(spacing: Espaco.m) {
                    SimboloBilhete(largura: 40)
                    Text("SoftSpend")
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(Tema.texto)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Text("Os gastos da viagem a trabalho, no controle.")
                    .font(.title3)
                    .foregroundStyle(Tema.textoFraco)
                    .padding(.top, Espaco.m)

                VStack(spacing: Espaco.g) {
                    CampoAcesso(rotulo: "E-mail", texto: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    CampoAcesso(rotulo: "Senha", texto: $senha, seguro: true)
                        .textContentType(.password)
                }
                .padding(.top, 48)

                if let error = authService.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Tema.estouro)
                        .padding(.top, Espaco.m)
                        .padding(.horizontal, Espaco.g + 4)
                }

                BotaoPrincipalCarregando("Entrar", carregando: authService.isLoading) {
                    Task {
                        await authService.login(email: email, senha: senha)
                    }
                }
                .disabled(bloqueado)
                .opacity(bloqueado ? 0.5 : 1)
                .padding(.top, Espaco.g + 4)

                Button {
                    showRegister = true
                } label: {
                    Text("Não tem conta? \(Text("Criar conta").foregroundStyle(Tema.marcaTexto).fontWeight(.semibold))")
                        .foregroundStyle(Tema.textoFraco)
                }
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.top, Espaco.g + 8)
            }
            .padding(.horizontal, Espaco.g + 8)
            .padding(.bottom, Espaco.g)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Tema.fundo.ignoresSafeArea())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onAppear {
            if email.isEmpty { email = emailInicial }
            if senha.isEmpty { senha = senhaInicial }
        }
        .fullScreenCover(isPresented: $showRegister) {
            RegisterView()
        }
    }
}

#Preview("Claro") { LoginView().preferredColorScheme(.light) }
#Preview("Escuro") { LoginView().preferredColorScheme(.dark) }
