//
//  PerfilView.swift
//  SoftSpend
//
//  Created by Gabriel fontes on 07/05/26.
//

import SwiftUI

/// Tela 17: perfil e ajustes. Conta (nome, e-mail, senha), preferências
/// (avisos de diária, leitura automática do comprovante, tema), sair e excluir
/// a conta. Sem estatísticas em cartões; "Ambiente API" só em build de desenvolvimento.
struct PerfilView: View {
    let usuario: UsuarioMenu

    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var assinatura = AssinaturaViewModel.shared
    @State private var mostrarGerenciarAssinatura = false

    /// Ausente = ligado (`AvisoDiaria.ativos`).
    @AppStorage(AvisoDiaria.chaveAtivos) private var avisosDiaria = true
    /// `nil` = ainda não perguntado; `true` = permitiu; `false` = "Agora não".
    @AppStorage(Consentimento.chave) private var leituraAutomatica: Bool?
    @AppStorage(PreferenciaTema.chave) private var tema: PreferenciaTema = .automatico

    @State private var confirmarExclusao = false
    /// Cartões que já chegaram pela ação "Registrar gasto" (§1.10), cada um
    /// com a chave liga/desliga.
    @State private var cartoesApplePay: [CartaoApplePay] = []

    #if DEBUG
    @State private var ambiente: APIEnvironment = APIConfig.shared.current
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cabecalho
                // Sempre disponível, mesmo com BILLING_ENFORCEMENT=off: é por
                // aqui que a revisão da Apple chega à compra (§3.2 e §4).
                secao("Assinatura")
                grupo {
                    NavigationLink {
                        PlanosAssinaturaView()
                    } label: {
                        linhaLink("Assinatura", valor: assinatura.resumo)
                    }
                }
                secao("Conta")
                grupo {
                    linhaValor("Nome", usuario.nome.isEmpty ? "—" : usuario.nome)
                    divisoria
                    linhaValor("E-mail", usuario.email.isEmpty ? "—" : usuario.email)
                    divisoria
                    linhaValor("Senha", "••••••••")
                        .accessibilityValue("oculta")
                }
                secao("Preferências")
                grupo {
                    linhaToggle("Avisos de diária", isOn: $avisosDiaria)
                    divisoria
                    linhaToggle("Leitura automática (comprovante e fatura)", isOn: Binding(
                        get: { leituraAutomatica == true },
                        set: { leituraAutomatica = $0 }
                    ))
                    divisoria
                    NavigationLink {
                        ComoLigarApplePayView()
                    } label: {
                        linhaLink("Apple Pay (atalho)")
                    }
                    divisoria
                    linhaTema
                }
                Text("Ligada, a foto ou o arquivo (comprovante ou fatura do cartão) é enviado para um serviço de leitura (Google Gemini).")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoFraco)
                    .padding(.horizontal, Espaco.g)
                    .padding(.top, Espaco.p)

                secao("Cartões do Apple Pay")
                if cartoesApplePay.isEmpty {
                    Text("Os cartões que chegarem pela automação aparecem aqui, cada um com uma chave liga/desliga.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoFraco)
                        .padding(.horizontal, Espaco.g)
                } else {
                    grupo {
                        ForEach(cartoesApplePay) { cartao in
                            if cartao.id != cartoesApplePay.first?.id { divisoria }
                            linhaToggle(cartao.nome, isOn: Binding(
                                get: { cartao.ligado },
                                set: { ligado in
                                    CartoesApplePay.shared.definirLigado(
                                        nome: cartao.nome, userId: cartao.userId, ligado: ligado)
                                    recarregarCartoes()
                                }
                            ))
                        }
                    }
                    Text("Cartão desligado tem as compras ignoradas. Desligar não apaga os gastos já lançados.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoFraco)
                        .padding(.horizontal, Espaco.g)
                        .padding(.top, Espaco.p)
                }

                #if DEBUG
                if !CommandLine.arguments.contains("-demo") {
                    secao("Desenvolvimento")
                    ambienteAPI
                }
                #endif

                VStack(spacing: Espaco.g) {
                    Button("Sair da conta") { authService.logout() }
                        .font(.body)
                        .foregroundStyle(Tema.estouro)
                    Button("Excluir conta") { confirmarExclusao = true }
                        .font(.footnote)
                        .foregroundStyle(Tema.textoFraco)
                        .disabled(authService.isLoading)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.bottom, Espaco.g + 8)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Perfil e ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recarregarCartoes() }
        .task { await assinatura.carregarEstado() }
        .confirmationDialog("Excluir conta permanentemente?", isPresented: $confirmarExclusao,
                            titleVisibility: .visible) {
            Button("Excluir minha conta", role: .destructive) {
                Task { await authService.deleteAccount() }
            }
            Button("Gerenciar assinatura") { mostrarGerenciarAssinatura = true }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todos os seus dados, ciclos e gastos serão apagados. Esta ação não pode ser desfeita.\n\nExcluir a conta não cancela uma assinatura da App Store.")
        }
        .gerenciarAssinatura(isPresented: $mostrarGerenciarAssinatura)
    }

    // MARK: Partes

    /// Relê a lista de cartões do usuário logado (§1.10). `UsuarioSalvo`
    /// cobre o app acordado pela ação antes do `checkAuthentication` encher
    /// `currentUser`; sem usuário, a seção mostra só o texto de espera.
    private func recarregarCartoes() {
        guard let userId = authService.currentUser?.id ?? UsuarioSalvo.id() else {
            cartoesApplePay = []
            return
        }
        cartoesApplePay = CartoesApplePay.shared.ler(userId: userId)
    }

    private var cabecalho: some View {
        VStack(spacing: Espaco.p) {
            Text(usuario.iniciais)
                .font(.title2.weight(.bold))
                .foregroundStyle(Tema.marcaTexto)
                .frame(width: 80, height: 80)
                .background(Tema.marcaFundo, in: Circle())
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(usuario.nome.isEmpty ? "Usuário" : usuario.nome)
                .font(.title3.weight(.bold))
                .foregroundStyle(Tema.texto)
                .multilineTextAlignment(.center)
            if !usuario.email.isEmpty {
                Text(usuario.email)
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Espaco.p)
        .accessibilityElement(children: .combine)
    }

    private func secao(_ titulo: String) -> some View {
        Text(titulo)
            .font(.title3.weight(.bold))
            .foregroundStyle(Tema.texto)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Espaco.p)
            .padding(.top, 28)
            .padding(.bottom, Espaco.m)
    }

    private func grupo<C: View>(@ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(spacing: 0) { conteudo() }
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }

    private var divisoria: some View {
        Rectangle().fill(Tema.borda).frame(height: 0.5).padding(.leading, Espaco.g)
    }

    private func linhaValor(_ titulo: String, _ valor: String) -> some View {
        HStack(spacing: Espaco.m) {
            Text(titulo)
                .foregroundStyle(Tema.texto)
            Spacer(minLength: Espaco.p)
            Text(valor)
                .foregroundStyle(Tema.textoFraco)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.body)
        .padding(.horizontal, Espaco.g)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }

    private func linhaToggle(_ titulo: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(titulo)
                .font(.body)
                .foregroundStyle(Tema.texto)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Tema.marcaBotao)
        .padding(.horizontal, Espaco.g)
        .padding(.vertical, Espaco.p)
        .frame(minHeight: 50)
    }

    private func linhaLink(_ titulo: String, valor: String? = nil) -> some View {
        HStack(spacing: Espaco.m) {
            Text(titulo)
                .font(.body)
                .foregroundStyle(Tema.texto)
            Spacer(minLength: Espaco.p)
            if let valor {
                Text(valor)
                    .font(.body)
                    .foregroundStyle(Tema.textoFraco)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tema.textoFraco)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Espaco.g)
        .frame(minHeight: 50)
    }

    private var linhaTema: some View {
        HStack(spacing: Espaco.m) {
            Text("Tema")
                .font(.body)
                .foregroundStyle(Tema.texto)
            Spacer(minLength: Espaco.p)
            Menu {
                Picker("Tema", selection: $tema) {
                    ForEach(PreferenciaTema.allCases) { opcao in
                        Text(opcao.nome).tag(opcao)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tema.nome)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.body)
                .foregroundStyle(Tema.textoFraco)
            }
            .accessibilityLabel("Tema, \(tema.nome)")
        }
        .padding(.horizontal, Espaco.g)
        .frame(minHeight: 50)
    }

    #if DEBUG
    private var ambienteAPI: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text("Ambiente API (só em desenvolvimento)")
                .font(.footnote)
                .foregroundStyle(Tema.textoFraco)
            Picker("Ambiente API", selection: $ambiente) {
                ForEach(APIEnvironment.allCases, id: \.self) { env in
                    Text(env.displayName).tag(env)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: ambiente) { _, novo in
                APIConfig.shared.current = novo
            }
        }
        .padding(Espaco.g)
        .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
    }
    #endif
}

#Preview("Claro") {
    NavigationStack {
        PerfilView(usuario: UsuarioMenu(nome: "João Victor Farhat", email: "joao@empresa.com"))
    }
    .preferredColorScheme(.light)
}

#Preview("Escuro") {
    NavigationStack {
        PerfilView(usuario: UsuarioMenu(nome: "João Victor Farhat", email: "joao@empresa.com"))
    }
    .preferredColorScheme(.dark)
}
