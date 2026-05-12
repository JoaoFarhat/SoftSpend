//
//  MenuView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 02/05/26.
//

import SwiftUI

struct MenuView: View {
    @Binding var showMenu: Bool
    @EnvironmentObject var viewModel: CiclosListViewModel
    @StateObject var authService = AuthService.shared
    @State private var selectedEnv: APIEnvironment = APIConfig.shared.current
    
    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(destination: PerfilView()
                                            .environmentObject(viewModel)) {
                HStack {
                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 45, height: 45)
                        .overlay(
                            Text(authService.currentUser?.nome.prefix(2).uppercased() ?? "??")
                                .foregroundColor(.white)
                                .bold()
                        )
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authService.currentUser?.username ?? "Usuário")
                            .font(.system(size: 16, weight: .bold))
                        Text(authService.currentUser?.email ?? "email@exemplo.com")
                            .font(.system(size: 12))
                            .opacity(0.9)
                    }
                    .foregroundColor(.white)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding()
                .background(Color.appPurple)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 15) {
                    Image(systemName: "network")
                        .foregroundColor(Color.appPurple)
                        .padding(10)
                        .background(Color.appPurple.opacity(0.1))
                        .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("Ambiente API")
                            .font(.system(size: 16, weight: .bold))
                        Text(selectedEnv.baseURL)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                
                Picker("Ambiente", selection: $selectedEnv) {
                    ForEach(APIEnvironment.allCases, id: \.self) { env in
                        Text(env.displayName).tag(env)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedEnv) { _, newValue in
                    APIConfig.shared.current = newValue
                }
            }
            .padding()
            .background(Color("cardBackground"))
            
            Divider()
            
            Button {
                withAnimation {
                    showMenu = false
                    authService.logout()
                }
            } label: {
                HStack(spacing: 15) {
                    Image(systemName: "arrow.right.to.line")
                        .foregroundColor(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("Sair da conta")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.red)
                        Text("Encerrar sessão")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                }
                .padding()
            }
            .background(Color("cardBackground"))
        }
        .frame(width: 280)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 10)
        .transition(.asymmetric(insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                                 removal: .opacity))
    }
}
