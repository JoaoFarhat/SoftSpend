//
//  PerfilView.swift
//  SoftSpend
//
//  Created by Gabriel fontes on 07/05/26.
//

import SwiftUI
import Combine

struct PerfilView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: CiclosListViewModel
    @ObservedObject private var authService = AuthService.shared
    
    private let purplePrimary = Color.appPurple
    private let cardBackground = Color(red: 0.12, green: 0.11, blue: 0.18)
    private let screenBackground = Color(red: 0.06, green: 0.05, blue: 0.10)
    
    private var user: UserModel? { authService.currentUser }
    
    private var ciclosCriados: Int { viewModel.allCiclos.count }
    
    private var ciclosAtivos: Int {
        viewModel.allCiclos.filter { ciclo in
            guard let dias = ciclo.dias?.last else { return false }
            return dias.data >= Date()
        }.count
    }
    
    private var totalGasto: Float {
        viewModel.allCiclos.reduce(0) { $0 + $1.gasto_total }
    }
    
    private var totalOrcado: Float {
        viewModel.allCiclos.reduce(0) { $0 + $1.valor_total }
    }
    
    private var percentUtilizado: Int {
        guard totalOrcado > 0 else { return 0 }
        return Int((totalGasto / totalOrcado) * 100)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            screenBackground.ignoresSafeArea()
            
            RadialGradient(
                colors: [purplePrimary.opacity(0.4), screenBackground],
                center: .top,
                startRadius: 0,
                endRadius: 350
            )
            .frame(height: 350)
            .ignoresSafeArea(edges: .top)
            
            ScrollView() {
                VStack(spacing: 24) {
                    // MARK: - Header
                    headerSection
                    
                    // MARK: - Stats Cards
                    statsGrid
                        .padding(.horizontal, 16)
                    
                    // MARK: - Account Info
                    accountInfoSection
                        .padding(.horizontal, 16)
                    
                    // MARK: - Preferences placeholder
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PREFERÊNCIAS")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.system(size: 18))
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
    }
    
    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 14) {
                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [purplePrimary, Color.appPurpleDark.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 90, height: 90)
                        .overlay(
                            Text(user?.nome.prefix(1).uppercased() ?? "?")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundColor(.white)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [purplePrimary, .appPurpleDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 3
                                )
                        )
                    
                    Circle()
                        .fill(Color(red: 0.18, green: 0.16, blue: 0.25))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                        )
                        .offset(x: -2, y: -2)
                }
                
                // Name + badge
                VStack(spacing: 6) {
                    Text(user?.nome ?? "Usuário")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(purplePrimary)
                        Text("VIAJANTE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(purplePrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(purplePrimary.opacity(0.15))
                    .cornerRadius(10)
                    
                    Text(user?.email ?? "email@exemplo.com")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
    }
    
    // MARK: - Stats Grid
    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatCard(
                icon: "calendar",
                value: "\(ciclosCriados)",
                label: "CICLOS CRIADOS",
                subtitle: ciclosCriados > 0 ? "+\(min(ciclosCriados, 2)) este mês" : nil,
                subtitleColor: purplePrimary,
                accentColor: purplePrimary
            )
            
            StatCard(
                icon: "chart.line.uptrend.xyaxis",
                value: "\(ciclosAtivos)",
                label: "CICLOS ATIVOS",
                subtitle: ciclosAtivos > 0 ? "\(ciclosAtivos) em andamento" : nil,
                subtitleColor: Color(hex: 0x06B6D4),
                accentColor: Color(hex: 0x06B6D4)
            )
            
            StatCard(
                icon: "dollarsign.circle",
                value: formatCurrency(totalGasto),
                label: "TOTAL GASTO",
                subtitle: nil,
                subtitleColor: .red,
                accentColor: .red
            )
            
            StatCard(
                icon: "wallet.bifold",
                value: formatCurrency(totalOrcado),
                label: "TOTAL ORÇADO",
                subtitle: totalOrcado > 0 ? "\(percentUtilizado)% utilizado" : nil,
                subtitleColor: .green,
                accentColor: .green
            )
        }
    }
    
    // MARK: - Account Info
    private var accountInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INFORMAÇÕES DA CONTA")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 4)
            
            VStack(spacing: 0) {
                AccountInfoRow(
                    icon: "person.fill",
                    title: "Nome completo",
                    value: user?.nome ?? "—"
                )
                
                Divider()
                    .background(Color.white.opacity(0.08))
                
                AccountInfoRow(
                    icon: "envelope.fill",
                    title: "E-mail",
                    value: user?.email ?? "—"
                )
            }
            .background(cardBackground)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Helpers
    private func formatCurrency(_ value: Float) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "R$ 0,00"
    }
}

// MARK: - Stat Card
private struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let subtitle: String?
    let subtitleColor: Color
    let accentColor: Color
    
    private let cardBg = Color(red: 0.12, green: 0.11, blue: 0.18)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 36, height: 36)
                .background(accentColor.opacity(0.12))
                .cornerRadius(10)
            
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.45))
            
            Text(subtitle ?? " ")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(subtitle != nil ? subtitleColor : .clear)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBg)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

// MARK: - Account Info Row
private struct AccountInfoRow: View {
    let icon: String
    let title: String
    let value: String
    
    private let purplePrimary = Color.appPurple
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(purplePrimary)
                .frame(width: 36, height: 36)
                .background(purplePrimary.opacity(0.1))
                .cornerRadius(10)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

#Preview {
    PerfilView()
        .environmentObject(CiclosListViewModel())
}
