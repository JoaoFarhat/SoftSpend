//
//  OpenFinanceView.swift
//  SoftSpend
//

import SwiftUI
import SwiftData

struct OpenFinanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var errorManager: ErrorManager
    @StateObject private var viewModel = OpenFinanceViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color("surfaceBackground").ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        resumoCard

                        if let resumo = viewModel.ultimoResumo {
                            Text(resumo)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color("textSecondary"))
                                .padding(.horizontal, 16)
                        }

                        if viewModel.cartoes.isEmpty && !viewModel.isLoading {
                            emptyState
                        } else {
                            ForEach(viewModel.cartoes, id: \.backendId) { cartao in
                                cartaoCard(cartao)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Cartão corporativo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Color("textPrimary"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.sincronizarTudo() }
                    } label: {
                        if viewModel.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color("textPrimary"))
                        }
                    }
                    .disabled(viewModel.isSyncing)
                }
            }
        }
        .task {
            viewModel.modelContext = modelContext
            viewModel.errorManager = errorManager
            await viewModel.carregarDados()
        }
        .refreshable {
            await viewModel.sincronizarTudo()
        }
    }

    private var resumoCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "creditcard.and.123")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient.appPurple)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 4) {
                Text("Fatura do cartão")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color("textPrimary"))
                Text("Veja as transações e confira quais gastos já foram conciliados.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color("textSecondary"))
            }

            Spacer()
        }
        .padding(16)
        .background(Color("cardBackground"))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color("textPrimary").opacity(0.08), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "creditcard")
                .font(.system(size: 42))
                .foregroundStyle(Color.appPurple.opacity(0.6))
            Text("Nenhuma fatura importada")
                .font(.system(size: 18, weight: .bold))
            Text("Toque em sincronizar depois de linkar o cartão no Pluggy.")
                .font(.system(size: 13))
                .foregroundStyle(Color("textSecondary"))
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.sincronizarTudo() }
            } label: {
                Label("Sincronizar agora", systemImage: "arrow.clockwise")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.appPurple)
                    .clipShape(Capsule())
            }
            .disabled(viewModel.isSyncing)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color("cardBackground"))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func cartaoCard(_ cartao: CartaoOpenFinance) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.appPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(cartao.titulo)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color("textPrimary"))
                    Text("\(cartao.institutionName ?? "Instituição") · \(cartao.numeroMascarado)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color("textSecondary"))
                }

                Spacer()
            }

            let faturas = cartao.faturas.sorted { ($0.dueDate ?? .distantPast) > ($1.dueDate ?? .distantPast) }
            if faturas.isEmpty {
                Text("Nenhuma fatura retornada pelo banco ainda.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color("textSecondary"))
                    .padding(.vertical, 8)
            } else {
                ForEach(faturas, id: \.backendId) { fatura in
                    NavigationLink {
                        FaturaDetalheView(fatura: fatura)
                            .environmentObject(viewModel)
                    } label: {
                        faturaRow(fatura)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color("cardBackground"))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color("textPrimary").opacity(0.08), lineWidth: 1)
        )
    }

    private func faturaRow(_ fatura: FaturaCartao) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appPurple)
                .frame(width: 38, height: 38)
                .background(Color.appPurple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(fatura.totalAmount?.formattedAsCurrency() ?? "Fatura")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color("textPrimary"))
                Text(fatura.periodo)
                    .font(.system(size: 11))
                    .foregroundStyle(Color("textSecondary"))
            }

            Spacer()

            Text("\(fatura.transacoes.count) transações")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color("textSecondary"))

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color("textSecondary"))
        }
        .padding(12)
        .background(Color("cinza").opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct FaturaDetalheView: View {
    @EnvironmentObject private var viewModel: OpenFinanceViewModel
    let fatura: FaturaCartao

    private var transacoesOrdenadas: [TransacaoCartao] {
        fatura.transacoes.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                faturaHeader

                Text("Transações")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color("textPrimary"))

                if transacoesOrdenadas.isEmpty {
                    Text("Nenhuma transação importada nesta fatura ainda.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color("textSecondary"))
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .background(Color("cardBackground"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(transacoesOrdenadas.enumerated()), id: \.element.backendId) { index, transacao in
                            transacaoRow(transacao)

                            if index < transacoesOrdenadas.count - 1 {
                                Divider()
                                    .padding(.leading, 62)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .background(Color("cardBackground"))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(16)
        }
        .background(Color("surfaceBackground"))
        .navigationTitle("Fatura")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.carregarFatura(fatura)
        }
    }

    private var faturaHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fatura.totalAmount?.formattedAsCurrency() ?? "Fatura")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Color("textPrimary"))
            Text(fatura.periodo)
                .font(.system(size: 13))
                .foregroundStyle(Color("textSecondary"))

            if let minimo = fatura.minimumPaymentAmount {
                Text("Pagamento mínimo: \(minimo.formattedAsCurrency())")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appPurple)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color("cardBackground"))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func transacaoRow(_ transacao: TransacaoCartao) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transacao.matchStatus?.icon ?? "creditcard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(transacao.matchStatus?.color ?? Color("textSecondary"))
                    .frame(width: 38, height: 38)
                    .background((transacao.matchStatus?.color ?? Color("textSecondary")).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    Text(transacao.titulo)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color("textPrimary"))
                    Text(transacao.date.map { Self.dateFormatter.string(from: $0) } ?? "Sem data")
                        .font(.system(size: 11))
                        .foregroundStyle(Color("textSecondary"))
                }

                Spacer()

                Text(transacao.amount?.formattedAsCurrency() ?? "--")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color("textPrimary"))
            }

            if let status = transacao.matchStatus {
                HStack {
                    Label(status.titulo, systemImage: status.icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(status.color.opacity(0.12))
                        .clipShape(Capsule())

                    if let gastoId = transacao.matchGastoBackendId {
                        Text("Gasto #\(gastoId)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color("textSecondary"))
                    }
                }

                if status == .review {
                    HStack(spacing: 10) {
                        Button {
                            Task { await viewModel.confirmarMatch(da: transacao) }
                        } label: {
                            Label("Confirmar", systemImage: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green)
                                .clipShape(Capsule())
                        }

                        Button {
                            Task { await viewModel.removerMatch(da: transacao) }
                        } label: {
                            Label("Remover", systemImage: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Button {
                        Task { await viewModel.removerMatch(da: transacao) }
                    } label: {
                        Text("Remover vínculo")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Ainda não vinculada a um gasto")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color("textSecondary"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()
}

#Preview {
    OpenFinanceView()
        .environmentObject(ErrorManager())
}
