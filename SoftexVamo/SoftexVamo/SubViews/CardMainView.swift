//
//  CardMainView.swift
//  SoftexVamo
//
//  Created by Joao Victor on 07/04/26.
//

import SwiftUI

struct CardMainView: View {
    @EnvironmentObject var viewModel: CiclosListViewModel

    @State var presentCiclo = false

    let corFundoTela = LinearGradient.cardMain

    var progresso: CGFloat {
        let percent = viewModel.atualCiclo.valor_total > 0
            ? viewModel.atualCiclo.gasto_total / viewModel.atualCiclo.valor_total
            : 0
        return CGFloat(min(max(percent, 0), 1))
    }

    var percentualUtilizado: Int {
        Int(progresso * 100)
    }

    var diasCount: Int {
        let periodo = viewModel.atualCiclo.periodo
        let parts = periodo.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return viewModel.atualCiclo.dias?.count ?? 0 }

        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        formatter.locale = Locale(identifier: "pt_BR")

        let currentYear = Calendar.current.component(.year, from: Date())
        formatter.defaultDate = Calendar.current.date(from: DateComponents(year: currentYear))

        guard let from = formatter.date(from: parts[0]),
              let to = formatter.date(from: parts[1]) else {
            return viewModel.atualCiclo.dias?.count ?? 0
        }

        return Calendar.current.datesBetween(from, and: to)
    }

    var body: some View {
        ZStack {
            corFundoTela
                .frame(maxWidth: .infinity, maxHeight: 220)
                .cornerRadius(22)

                Image("maleta")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 160)
                    .opacity(0.45)
                    .frame(maxWidth: .infinity, maxHeight: 220, alignment: .bottomTrailing)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(7)
                        .background(Color.appPurpleDark)
                        .clipShape(Circle())
                    Text("Saldo disponível")
                        .font(.system(size: 13, weight: .regular))
                    Image(systemName: "eye")
                        .font(.system(size: 13, weight: .regular))
                }

                Text(
                    viewModel.atualCiclo.valor_total - viewModel.atualCiclo.gasto_total,
                    format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR"))
                )
                .font(.system(size: 36, weight: .heavy))
                .lineLimit(1)
                .truncationMode(.tail)

                (Text("de ")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                + Text(
                    viewModel.atualCiclo.valor_total,
                    format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR"))
                )
                .font(.system(size: 12, weight: .bold)))

                HStack {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.black.opacity(0.3))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: 0xA855F7))
                            .frame(width: geometry.size.width * progresso, height: 8)
                            .animation(.spring(), value: viewModel.atualCiclo.gasto_total)
                    }
                }
                .frame(height: 8)

                    Text("\(percentualUtilizado)% utilizado")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
//                .padding(.bottom)

                HStack(spacing: 0) {
                    statItem(
                        icon: "calendar",
                        label: "Período",
                        value: viewModel.atualCiclo.periodo,
                        subtitle: diasCount > 0 ? "\(diasCount) dias" : ""
                    )
                    
                    Spacer()

                    Divider()
                        .frame(width: 1, height: 32)
                        .background(.white.opacity(0.3))
                        .padding(.horizontal, 8)
                    
                    Spacer()

                    statItem(
                        icon: "dollarsign.circle",
                        label: "Gasto Total",
                        value: viewModel.atualCiclo.gasto_total,
                        format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")),
                        subtitle: "\(percentualUtilizado)% do total"
                    )
                    
                    Spacer()

                    Divider()
                        .frame(width: 1, height: 32)
                        .background(.white.opacity(0.3))
                        .padding(.horizontal, 8)
                    
                    Spacer()

                    statItem(
                        icon: "chart.line.uptrend.xyaxis",
                        label: "Média diária",
                        value: viewModel.atualCiclo.diaria,
                        format: .currency(code: "BRL").locale(Locale(identifier: "pt_BR")),
                        subtitle: "por dia"
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .onTapGesture {
            presentCiclo = true
            viewModel.selectedTab = 1
        }
    }

    @ViewBuilder
    private func statItem(icon: String, label: String, value: Any, format: FloatingPointFormatStyle<Float>.Currency? = nil, subtitle: String = "") -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .padding(8)
                .background(Color.appPurpleDark)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                if let format {
                    Text(value as! Float, format: format)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(value as! String)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

//    @ViewBuilder
//    private func statItem(icon: String, label: String, value: Float, format: FloatingPointFormatStyle<Float>.Currency, subtitle: String = "") -> some View {
//        HStack(spacing: 6) {
//            Image(systemName: icon)
//                .font(.system(size: 12))
//                .foregroundStyle(.white.opacity(0.75))
//                .padding(8)
//                .background(Color.appPurpleDark)
//                .clipShape(Circle())
//            VStack(alignment: .leading, spacing: 1) {
//                Text(label)
//                    .font(.system(size: 8, weight: .regular))
//                    .foregroundStyle(.white.opacity(0.75))
//                Text(value, format: format)
//                    .font(.system(size: 10, weight: .bold))
//                    .lineLimit(1)
//                    .minimumScaleFactor(0.7)
//                if !subtitle.isEmpty {
//                    Text(subtitle)
//                        .font(.system(size: 9, weight: .regular))
//                        .foregroundStyle(.white.opacity(0.6))
//                }
//            }
//        }
//    }
}

#Preview {
    CardMainView()
        .environmentObject(CiclosListViewModel())
}
