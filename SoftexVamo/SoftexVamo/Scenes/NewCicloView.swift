//
//  NewCicloView.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 26/03/26.
//

import SwiftUI

extension EnvironmentValues {
    /// Formulário com que "Nova viagem" abre pela rota `.novaViagem` (modo de demonstração).
    @Entry var formularioNovaViagem: FormularioViagem? = nil
}

/// Tela 4: Nova viagem (e Editar viagem). Destino, ida, volta e os campos
/// ligados total ⇅ diária. O backend continua recebendo o total.
struct NewCicloView: View {
    private enum Foco: Hashable { case destino, total, diaria }
    private enum DataAberta { case ida, volta }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cicloViewModel: CiclosViewModel

    @State private var form: FormularioViagem
    @State private var dataAberta: DataAberta?
    @State private var erroSalvar: String?
    @State private var salvando = false
    @State private var confirmandoEncurtar = false
    @State private var gastosEmRisco = 0
    @FocusState private var foco: Foco?

    var ciclo: CicloSoftex?
    var onBack: (() -> Void)? = nil

    private var isEditing: Bool { ciclo != nil }

    /// Editar viagem: começa pelo total do ciclo e pelas datas dos dias
    /// (sem dias carregados, pelo `periodo`; nunca por "hoje + 7").
    init(ciclo: CicloSoftex, onBack: (() -> Void)? = nil) {
        self.ciclo = ciclo
        self.onBack = onBack
        let intervalo = intervaloViagem(ciclo)
        let ida = intervalo?.ini ?? Calendar.current.startOfDay(for: Date())
        let volta = intervalo?.fim ?? ida
        _form = State(initialValue: FormularioViagem(ida: ida, volta: volta, total: ciclo.valor_total,
                                                     destino: ciclo.titulo))
    }

    init(formulario: FormularioViagem? = nil) {
        let hoje = Calendar.current.startOfDay(for: Date())
        let volta = Calendar.current.date(byAdding: .day, value: 7, to: hoje) ?? hoje
        _form = State(initialValue: formulario ?? FormularioViagem(ida: hoje, volta: volta))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espaco.p) {
                campoDestino
                datas
                textoDias
                campoValor(.total)
                Label("um calcula o outro", systemImage: "arrow.up.arrow.down")
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .accessibilityLabel("Total e diária ligados: um calcula o outro")
                campoValor(.diaria)

                if let erroSalvar {
                    Text(erroSalvar)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Tema.estouro)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Espaco.p)
                }
            }
            .padding(.horizontal, Espaco.g + 10)
            .padding(.top, Espaco.p)
            .padding(.bottom, Espaco.g)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { barraTopo }
        .safeAreaInset(edge: .bottom) {
            BotaoPrincipal(isEditing ? "Salvar alterações" : "Criar viagem", acao: salvar)
                .disabled(salvando)
                .overlay { if salvando { ProgressView().tint(Tema.sobreCor) } }
                .padding(.horizontal, Espaco.g + 2)
                .padding(.top, Espaco.p)
                .padding(.bottom, Espaco.p)
                .background(Tema.fundo.ignoresSafeArea())
        }
        .background(Tema.fundo.ignoresSafeArea())
        .onChange(of: foco) { anterior, _ in
            if anterior == .total || anterior == .diaria { form.formatarCampos() }
        }
        .onAppear {
            // Viagem sincronizada sem dias locais: pede os dias ao servidor,
            // que `salvar` exige para editar sem corromper a viagem.
            if let ciclo, ciclo.backendId != nil, !(ciclo.dias ?? []).contains(where: { $0.deletadoEm == nil }) {
                cicloViewModel.abrirViagem(ciclo)
            }
        }
        .navigationBarHidden(true)
        .confirmationDialog("Encurtar a viagem?", isPresented: $confirmandoEncurtar,
                            titleVisibility: .visible) {
            Button("Salvar e excluir", role: .destructive) { confirmarEncurtar() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(gastosEmRisco == 1
                ? "1 gasto de dia fora das novas datas será excluído."
                : "\(gastosEmRisco) gastos de dias fora das novas datas serão excluídos.")
        }
    }

    // MARK: Campos

    private var campoDestino: some View {
        CampoFormulario(rotulo: "Destino") {
            TextField("Cidade, UF", text: $form.destino)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($foco, equals: .destino)
                .onSubmit { foco = .total }
        }
        .onTapGesture { foco = .destino }
        .onChange(of: form.destino) { _, _ in erroSalvar = nil }
    }

    private var datas: some View {
        VStack(spacing: Espaco.p) {
            HStack(spacing: Espaco.p) {
                botaoData("Ida", form.ida, .ida)
                botaoData("Volta", form.volta, .volta)
            }
            if let dataAberta {
                calendario(dataAberta)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func botaoData(_ rotulo: String, _ data: Date, _ qual: DataAberta) -> some View {
        Button {
            foco = nil
            withAnimation(.easeInOut(duration: 0.2)) { dataAberta = dataAberta == qual ? nil : qual }
        } label: {
            CampoFormulario(rotulo: rotulo) {
                Text(dataCurta(data))
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(Tema.texto)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rotulo), \(diaPorExtenso(data))")
        .accessibilityHint("Toque para escolher a data")
    }

    private func calendario(_ qual: DataAberta) -> some View {
        let selecao = Binding<Date>(
            get: { qual == .ida ? form.ida : form.volta },
            set: { nova in
                if qual == .ida { form.mudarIda(nova) } else { form.mudarVolta(nova) }
                erroSalvar = nil
                withAnimation(.easeInOut(duration: 0.2)) { dataAberta = nil }
            }
        )
        return Group {
            if qual == .volta {
                DatePicker("Volta", selection: selecao, in: form.ida..., displayedComponents: .date)
            } else {
                DatePicker("Ida", selection: selecao, displayedComponents: .date)
            }
        }
        .datePickerStyle(.graphical)
        .labelsHidden()
        .tint(Tema.marcaTexto)
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .padding(Espaco.p)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    private var textoDias: some View {
        let n = form.dias
        let texto: String
        if n < 1 {
            texto = "A volta precisa ser no dia da ida ou depois"
        } else if n == 1 {
            texto = "1 dia"
        } else {
            texto = "\(n) dias, contando ida e volta"
        }
        return Text(texto)
            .font(.subheadline)
            .foregroundStyle(n < 1 ? Tema.estouro : Tema.textoFraco)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
    }

    private func campoValor(_ campo: FormularioViagem.Campo) -> some View {
        let total = campo == .total
        let texto = Binding<String>(
            get: { total ? form.totalTexto : form.diariaTexto },
            set: { novo in
                // Só a digitação do usuário passa aqui: recalcular o outro campo
                // não chama este `set`, então não há laço.
                if total { form.editarTotal(novo) } else { form.editarDiaria(novo) }
                erroSalvar = nil
            }
        )
        // A borda da marca acompanha o campo em edição (10/11: ficava presa no Total).
        return CampoFormulario(rotulo: total ? "Total da viagem" : "Diária",
                               destacado: foco == (total ? .total : .diaria)) {
            HStack(spacing: 6) {
                Text("R$")
                TextField("0,00", text: texto)
                    .keyboardType(.decimalPad)
                    .focused($foco, equals: total ? .total : .diaria)
                    .accessibilityLabel(total ? "Total da viagem, em reais" : "Diária, em reais")
            }
            .font(total ? .title2.weight(.bold) : .body)
            .monospacedDigit()
            .foregroundStyle(Tema.texto)
        }
        .onTapGesture { foco = total ? .total : .diaria }
    }

    // MARK: Ações

    /// Barra fixa no topo: "Cancelar" à esquerda e o título pequeno no meio, como nos formulários do
    /// iPhone. O título grande empurrava os campos para baixo e "Criar viagem" colava no teclado (10/11).
    private var barraTopo: some View {
        ZStack {
            Text(isEditing ? "Editar viagem" : "Nova viagem")
                .font(.headline)
                .foregroundStyle(Tema.texto)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: fechar) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                        Text("Cancelar")
                    }
                    .font(.body)
                    .foregroundStyle(Tema.marcaTexto)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, Espaco.g + 2)
        .padding(.vertical, Espaco.m)
        .background(Tema.fundo.ignoresSafeArea(edges: .top))
    }

    private func fechar() {
        foco = nil
        if let onBack { onBack() } else { dismiss() }
    }

    private func salvar() {
        guard !salvando else { return }
        foco = nil
        form.formatarCampos()
        if let erro = form.erro {
            erroSalvar = erro
            return
        }
        guard let total = form.total else { return }
        erroSalvar = nil
        let titulo = form.destino.trimmingCharacters(in: .whitespacesAndNewlines)
        let ida = form.ida
        let volta = form.volta

        // Encurtar a viagem apaga, sem aviso, os dias fora das novas datas e os
        // gastos deles (editCiclo): com gastos em risco, confirma antes.
        if let ciclo {
            let emRisco = EncurtarViagem.gastosForaDoPeriodo(dias: ciclo.dias ?? [], ida: ida, volta: volta)
            if emRisco > 0 {
                gastosEmRisco = emRisco
                confirmandoEncurtar = true
                return
            }
        }

        gravar(titulo: titulo, ida: ida, volta: volta, total: total)
    }

    /// "Salvar e excluir" do aviso: o formulário não muda com o diálogo aberto,
    /// então os mesmos valores validados em `salvar` seguem valendo.
    private func confirmarEncurtar() {
        guard let total = form.total else { return }
        gravar(titulo: form.destino.trimmingCharacters(in: .whitespacesAndNewlines),
               ida: form.ida, volta: form.volta, total: total)
    }

    /// Salva de fato — direto, ou depois do "Salvar e excluir" do aviso de
    /// encurtar a viagem.
    private func gravar(titulo: String, ida: Date, volta: Date, total: Decimal) {
        salvando = true
        Task {
            if let ciclo {
                guard let cicloId = ciclo.backendId else {
                    // `editCiclo` localiza o ciclo pelo id do backend; antes dele, não edita
                    // (a tela antiga criava uma viagem nova por engano).
                    salvando = false
                    erroSalvar = "A viagem ainda está sincronizando. Tente editar daqui a pouco."
                    return
                }
                guard (ciclo.dias ?? []).contains(where: { $0.deletadoEm == nil }) else {
                    // Sem os dias locais, `editCiclo` recriaria todos os dias com clientIds novos:
                    // a viagem ficaria com dias duplicados ou em datas erradas.
                    salvando = false
                    erroSalvar = "Os dias da viagem ainda estão carregando. Tente de novo em instantes."
                    return
                }
                let dias = Calendar.current.datesBetween(ida, and: volta)
                let cicloEditado = ciclo
                cicloEditado.titulo = titulo
                cicloEditado.valor_total = total
                cicloEditado.periodo = periodoCurto(ida, volta)
                cicloEditado.diaria = ValoresViagem.diaria(total: total, dias: max(dias, 1))
                let novosDias = cicloViewModel.createAllDiasLoteRequest(dayCount: dias, startDate: ida)
                await cicloViewModel.editCiclo(cicloId: cicloId, ciclo: cicloEditado, dias: novosDias)
            } else {
                do {
                    try await cicloViewModel.createNewCiclo(startDate: ida, endDate: volta,
                                                            totalValue: total, titulo: titulo)
                } catch {
                    salvando = false
                    // Aviso no próprio formulário: o alerta da raiz não aparece
                    // sobre esta tela (fullScreenCover) e seria um aviso em dobro.
                    erroSalvar = "Não foi possível criar a viagem. Tente novamente."
                    return
                }
            }
            // Estado da tela zerado antes de fechar (AGENTS.md, armadilha 4).
            salvando = false
            fechar()
        }
    }

    private func periodoCurto(_ ida: Date, _ volta: Date) -> String {
        "\(dataCurta(ida)) - \(dataCurta(volta))"
    }
}

/// Campo agrupado da tela: rótulo pequeno sobre o valor, superfície sem borda;
/// `destacado` desenha a borda da marca (o campo em edição).
private struct CampoFormulario<Conteudo: View>: View {
    let rotulo: String
    var destacado: Bool = false
    @ViewBuilder let conteudo: Conteudo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rotulo)
                .font(.footnote)
                .foregroundStyle(Tema.textoFraco)
                .accessibilityHidden(true)
            conteudo
        }
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .overlay {
            if destacado {
                RoundedRectangle(cornerRadius: Raio.lista, style: .continuous)
                    .strokeBorder(Tema.marca, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NewCicloView()
        .environmentObject(CiclosViewModel())
        .environmentObject(ErrorManager())
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
