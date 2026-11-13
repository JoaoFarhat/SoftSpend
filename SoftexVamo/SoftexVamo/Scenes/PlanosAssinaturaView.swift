//
//  PlanosAssinaturaView.swift
//  SoftSpend
//
//  Tela de planos (docs/assinatura.md §3.2). Segue o que a regra 3.1.2 da
//  Apple exige: nome, duração e preço vindos da App Store, texto do teste só
//  para quem é elegível, renovação automática, Termos e Privacidade,
//  Restaurar compras e Gerenciar assinatura. A regra fica no
//  `AssinaturaViewModel`; esta tela só monta.
//

import SwiftUI

/// Endereços dos textos legais exigidos pela loja.
/// PENDENTE (§6): os textos ainda não estão hospedados (rascunhos em
/// `docs/legal/`). A tela não vai para a loja antes de essas URLs responderem.
enum LinksLegais {
    static let termos = URL(string: "https://softspend.com.br/termos")!
    static let privacidade = URL(string: "https://softspend.com.br/privacidade")!
}

struct PlanosAssinaturaView: View {
    @ObservedObject var vm: AssinaturaViewModel
    @State private var mostrarGerenciar = false

    init(vm: AssinaturaViewModel = .shared) {
        _vm = ObservedObject(wrappedValue: vm)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espaco.g) {
                if vm.pagamentoFalhando {
                    faixaPagamento
                }
                if vm.jaAssina {
                    cartaoJaAssina
                } else {
                    cabecalho
                }
                beneficios
                if !vm.jaAssina {
                    listaDePlanos
                }
                if let mensagem = vm.mensagem {
                    aviso(mensagem)
                }
                textoRenovacao
                acoes
                linksLegais
            }
            .padding(.horizontal, Espaco.g + 2)
            .padding(.vertical, Espaco.g)
        }
        .background(Tema.fundo.ignoresSafeArea())
        .navigationTitle("Assinatura")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.carregarEstado()
            if vm.planos.isEmpty { await vm.carregarPlanos() }
        }
        .gerenciarAssinatura(isPresented: $mostrarGerenciar)
    }

    // MARK: Partes

    private var cabecalho: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text("SoftSpend completo")
                .font(.title2.weight(.bold))
                .foregroundStyle(Tema.texto)
            Text("Lançar gastos à mão, ver e sincronizar suas viagens continua grátis, com ou sem assinatura.")
                .font(.subheadline)
                .foregroundStyle(Tema.textoFraco)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cartaoJaAssina: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text("Você já assina")
                .font(.title3.weight(.bold))
                .foregroundStyle(Tema.texto)
            if let plano = vm.nomeDoPlano {
                Text("Plano \(plano.lowercased())")
                    .font(.body)
                    .foregroundStyle(Tema.texto)
            }
            if let data = vm.estado?.expiraEm {
                Text(textoData(data))
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Espaco.g)
        .background(Tema.okFundo, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func textoData(_ data: Date) -> String {
        let dia = data.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()
            .locale(Locale(identifier: "pt_BR")))
        switch vm.estado?.status {
        case "trial": return "Teste grátis até \(dia)"
        case "grace", "billing_retry": return "Período pago até \(dia)"
        // O servidor ainda não diz se a renovação automática está ligada.
        default: return "Válida até \(dia)"
        }
    }

    private var faixaPagamento: some View {
        Button { mostrarGerenciar = true } label: {
            HStack(spacing: Espaco.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text("Seu pagamento falhou. Atualize a forma de pagamento.")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Tema.alertaTexto)
            .padding(Espaco.m)
            .background(Tema.alertaFundo, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Raio.lista, style: .continuous)
                    .stroke(Tema.alertaBorda, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Abre o gerenciamento da assinatura na App Store")
    }

    private var beneficios: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text("O assinante recebe")
                .font(.headline)
                .foregroundStyle(Tema.texto)
            ForEach([
                "Viagens novas",
                "Leitura de comprovante e de fatura por IA",
                "Relatório em PDF e CSV"
            ], id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: Espaco.p) {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Tema.ok)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(Tema.texto)
                }
            }
        }
    }

    @ViewBuilder
    private var listaDePlanos: some View {
        if vm.carregandoPlanos && vm.planos.isEmpty {
            HStack {
                Spacer()
                ProgressView("Carregando os planos…")
                Spacer()
            }
            .padding(.vertical, Espaco.g)
        } else if let erro = vm.erroAoCarregarPlanos, vm.planos.isEmpty {
            VStack(spacing: Espaco.m) {
                Text(erro)
                    .font(.body)
                    .foregroundStyle(Tema.texto)
                    .multilineTextAlignment(.center)
                BotaoSecundario("Tentar de novo") {
                    Task { await vm.carregarPlanos() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Espaco.g)
        } else {
            VStack(spacing: Espaco.m) {
                ForEach(vm.planos) { plano in
                    cartaoPlano(plano)
                }
            }
        }
    }

    private func cartaoPlano(_ plano: PlanoLoja) -> some View {
        Button {
            Task { await vm.comprar(plano) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(plano.periodo.nome)
                        .font(.headline)
                        .foregroundStyle(Tema.texto)
                    Spacer(minLength: Espaco.p)
                    Text(plano.preco)
                        .font(.headline)
                        .foregroundStyle(Tema.texto)
                }
                Text("Duração: \(plano.periodo.duracao)")
                    .font(.subheadline)
                    .foregroundStyle(Tema.textoFraco)
                if let teste = plano.testeGratis {
                    Text("\(teste.texto) grátis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tema.marcaTexto)
                    Text(plano.textoDepoisDoTeste)
                        .font(.subheadline)
                        .foregroundStyle(Tema.textoFraco)
                }
                Text(plano.testeGratis == nil ? "Assinar" : "Começar o teste grátis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Tema.sobreCor)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Tema.marcaBotao, in: Capsule())
                    .padding(.top, Espaco.p)
            }
            .padding(Espaco.g)
            .background(Tema.superficie, in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(vm.ocupado)
        .opacity(vm.ocupado ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func aviso(_ mensagem: MensagemAssinatura) -> some View {
        Text(mensagem.texto)
            .font(.subheadline)
            .foregroundStyle(mensagem.ehSucesso ? Tema.ok : Tema.alertaTexto)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Espaco.m)
            .background(mensagem.ehSucesso ? Tema.okFundo : Tema.alertaFundo,
                        in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var textoRenovacao: some View {
        Text("A assinatura renova sozinha, a menos que seja cancelada pelo menos 24 horas antes do fim do período; cancele em Ajustes › Apple ID › Assinaturas. A cobrança é feita na sua conta da App Store.")
            .font(.footnote)
            .foregroundStyle(Tema.textoFraco)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var acoes: some View {
        VStack(spacing: Espaco.m) {
            if vm.ocupado {
                ProgressView()
            }
            BotaoSecundario("Restaurar compras") {
                Task { await vm.restaurar() }
            }
            .disabled(vm.ocupado)
            BotaoSecundario("Gerenciar assinatura") {
                mostrarGerenciar = true
            }
        }
    }

    private var linksLegais: some View {
        HStack(spacing: Espaco.g) {
            Link("Termos de Uso", destination: LinksLegais.termos)
            Link("Política de Privacidade", destination: LinksLegais.privacidade)
        }
        .font(.footnote)
        .tint(Tema.marcaTexto)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Claro") {
    NavigationStack { PlanosAssinaturaView() }
        .preferredColorScheme(.light)
}
