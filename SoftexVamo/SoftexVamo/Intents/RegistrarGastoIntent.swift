import AppIntents
import Foundation
import SwiftData

/// Ação "Registrar gasto" (§1.3 de docs/cartao-sem-open-finance.md): a
/// automação "Transação" do Atalhos a chama quando uma compra é feita com o
/// Apple Pay. Grava no dia de hoje da viagem aberta **sem abrir o app** e sem
/// depender do token (`UsuarioSalvo`): roda com o iPhone trancado.
// `nonisolated` no tipo: o projeto isola tudo no MainActor, e os requisitos do
// `AppIntent` (`title`, `openAppWhenRun`, os sintetizados de `@Parameter`) são
// `nonisolated` — o Atalhos os lê fora do MainActor. Só o `perform` (que toca
// o `mainContext`) volta explicitamente para o MainActor, como o resto do app.
nonisolated struct RegistrarGastoIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar gasto"
    static var description: IntentDescription? =
        "Grava a compra do Apple Pay como gasto no dia de hoje da viagem aberta."
    static var openAppWhenRun: Bool { false }

    /// Texto da variável "Valor" da automação ("R$ 12,34" ou "12,34").
    @Parameter(title: "Valor")
    var valor: String

    /// Vira o título do gasto.
    @Parameter(title: "Estabelecimento")
    var estabelecimento: String

    /// Só aparece no diálogo e na fila "sem viagem"; não é gravado no gasto.
    @Parameter(title: "Cartão ou passe")
    var cartao: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let userId = UsuarioSalvo.id() else {
            return .result(dialog: "Abra o SoftSpend e entre na sua conta.")
        }

        // O mesmo `ModelContainer` do app: a tela aberta atualiza na hora.
        let contexto = BancoLocal.container.mainContext
        let resultado = RegistroApplePay.registrar(
            valorTexto: valor,
            estabelecimento: estabelecimento,
            cartao: cartao,
            userId: userId,
            em: contexto
        )

        if case .gravado = resultado {
            // App aberto: sobe já, como o `createNewGasto`. App fechado: o
            // SyncManager nem está configurado e quem sobe é o `onAppear` do
            // MainView, como qualquer gasto pendente.
            Task { await SyncManager.shared.sync(forcar: true) }
        }

        return .result(dialog: "\(dialogo(resultado, userId: userId, em: contexto))")
    }

    /// Frase curta do diálogo do Atalhos (§1.3). Não loga valor nem
    /// estabelecimento: a ação roda com o aparelho trancado.
    @MainActor
    private func dialogo(_ resultado: ResultadoRegistro, userId: String, em contexto: ModelContext) -> String {
        switch resultado {
        case .gravado(let titulo, let valor, let viagem, let data):
            // "Dia 3" = terceiro dia da viagem; se a releitura não achar a
            // viagem (apagada no meio do caminho), cai no dia do mês.
            var numero = Calendar.current.component(.day, from: data)
            if let (ciclo, _) = RegistroApplePay.diaDeHoje(
                userId: userId, agora: data,
                calendario: .current, em: contexto
            ) {
                numero = RegistroApplePay.numeroDia(data, ciclo: ciclo, calendario: .current)
            }
            var msg = "Gasto de \(formatarBRL(valor)) em \(titulo) registrado em \(viagem), dia \(numero)."
            if let cartao, !cartao.trimmingCharacters(in: .whitespaces).isEmpty {
                msg += " Cartão: \(cartao)."
            }
            return msg
        case .guardadoSemViagem(let titulo, let valor):
            return "Gasto de \(formatarBRL(valor)) em \(titulo) guardado. Abra o SoftSpend para lançar numa viagem."
        case .duplicado:
            return "Essa compra já estava registrada."
        case .recusado(let motivo):
            switch motivo {
            case .semUsuario:
                return "Abra o SoftSpend e entre na sua conta."
            case .valorInvalido:
                return "Não consegui ler o valor da compra. Lance no app."
            case .moedaEstrangeira:
                return "Compra em outra moeda: lance no app."
            }
        }
    }
}
