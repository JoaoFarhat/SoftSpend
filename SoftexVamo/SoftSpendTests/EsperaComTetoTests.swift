import Testing
import Foundation
@testable import SoftSpend

/// Portão próprio do teste: a operação fica parada em `esperar()` até o
/// teste chamar `liberar()`, e depois o teste espera a operação terminar
/// por `aguardarFim()` — tudo por continuação, sem `sleep` de tempo fixo.
private actor PortaoDoTeste {
    private var liberado = false
    private var terminou = false
    private var esperandoLiberacao: [CheckedContinuation<Void, Never>] = []
    private var esperandoFim: [CheckedContinuation<Void, Never>] = []

    /// Chamado pela operação: segura até o teste liberar.
    func esperar() async {
        guard !liberado else { return }
        await withCheckedContinuation { esperandoLiberacao.append($0) }
    }

    /// Chamado pelo teste: abre o portão e solta a operação.
    func liberar() {
        liberado = true
        esperandoLiberacao.forEach { $0.resume() }
        esperandoLiberacao.removeAll()
    }

    /// Chamado pela operação ao fim: acorda o `aguardarFim()` do teste.
    func sinalizarFim() {
        terminou = true
        esperandoFim.forEach { $0.resume() }
        esperandoFim.removeAll()
    }

    /// Chamado pelo teste: volta quando a operação já sinalizou o fim.
    func aguardarFim() async {
        guard !terminou else { return }
        await withCheckedContinuation { esperandoFim.append($0) }
    }
}

/// O que a operação gravou: se terminou e, no `Task.isCancelled` lido
/// dentro dela, se a `Task` dela estava cancelada.
private actor RegistroDoTeste {
    private(set) var terminou = false
    private(set) var estavaCancelada: Bool?

    func marcarTermino(cancelada: Bool) {
        terminou = true
        estavaCancelada = cancelada
    }
}

/// Testes diretos do `EsperaComTeto` (usado pela exportação do relatório
/// e pela leitura da fatura): ele promete voltar assim que a operação
/// termina — sem esperar o teto — e, passado o teto, voltar sem cancelar
/// a operação, que continua sozinha em background.
struct EsperaComTetoTests {

    /// Operação que termina na hora: o `esperar` volta por causa dela, não
    /// do teto — na volta o registro já diz "terminou". Com teto de 30 s,
    /// se ele esperasse o teto este teste demoraria 30 s.
    @Test func voltaQuandoAOperacaoTerminaSemEsperarOTeto() async {
        let registro = RegistroDoTeste()

        await EsperaComTeto.esperar(teto: .seconds(30)) {
            await registro.marcarTermino(cancelada: Task.isCancelled)
        }

        #expect(await registro.terminou)
    }

    /// Operação presa no portão com teto de 50 ms: o teto vence, o
    /// `esperar` volta com ela ainda rodando e **sem cancelá-la** — quando
    /// o teste abre o portão ela termina sozinha, e o `Task.isCancelled`
    /// lido dentro dela é `false`. Se o `esperar` passasse a cancelar a
    /// operação, um sync em voo marcaria os itens como `.failed` com
    /// backoff e a pessoa veria "falha" sem ter feito nada.
    @Test func passadoOTetoVoltaSemCancelarAOperacao() async {
        let portao = PortaoDoTeste()
        let registro = RegistroDoTeste()

        await EsperaComTeto.esperar(teto: .milliseconds(50)) {
            await portao.esperar()
            await registro.marcarTermino(cancelada: Task.isCancelled)
            await portao.sinalizarFim()
        }

        // Voltou pelo teto: a operação continua presa no portão.
        #expect(await registro.terminou == false)

        await portao.liberar()
        await portao.aguardarFim()

        #expect(await registro.terminou)
        #expect(await registro.estavaCancelada == false)
    }

    /// Dez vezes o caso do teto vencendo primeiro: a continuação do
    /// `esperar` nunca pode ser retomada duas vezes — a operação termina
    /// depois do teto e chama `responder()` de novo, que tem que ser
    /// no-op. Se não fosse, seria crash de "continuation resumed more
    /// than once" no segundo caso em diante.
    @Test func tetoSeguidoDeTerminoNaoRetomaAContinuacaoDuasVezes() async {
        for _ in 0..<10 {
            let portao = PortaoDoTeste()
            let registro = RegistroDoTeste()

            await EsperaComTeto.esperar(teto: .milliseconds(50)) {
                await portao.esperar()
                await registro.marcarTermino(cancelada: Task.isCancelled)
                await portao.sinalizarFim()
            }
            #expect(await registro.terminou == false)

            await portao.liberar()
            await portao.aguardarFim()
            #expect(await registro.terminou)
        }
    }
}
