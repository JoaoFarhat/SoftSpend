//
//  ConfiguracoesView.swift
//  SoftSpend
//
//  Created by Cascade on 01/08/26.
//

import SwiftUI

struct ConfiguracoesView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var authService = AuthService.shared
    @State private var showDeleteConfirmation = false
    
    private let cardBackground = Color("cardBackground")
    private let screenBackground = Color("backgroundCor")
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                screenBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("CONTA")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color("textSecondary"))
                            .padding(.horizontal, 16)
                        
                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.red)
                                    .frame(width: 36, height: 36)
                                    .background(.red.opacity(0.1))
                                    .cornerRadius(10)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Excluir conta")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.red)
                                    Text("Remover todos os dados")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color("textSecondary"))
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color("textSecondary"))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cardBackground)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color("textPrimary").opacity(0.08), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        .disabled(authService.isLoading)
                        
                        Spacer()
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(Color("textSecondary"))
                            .font(.system(size: 18))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(Color("textPrimary"))
            .confirmationDialog("Excluir conta permanentemente?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Excluir minha conta", role: .destructive) {
                    Task {
                        await authService.deleteAccount()
                    }
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Todos os seus dados, ciclos e gastos serão apagados. Esta ação não pode ser desfeita.")
            }
        }
    }
}

#Preview {
    ConfiguracoesView()
}
