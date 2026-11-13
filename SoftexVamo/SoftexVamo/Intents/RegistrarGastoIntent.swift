import AppIntents
import Foundation
import SwiftData
import os

/// Ação "Registrar gasto" para a automação "Transação" do Apple Pay no app
/// Atalhos (§1.3 de `docs/cartao-sem-open-finance.md`). Roda sem abrir o app
/// — inclusive com o iPhone trancado, por isso lê o usuário do `user_data`
/// (`UsuarioSalvo`) em vez do `AuthService`, cujo token do Keychain é ilegível
/// nessa hora. Grava no `mainContext` do `BancoLocal.container`, o mesmo do
/// app aberto. Não loga valor nem estabelecimento.
nonisolated struct RegistrarGastoIntent: AppIntent {
    static let title: LocalizedStringResource = "Registrar gasto"
    static let description = IntentDescription("Grava a compra que a automação do Apple Pay entrega no dia de hoje da viagem aberta.")
    static let openAppWhenRun = false

    /// Texto da variável "Valor" da automação ("R$ 12,34").
    @Parameter(title: "Valor")
    var valor: String

    /// Vira o título do gasto (cortado em 60 caracteres).
    @Parameter(title: "Estabelecimento")
    var estabelecimento: String

    /// Aparece só no diálogo de resposta e na fila "sem viagem"; não é gravado
    /// no gasto (§1.8).
    @Parameter(title: "Cartão ou passe")
    var cartao: String?

    init() {
        valor = ""
        estabelecimento = ""
        cartao = nil
    }

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
                valorTexto: valor,
                estabelecimento: estabelecimento,
                cartao: cartao,
                userId: UsuarioSalvo.id(),
                em: BancoLocal.container.mainContext
            )
        } catch {
            Self.logger.error("RegistrarGastoIntent: falha ao gravar a compra: \(error.localizedDescription, privacy: .public)")
            return .result(dialog: "Não consegui registrar a compra: lance o gasto no app.")
        }

        // O cartão aparece só no diálogo, nunca no gasto (§1.3).
        let noCartao = cartao.map { " no \($0)" } ?? ""
        switch resultado {
        case .gravado(let titulo, let valor, let viagem, let dia):
            Self.logger.info("RegistrarGastoIntent: compra registrada")
            // App aberto: o SyncManager já está configurado e sobe o gasto, como
            // o createNewGasto faz. App fechado: quem envia é o onAppear do
            // MainView, como acontece com qualquer gasto pendente.
            Task { await SyncManager.shared.sync(forcar: true) }
            let diaDoMes = Calendar.current.component(.day, from: dia)
            return .result(dialog: "Gasto de \(formatarBRL(valor))\(noCartao) em \(titulo) registrado em \(viagem), dia \(diaDoMes).")
        case .guardadoSemViagem(let titulo, let valor):
            Self.logger.info("RegistrarGastoIntent: compra guardada sem viagem")
            return .result(dialog: "Gasto de \(formatarBRL(valor))\(noCartao) em \(titulo) guardado: lance numa viagem pelo app.")
        case .duplicado:
            return .result(dialog: "Essa compra já estava registrada.")
        case .recusado(let motivo):
            switch motivo {
            case .semUsuario:
                return .result(dialog: "Abra o SoftSpend e entre na sua conta.")
            case .moedaEstrangeira:
                return .result(dialog: "Compra em outra moeda: lance no app.")
            case .valorInvalido:
                return .result(dialog: "Não entendi o valor da compra: lance no app.")
            }
        }
    }
}
