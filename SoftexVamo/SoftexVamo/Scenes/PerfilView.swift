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
    @EnvironmentObject var viewModel: CiclosViewModel
    @ObservedObject private var authService = AuthService.shared
    @State private var showConfiguracoes = false
    
    private let purplePrimary = Color.appPurple
    private let cardBackground = Color("cardBackground")
    private let screenBackground = Color("backgroundCor")
    
    private var user: UserModel? { authService.currentUser }
    
    private var ciclosCriados: Int { viewModel.allCiclos.count }
    
    private var ciclosAtivos: Int {
        viewModel.allCiclos.filter { ciclo in
            guard let dias = ciclo.dias?.last else { return false }
            return dias.data >= Date()
        }.count
    }
    
    private var totalGasto: Decimal {
        viewModel.allCiclos.reduce(Decimal(0)) { $0 + $1.gasto_total }
    }

    private var totalOrcado: Decimal {
        viewModel.allCiclos.reduce(Decimal(0)) { $0 + $1.valor_total }
    }

    private var percentUtilizado: Int {
        guard totalOrcado > 0 else { return 0 }
        let ratio = totalGasto / totalOrcado
        return Int((Double(truncating: NSDecimalNumber(decimal: ratio))) * 100)
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
                    headerSection
                    
                    statsGrid
                        .padding(.horizontal, 16)
                    
                    accountInfoSection
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfiguracoes = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(Color("textSecondary"))
                        .font(.system(size: 18))
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color("textPrimary"))
        .sheet(isPresented: $showConfiguracoes) {
            ConfiguracoesView()
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 14) {
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
                        .fill(Color("cardBackground"))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color("textSecondary"))
                        )
                        .offset(x: -2, y: -2)
                }
                
                // Name + badge
                VStack(spacing: 6) {
                    Text(user?.nome ?? "Usuário")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(Color("textPrimary"))
                    
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
                        .foregroundColor(Color("textSecondary"))
                }
            }
        
    }
    
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
    
    private var accountInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INFORMAÇÕES DA CONTA")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color("textSecondary"))
                .padding(.bottom, 4)
            
            VStack(spacing: 0) {
                AccountInfoRow(
                    icon: "person.fill",
                    title: "Nome completo",
                    value: user?.nome ?? "—"
                )
                
                Divider()
                    .background(Color("textPrimary").opacity(0.08))
                
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
                    .stroke(Color("textPrimary").opacity(0.08), lineWidth: 1)
            )
        }
    }
    
    private func formatCurrency(_ value: Decimal) -> String {
        value.formattedAsCurrency()
    }
}

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let subtitle: String?
    let subtitleColor: Color
    let accentColor: Color
    
    private let cardBg = Color("cardBackground")
    
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
                .foregroundColor(Color("textPrimary"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color("textSecondary"))
            
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
                .stroke(Color("textPrimary").opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}

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
                    .foregroundColor(Color("textSecondary"))
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color("textPrimary"))
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color("textSecondary"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

#Preview {
    PerfilView()
        .environmentObject(CiclosViewModel())
}
