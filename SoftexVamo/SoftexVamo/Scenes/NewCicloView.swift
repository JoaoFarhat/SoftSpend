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
    
    @EnvironmentObject var cicloViewModel: CiclosViewModel
    
    @State private var nomeCiclo: String
    @State private var orcamentoString: String
    @State private var orcamento: Float
    @State private var dataInicio: Date
    @State private var dataFim: Date
    
    var ciclo: CicloSoftex?
    
    var isEditing: Bool { ciclo != nil }
    
    var tituloTela: String {
        isEditing ? "Editar Ciclo" : "Novo Ciclo"
    }
    
    var textoBotaoSalvar: String {
        isEditing ? "Salvar Alterações" : "Criar Ciclo"
    }
    
    var onBack: (() -> Void)? = nil
    
    init(ciclo: CicloSoftex, onBack: (() -> Void)? = nil) {
        _nomeCiclo = State(initialValue: ciclo.titulo)
        _orcamentoString = State(initialValue: String(ciclo.valor_total))
        _orcamento = State(initialValue: ciclo.valor_total)
        self.onBack = onBack
        self.ciclo = ciclo
        
        if let primeiraData = ciclo.dias?.first?.data, let ultimaData = ciclo.dias?.last?.data {
            _dataInicio = State(initialValue: primeiraData)
            _dataFim = State(initialValue: ultimaData)
        } else {
            _dataInicio = State(initialValue: Date())
            _dataFim = State(initialValue: Date().addingTimeInterval(86400 * 7))
        }
    }
    
    init() {
        _nomeCiclo = State(initialValue: "")
        _orcamentoString = State(initialValue: "")
        _orcamento = State(initialValue: 0.0)
        _dataInicio = State(initialValue: Date())
        _dataFim = State(initialValue: Date().addingTimeInterval(86400 * 7))
    }
    
    @FocusState private var focusedField: Field?
    
    @State private var hasScrolled: Bool = false
    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading) {
                    Color.clear.frame(height: 30)
                    
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tituloTela)
                                .font(.system(size: 34, weight: .bold))

                            Text("Organize sua viagem e controle seus gastos")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image("bagagem")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 90, height: 70)
                    }
                    .padding(.bottom)
                    
                    VStack(spacing: 15) {
                        InputField(title: "Nome do Ciclo", icon: "mappin.and.ellipse", helperText: "Dê um nome para identificar sua viagem") {
                            TextField("Ex: São Paulo, SP", text: $nomeCiclo)
                                .font(.system(size: 18, weight: .medium))
                                .focused($focusedField, equals: .nomeCiclo)
                        }
                        
                        Divider()
                        
                        InputField(title: "Orçamento Total", icon: "briefcase", helperText: "Defina o valor total disponível para este ciclo") {
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
                        
                        VStack(spacing: 15) {
                            TextFieldDataView(dataSelecionada: $dataInicio, title: "Data de Início", helperText: "Quando a viagem começa")
                            Divider()
                            TextFieldDataView(dataSelecionada: $dataFim, title: "Data Final", helperText: "Quando a viagem termina")
                        }
                    }
                    .padding(25)
                    .background(Color("cardBackground").opacity(0.5))
                    .cornerRadius(30)
                    .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 10)
                    .padding(.bottom, 10)
                    
//                    Spacer()
                    
                    Button(action: {
                        Task{
                            if let ciclo, let cicloId = ciclo.backendId {
                                let dayCount = Calendar.current.datesBetween(dataInicio, and: dataFim)
                                let safeDayCount = max(dayCount, 1)
                                
                                var cicloEditado = ciclo
                                cicloEditado.titulo = nomeCiclo
                                cicloEditado.valor_total = orcamento
                                cicloEditado.periodo = createPeriodoString(from: dataInicio, to: dataFim)
                                cicloEditado.diaria = orcamento / Float(safeDayCount)
                                
                                let novosDias = cicloViewModel.createAllDiasLoteRequest(dayCount: dayCount, startDate: dataInicio)
                                
                                do {
                                    try await cicloViewModel.editCiclo(cicloId: cicloId, ciclo: cicloEditado, dias: novosDias)
                                } catch {
                                    print("Erro ao editar ciclo:", error)
                                    return
                                }
                            }
                            else {
                                await cicloViewModel.createNewCiclo(startDate: dataInicio, endDate: dataFim, totalValue: Float(orcamento), titulo: nomeCiclo)
                            }
                            
                            await MainActor.run {
                                dismiss()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "checkmark")
                            Text(textoBotaoSalvar)
                        }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 65)
                        .background(Color.roxoFinal)
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
                Button(action: {
                    if let onBack {
                        onBack()
                    } else {
                        dismiss()
                    }
                })
                {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("surfaceBackground").ignoresSafeArea())
        .navigationBarHidden(true)
        
    }
    
    private func createPeriodoString(from: Date, to: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM"
        return "\(dateFormatter.string(from: from)) - \(dateFormatter.string(from: to))"
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
    let helperText: String
    let content: Content

    init(
        title: String,
        icon: String,
        helperText: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.helperText = helperText
        self.content = content()
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(Color.roxoInicial)
                .padding(15)
                .background(
                    Circle()
                        .fill(Color.purplePrimary.opacity(0.3))
                )

            VStack(alignment: .leading) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))

                content
                    .padding()
                    .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.gray, lineWidth: 1)
                        )

                Text(helperText)
                    .font(.system(size: 10))
                    .foregroundColor(Color.textSecondary)
            }
        }
    }
}

struct TextFieldDataView: View {
    @Binding var dataSelecionada: Date
    let title: String
    let helperText: String
    
    init(dataSelecionada: Binding<Date>, title: String, helperText: String) {
        self._dataSelecionada = dataSelecionada
        self.title = title
        self.helperText = helperText
        
    }
    
    var dataFormatada: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter.string(from: dataSelecionada)
    }

    var body: some View {
        HStack{
            Image(systemName: "calendar")
                .foregroundColor(Color.roxoInicial)
                .padding(15)
                .background(
                    Circle()
                        .fill(Color.purplePrimary.opacity(0.3))
                )
            
            VStack(alignment: .leading) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                
                HStack {
                    Text(dataFormatada)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "calendar")
                        .foregroundColor(.gray)
                }
                .padding()
//                .background(Color(.gray))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.gray, lineWidth: 1)
                )
                .overlay(
                    DatePicker("", selection: $dataSelecionada, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .colorMultiply(.clear)
                )
                
                Text(helperText)
                    .font(.system(size: 10))
                    .foregroundColor(Color.textSecondary)
            }

        }
    }
}

struct DatePickerField: View {
    
    let title: String
    @Binding var date: Date
    
    var body: some View {
        HStack {
            Image(systemName: "calendar")
                .foregroundColor(Color.roxoInicial)
                .padding(15)
                .background(
                    Circle()
                        .fill(Color.purplePrimary.opacity(0.3))
                )
            
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))

                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "pt_BR"))
                    .datePickerStyle(.compact)
                
                Spacer()
            }
            
            Spacer()
        }
    }
}

#Preview {
    NewCicloView()
        .environmentObject(CiclosViewModel())
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
