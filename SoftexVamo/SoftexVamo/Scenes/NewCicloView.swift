//
//  NewCicloView.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 26/03/26.
//

import SwiftUI
import Combine

struct NewCicloView: View {
    
    private enum Field: Int, CaseIterable {
        case nomeCiclo, orcamento
    }
    
    @Environment(\.dismiss) var dismiss
    
    @EnvironmentObject var cicloViewModel: CiclosListViewModel
    
    @State private var nomeCiclo: String = ""
    @State private var orcamentoString: String = ""
    @State private var orcamento: Float = 0.0
    @State private var dataInicio = Date()
    @State private var dataFim = Date().addingTimeInterval(86400 * 7)
    
    @FocusState private var focusedField: Field?
    
    @State private var hasScrolled: Bool = false
    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 50)
                    
                    Text("Novo Ciclo")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.bottom, 10)
                    
                    VStack(spacing: 25) {
                        InputField(title: "Nome do Ciclo", icon: "mappin.and.ellipse") {
                            TextField("Ex: São Paulo, SP", text: $nomeCiclo)
                                .font(.system(size: 18, weight: .medium))
                                .focused($focusedField, equals: .nomeCiclo)
                        }
                        
                        Divider()
                        
                        InputField(title: "Orçamento Total", icon: "briefcase") {
                            HStack {
                                Text("R$")
                                    .foregroundStyle(Color("textSecondary").opacity(0.65))
                                    .font(.system(size: 18, weight: .medium))
                                TextField("0,00", text: $orcamentoString)
                                    .keyboardType(.decimalPad)
                                    .onChange(of: orcamentoString) { oldValue, newValue in
                                        orcamento = verificarNumeros(orcamento: newValue)
                                    }
                                    .font(.system(size: 18, weight: .heavy))
                                    .focused($focusedField, equals: .orcamento)
                            }
                        }
                        
                        Divider()
                        
                        VStack(spacing: 20) {
                            DatePickerField(title: "Data de Início", date: $dataInicio)
                            DatePickerField(title: "Data de Fim", date: $dataFim)
                        }
                    }
                    .padding(25)
                    .background(Color("cardBackground"))
                    .cornerRadius(30)
                    .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 10)
                    
                    Spacer()
                    
                    Button(action: {
                        Task{
                            await cicloViewModel.createNewCiclo(startDate: dataInicio, endDate: dataFim, totalValue: Float(orcamento), titulo: nomeCiclo)
                            
                            await MainActor.run {
                                dismiss()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Criar Ciclo")
                        }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 65)
                        .background(Color(red: 0.65, green: 0.55, blue: 1.0))
                        .cornerRadius(20)
                    }
                }
                .padding(.horizontal, 25)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("scroll")).minY)
                    }
                )
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                withAnimation(.easeInOut(duration: 0.2)) {
                    hasScrolled = value < -5
                }
            }
            
            HStack {
                Button(action: { dismiss() }) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Voltar")
                    }
                    .foregroundColor(.appPurple)
                    .font(.system(size: 18, weight: .medium))
                }
                Spacer()
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 12)
            .background {
                Rectangle()
                    .fill(hasScrolled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color("surfaceBackground")))
                    .ignoresSafeArea(edges: .top)
            }
        }
        .onTapGesture {
            focusedField = nil
        }
        .background(Color("surfaceBackground"))
        .navigationBarHidden(true)
        
    }
    
    func verificarNumeros(orcamento: String) -> Float{
        
        let orcamentoFiltrado = orcamento.filter { "0123456789,.".contains($0) }
        
        let orcamentoCerto = orcamentoFiltrado.replacingOccurrences(of: ",", with: ".")
        
        if let valorConvertido = Float(orcamentoCerto){
            return valorConvertido
        }
        
        return 0.0
    }
}

struct InputField<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color("textPrimary"))
            
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.gray)
                content
                    .font(.system(size: 16))
            }
        }
    }
}

struct DatePickerField: View {
    
    let title: String
    @Binding var date: Date
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.gray)
                
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "pt_BR"))
                //                    .colorMultiply(.clear)
                
                Spacer()
            }
        }
    }
}

#Preview {
    NewCicloView()
        .environmentObject(NewCicloViewModel())
}

final class NewCicloViewModel: ObservableObject {
    @Published var textResult = ""
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
