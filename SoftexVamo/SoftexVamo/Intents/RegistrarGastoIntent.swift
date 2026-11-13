//
//  RegistrarGastoIntent.swift
//  SoftexVamo
//
//  Ação "Registrar gasto" do atalho do Apple Pay (§1.3 de
//  docs/cartao-sem-open-finance.md).
//

import AppIntents
import Foundation
import os

/// Grava o gasto da compra do Apple Pay **sem abrir o app e sem perguntar
/// nada**. A automação do app Atalhos (gatilho "Transação"/"Carteira") entrega
/// valor, estabelecimento e cartão como texto.
///
/// Roda no `mainContext` do `BancoLocal.container` — o mesmo container do app —
/// e só grava no SwiftData (gravação local não exige token, que é ilegível com
/// o iPhone trancado). Se o `SyncManager` já estiver configurado (app aberto),
/// pede `sync(forcar: true)`; com o app fechado, quem sobe o gasto é o
/// `onAppear` do `MainView`, como qualquer gasto pendente.
nonisolated struct RegistrarGastoIntent: AppIntent {
    static let title: LocalizedStringResource = "Registrar gasto"
    static let description = IntentDescription(
        "Grava a compra do Apple Pay no dia de hoje da viagem aberta."
    )
    static let openAppWhenRun = false

    /// Texto da variável "Valor" da automação ("R$ 12,34", "12,34"...).
    @Parameter(title: "Valor")
    var valor: String

    /// Vira o título do gasto.
    @Parameter(title: "Estabelecimento")
    var estabelecimento: String

    /// Só aparece no diálogo de resposta e na fila "sem viagem"; **não** é
    /// gravado no gasto (§1.8).
    @Parameter(title: "Cartão")
    var cartao: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar gasto de \(\.$valor) em \(\.$estabelecimento) com \(\.$cartao)")
    }

    init() {}

    init(valor: String, estabelecimento: String, cartao: String? = nil) {
        self.valor = valor
        self.estabelecimento = estabelecimento
        self.cartao = cartao
    }

    private static let logger = Logger(subsystem: "br.com.softspend", category: "RegistrarGastoIntent")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resultado: ResultadoRegistro
        do {
            resultado = try RegistroApplePay.registrar(
                valor: valor,
                estabelecimento: estabelecimento,
                cartao: cartao,
                userId: UsuarioSalvo.id(),
                em: BancoLocal.container.mainContext
            )
        } catch {
            Self.logger.error("Falha ao gravar gasto do Apple Pay: \(error.localizedDescription, privacy: .public)")
            return .result(dialog: "Não consegui gravar a compra. Lance no app.")
        }

        switch resultado {
        case .gravado(let titulo, let valor, let viagem, let dia):
            // Se o SyncManager já está configurado (app aberto) sobe agora; sem
            // conexão ou sem configurar, o pedido é ignorado sem erro.
            Task { await SyncManager.shared.sync(forcar: true) }
            let numero = Calendar.current.component(.day, from: dia)
            var resposta = "Gasto de \(formatarBRL(valor)) em \(titulo) registrado em \(viagem), dia \(numero)."
            if let cartao, !cartao.isEmpty {
                resposta += " (\(cartao))"
            }
            return .result(dialog: IntentDialog(stringLiteral: resposta))

        case .guardadoSemViagem(let titulo, let valor):
            var resposta = "Gasto de \(formatarBRL(valor)) em \(titulo) guardado: abra o SoftSpend para lançar numa viagem."
            if let cartao, !cartao.isEmpty {
                resposta += " (\(cartao))"
            }
            return .result(dialog: IntentDialog(stringLiteral: resposta))

        case .duplicado:
            return .result(dialog: "Essa compra já estava registrada.")

        case .recusado(.semUsuario):
            return .result(dialog: "Abra o SoftSpend e entre na sua conta.")

        case .recusado(.moedaEstrangeira):
            return .result(dialog: "Compra em outra moeda: lance no app.")

        case .recusado(.valorInvalido):
            return .result(dialog: "Não entendi o valor da compra. Lance no app.")
        }
    }
}
