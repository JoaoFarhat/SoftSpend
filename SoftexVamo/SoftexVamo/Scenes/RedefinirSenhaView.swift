//
//  RedefinirSenhaView.swift
//  SoftSpend
//
//  "Esqueci minha senha", aberta pelo login. Toda a regra está no
//  `RedefinirSenhaViewModel`; aqui só a montagem das duas etapas.
//

import SwiftUI

struct RedefinirSenhaView: View {

    @StateObject private var vm: RedefinirSenhaViewModel
    @Environment(\.dismiss) private var dismiss

    init(email: String = "") {
        _vm = StateObject(wrappedValue: RedefinirSenhaViewModel(email: email))
    }

    init(viewModel: RedefinirSenhaViewModel) {
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espaco.g) {
                    switch vm.etapa {
                    case .email: etapaEmail
                    case .codigo: etapaCodigo
                    case .senhaAlterada: etapaSenhaAlterada
                    }
                }
                .padding(.horizontal, Espaco.g + 4)
                .padding(.top, Espaco.p)
                .padding(.bottom, Espaco.g)
                .larguraLegivel()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tema.fundo.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                            Text("Entrar")
                        }
                    }
                    .accessibilityLabel("Voltar para entrar")
                }
            }
            .tint(Tema.marcaTexto)
        }
        .onDisappear { vm.limparSegredos() }
    }

    // MARK: Etapa 1: e-mail

    private var etapaEmail: some View {
        Group {
            titulo("Esqueci minha senha")

            Text("Informe o e-mail da sua conta. Se houver uma conta com ele, você recebe um código de 6 dígitos para criar uma senha nova.")
                .font(.body)
                .foregroundStyle(Tema.textoFraco)

            CampoAcesso(rotulo: "E-mail", texto: $vm.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            erroAtual

            BotaoPrincipalCarregando("Enviar código", carregando: vm.carregando) {
                Task { await vm.enviarCodigo() }
            }
            .disabled(!vm.podeEnviarCodigo)
            .opacity(vm.podeEnviarCodigo ? 1 : 0.5)
            .padding(.top, Espaco.p)
        }
    }

    // MARK: Etapa 2: código e senha nova

    private var etapaCodigo: some View {
        Group {
            titulo("Digite o código")

            Text("Se houver uma conta com \(Text(vm.emailAparado).fontWeight(.semibold)), enviamos um código de 6 dígitos para ela. Ele vale por \(vm.minutosValidade) minutos.")
                .font(.body)
                .foregroundStyle(Tema.textoFraco)

            CampoAcesso(rotulo: "Código", texto: $vm.codigo)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)

            CampoAcesso(rotulo: "Nova senha", texto: $vm.novaSenha, seguro: true)
                .textContentType(.newPassword)

            if !vm.novaSenha.isEmpty && !vm.regra.valida {
                RequisitosSenha(regra: vm.regra)
            }

            CampoAcesso(rotulo: "Confirmar nova senha", texto: $vm.confirmarSenha, seguro: true)
                .textContentType(.newPassword)

            if !vm.confirmarSenha.isEmpty && vm.novaSenha != vm.confirmarSenha {
                Text(RedefinirSenhaViewModel.Texto.senhasDiferentes)
                    .font(.footnote)
                    .foregroundStyle(Tema.estouro)
            }

            erroAtual

            BotaoPrincipalCarregando("Redefinir senha", carregando: vm.carregando) {
                Task { await vm.redefinir() }
            }
            .disabled(!vm.podeRedefinir)
            .opacity(vm.podeRedefinir ? 1 : 0.5)
            .padding(.top, Espaco.p)

            VStack(spacing: Espaco.m) {
                if !vm.bloqueado {
                    Button {
                        Task { await vm.reenviarCodigo() }
                    } label: {
                        Text(vm.segundosParaReenviar > 0
                             ? "Reenviar código (\(vm.segundosParaReenviar) s)"
                             : (vm.codigoRecusado ? "Pedir novo código" : "Reenviar código"))
                            .fontWeight(.semibold)
                    }
                    .disabled(!vm.podeReenviar)
                }

                Button("Usar outro e-mail") { vm.usarOutroEmail() }
                    .foregroundStyle(Tema.textoFraco)
            }
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.top, Espaco.p)
        }
    }

    // MARK: Senha trocada, mas sem entrar

    private var etapaSenhaAlterada: some View {
        Group {
            titulo("Senha alterada")

            Text("Sua senha nova já vale. Entre com ela para continuar.")
                .font(.body)
                .foregroundStyle(Tema.textoFraco)

            BotaoPrincipal("Voltar para entrar") { dismiss() }
                .padding(.top, Espaco.p)
        }
    }

    // MARK: Apoio

    private func titulo(_ texto: String) -> some View {
        Text(texto)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Tema.texto)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, Espaco.p)
    }

    @ViewBuilder
    private var erroAtual: some View {
        if let erro = vm.erro {
            Text(erro)
                .font(.footnote)
                .foregroundStyle(Tema.estouro)
        }
    }
}

#Preview("Claro") { RedefinirSenhaView(email: "joao@empresa.com").preferredColorScheme(.light) }
#Preview("Escuro") { RedefinirSenhaView().preferredColorScheme(.dark) }
