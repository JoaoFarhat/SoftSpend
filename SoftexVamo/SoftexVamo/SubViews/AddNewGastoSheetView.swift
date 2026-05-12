//
//  AddNewGastoSheetView.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 26/03/26.
//

import SwiftUI
import PhotosUI

struct AddNewGastoSheetView: View {
    @Environment(\.dismiss) var dismiss
    
    private enum Field: Int, CaseIterable {
        case title, value, date
    }
    
    let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    @EnvironmentObject var viewModel: CiclosListViewModel
    
    @State var title: String = ""
    @State var valueString: String = ""
    @State private var value: Float = 0.0
    @State private var selectedCategoria: Categoria = .ALIMENTACAO
    
    let dias: [DiaSoftex]
    @State var selectedDia: DiaSoftex
    
    init(dias: [DiaSoftex]) {
        self.dias = dias
        let hoje = dias.first(where: { Calendar.current.isDateInToday($0.data) })
        let inicial = hoje ?? dias.first ?? DiaSoftex.examples[0]
        _selectedDia = State(initialValue: inicial)
    }
    
    let purplePrimary = Color.appPurple
    let purpleBackground = Color(red: 243/255, green: 232/255, blue: 255/255)
    let grayText = Color.black.opacity(0.6)
    let grayBorder = Color.gray.opacity(0.2)
    
    @FocusState private var focusedField: Field?
    @State private var hasScrolled: Bool = false
    
    @State private var photoItem: PhotosPickerItem?
    @State private var isExtraindo: Bool = false
    @State private var erroExtracao: String?
    @State private var showCamera: Bool = false
    @State private var showPhotosPicker: Bool = false
    @State private var capturedImage: UIImage?
    @State private var showSourceDialog: Bool = false
    
    var body: some View {
        let topInset = (UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.top }
            .first) ?? 0
        
        VStack(spacing: 0) {
            ZStack(alignment: .top){
                LinearGradient(
                    colors: [purplePrimary.opacity(0.9), Color.appPurpleDark.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(BottomCurveShape())
                .ignoresSafeArea(edges: .top)
                .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
                
                VStack(alignment: .leading){
                    HStack{
                        Button(action: { dismiss() }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("Voltar")
                            }
                            .foregroundColor(.white)
                            .font(.system(size: 18, weight: .bold))
                        }
                        Spacer()
                    }
                    .padding(.bottom, 10)
                    
                    Text("NOVO GASTO")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.60))
                    
                    VStack{
                        HStack{
                            Text("R$")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.60))
                            Spacer()
                            TextField("", text: $valueString, prompt: Text("0,00").foregroundColor(.white.opacity(0.70)))
                                .font(.system(size: 40, weight: .bold))
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .value)
                                .onChange(of: valueString) { _, newValue in
                                    value = verificarNumeros(orcamento: newValue)
                                }
                                
                        }
                        Text("Toque para digitar um valor")
                            .foregroundStyle(Color.white.opacity(0.60))
                            .font(.system(size: 12, weight: .bold))
                    }
                    .multilineTextAlignment(.center)
                    
                    Button(action: {
                        showSourceDialog = true
                    }) {
                        HStack(spacing: 12) {
                            if isExtraindo {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "doc.viewfinder.fill")
                                    .font(.system(size: 22, weight: .semibold))
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isExtraindo ? "Analisando comprovante..." : "Escanear comprovante")
                                    .font(.system(size: 16, weight: .bold))
                                Text(isExtraindo ? "Aguarde alguns segundos" : "Preencha automaticamente com IA")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.85)
                            }
                            
                            Spacer()
                            
                            if !isExtraindo {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [purplePrimary.opacity(0.9), .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .cornerRadius(20)
                        .shadow(color: purplePrimary.opacity(0.3), radius: 10, x: 0, y: 5)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.top, 10)
                    .shadow(color: Color.appPurple.opacity(0.4), radius: 20, y: 10)
                    .disabled(isExtraindo)
                }
                .padding()
                .padding(.top, topInset)
            }
            .frame(height: 280 + topInset)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20){
                    if let erro = erroExtracao {
                        Text(erro)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                    }
                VStack(alignment: .leading) {
                    InputField(title: "Descrição", icon: "") {
                        TextField("Ex: Almoço, Uber...", text: $title)
                            .font(.system(size: 18, weight: .medium))
                            .focused($focusedField, equals: .title)
                    }
                    
                    Divider()
                    
                    DatePickerFieldLimitado(title: "Data", diaSelecionado: $selectedDia, diasPermitidos: dias)
                    
                    
                }
                .padding()
                .background(Color("cinza"))
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 10)
                    
                    Text("Categoria")
                        .font(.system(size: 14, weight: .bold))
                    LazyVGrid(columns: columns) {
                        ForEach(Categoria.allCases) { categoria in
                            let isSelected = (categoria == selectedCategoria)
                            let cor = categoria.color
                            
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedCategoria = categoria
                                }
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    VStack(spacing: 12) {
                                        Image(systemName: iconName(for: categoria))
                                            .font(.system(size: 22, weight: .semibold))
                                            .frame(width: 44, height: 44)
                                            .background(
                                                Circle()
                                                    .fill(isSelected ? cor.opacity(0.25) : Color.white.opacity(0.05))
                                            )
                                        Text(categoria.localizedName.uppercased())
                                            .font(.system(size: 11, weight: .bold))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(isSelected ? cor : Color("textSecondary"))
                                    .padding(.vertical, 18)
                                    .frame(maxWidth: .infinity)
                                    .background(isSelected ? cor.opacity(0.15) : Color("cinza"))
                                    .cornerRadius(22)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 22)
                                            .stroke(isSelected ? cor : grayBorder, lineWidth: isSelected ? 2 : 1)
                                    )
                                    
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 22, height: 22)
                                            .background(Circle().fill(cor))
                                            .padding(8)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(minHeight: 150)
                
                Button(action: {
                    Task {
                        try await viewModel.createNewGasto(title: title, value: value, dia: selectedDia, categoria: selectedCategoria)
                        await MainActor.run { dismiss() }
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Salvar Gasto")
                    }
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 65)
                    .background(LinearGradient(
                        colors: [purplePrimary, .appPurpleDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .cornerRadius(20)
                }
                .padding(.top, 10)
            }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 50)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("gastoScroll")).minY)
                    }
                )
            }
            .coordinateSpace(name: "gastoScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                withAnimation(.easeInOut(duration: 0.2)) {
                    hasScrolled = value < -5
                }
            }
            
//            HStack {
//                Button(action: { dismiss() }) {
//                    HStack {
//                        Image(systemName: "chevron.left")
//                        Text("Voltar")
//                    }
//                    .foregroundColor(.purple)
//                    .font(.system(size: 18, weight: .medium))
//                }
//                Spacer()
//            }
//            .padding(.horizontal, 25)
//            .padding(.vertical, 12)
//            .background {
//                Rectangle()
//                    .fill(hasScrolled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color("surfaceBackground")))
//                    .ignoresSafeArea(edges: .top)
//            }
        }
        .background(Color("surfaceBackground").ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .onTapGesture { focusedField = nil }
        .confirmationDialog("Escanear comprovante", isPresented: $showSourceDialog, titleVisibility: .visible) {
            Button("Tirar foto") {
                showCamera = true
            }
            Button("Escolher da galeria") {
                showPhotosPicker = true
            }
            Button("Cancelar", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await processarImagem(data: data)
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .onChange(of: capturedImage) { _, newImage in
            guard let img = newImage, let data = img.jpegData(compressionQuality: 0.85) else { return }
            Task {
                await processarImagem(data: data)
                capturedImage = nil
            }
        }
    }
    
    @MainActor
    private func processarImagem(data: Data) async {
        isExtraindo = true
        erroExtracao = nil
        
        do {
            let resultado = try await NetworkManager.shared.extrairGastoDeImagem(imageData: data)
            
            withAnimation {
                title = resultado.titulo
                value = resultado.valor
                valueString = String(format: "%.2f", resultado.valor).replacingOccurrences(of: ".", with: ",")
                selectedCategoria = resultado.categoria
            }
        } catch {
            erroExtracao = "Nao foi possivel extrair os dados. Preencha manualmente."
            print("Erro ao extrair gasto:", error)
        }
        
        isExtraindo = false
    }
    
    func verificarNumeros(orcamento: String) -> Float{
        
        let orcamentoFiltrado = orcamento.filter { "0123456789,.".contains($0) }
        
        let orcamentoCerto = orcamentoFiltrado.replacingOccurrences(of: ",", with: ".")
        
        if let valorConvertido = Float(orcamentoCerto){
            return valorConvertido
        }
        
        return 0.0
    }
    
    func iconName(for categoria: Categoria) -> String {
        switch categoria {
        case .ALIMENTACAO: return "fork.knife"
        case .TRANSPORTE: return "car.fill"
        case .LAZER: return "ticket.fill"
        case .COMPRAS: return "bag.fill"
        case .OUTROS: return "ellipsis"
        }
    }
}

struct DatePickerFieldLimitado: View {
    let title: String
    @Binding var diaSelecionado: DiaSoftex
    let diasPermitidos: [DiaSoftex]
    
    private var dateRange: ClosedRange<Date> {
        let dates = diasPermitidos.map { $0.data }
        let minDate = dates.min() ?? Date()
        let maxDate = dates.max() ?? Date()
        return minDate...maxDate
    }
    
    private var dateProxy: Binding<Date> {
        Binding<Date>(
            get: {
                self.diaSelecionado.data
            },
            set: { newDate in
                if let foundDia = diasPermitidos.first(where: {
                    Calendar.current.isDate($0.data, inSameDayAs: newDate)
                }) {
                    self.diaSelecionado = foundDia
                }
            }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.gray)
                
                DatePicker("", selection: dateProxy, in: dateRange, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "pt_BR"))
                
                Spacer()
            }
        }
    }
}

func formatarData(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd/MM"
    return formatter.string(from: date)
}

struct BottomCurveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        path.move(to: .zero)
        
        // topo
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        
        // lado direito
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        
        // curva pra baixo (dentro do shape)
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height),
            control: CGPoint(x: rect.width / 2, y: rect.height - 30)
        )
        
        // lado esquerdo
        path.closeSubpath()
        
        return path
    }
}

#Preview {
    AddNewGastoSheetView(dias: DiaSoftex.examples)
}
