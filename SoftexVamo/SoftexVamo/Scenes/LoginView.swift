//
//  LoginView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import SwiftUI

struct LoginView: View {
    
    @ObservedObject var authService = AuthService.shared
    @State private var email: String = ""
    @State private var senha: String = ""
    @State private var showRegister: Bool = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Spacer()
                
                VStack(spacing: 8) {
                    Text("SoftSpend")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Color.appPurple)
                    
                    Text("Gerencie seus gastos")
                        .font(.system(size: 16))
                        .foregroundStyle(Color("textSecondary"))
                }
                
                Spacer()
                
                VStack(spacing: 20) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .padding()
                        .background(Color("cinza"))
                        .cornerRadius(12)
                    
                    SecureField("Senha", text: $senha)
                        .textContentType(.password)
                        .padding()
                        .background(Color("cinza"))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 30)
                
                if let error = authService.errorMessage {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 30)
                }
                
                Button(action: {
                    Task {
                        await authService.login(email: email, senha: senha)
                    }
                }) {
                    if authService.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Entrar")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    LinearGradient(
                        colors: [Color.appPurple, Color.appPurpleDark],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(16)
                .padding(.horizontal, 30)
                .disabled(authService.isLoading || email.isEmpty || senha.isEmpty)
                .opacity(authService.isLoading || email.isEmpty || senha.isEmpty ? 0.6 : 1)
                
                // Register Link
                Button(action: {
                    showRegister = true
                }) {
                    Text("Nao tem conta? ")
                        .foregroundStyle(Color("textSecondary"))
                    + Text("Cadastre-se")
                        .foregroundStyle(Color.appPurple)
                        .fontWeight(.bold)
                }
                .font(.system(size: 16))
                
                Spacer()
            }
            .background(Color("surfaceBackground").ignoresSafeArea())
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .fullScreenCover(isPresented: $showRegister) {
                RegisterView()
            }
        }
    }
}

#Preview {
    LoginView()
}
