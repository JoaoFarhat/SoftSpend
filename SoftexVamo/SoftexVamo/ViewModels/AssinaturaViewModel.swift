//
//  AssinaturaViewModel.swift
//  SoftSpend
//
//  Regra da assinatura no app (I1, docs/assinatura.md §3.2), testável sem
//  StoreKit: recebe a loja (`LojaAssinaturaProtocolo`) e a API
//  (`AssinaturaAPI`) no `init`.
//
//  Princípio 1: só o servidor libera recurso (`tem_acesso`). O StoreKit serve
//  para comprar, restaurar e mostrar o plano; nunca para destravar nada.
//

import Foundation
import Combine
import os

/// Mensagem da tela de planos depois de uma ação.
nonisolated enum MensagemAssinatura: Equatable, Sendable {
    case aguardandoAprovacao
    case confirmandoComServidor
    case restaurada
    case naoEncontrada
    case outraConta
    case falha(String)

    var texto: String {
        switch self {
        case .aguardandoAprovacao:
            return "Compra aguardando aprovação. Quando for aprovada, a assinatura começa sozinha."
        case .confirmandoComServidor:
            return "Compra recebida; confirmando com o servidor… Você não será cobrado de novo."
        case .restaurada:
            return "Assinatura restaurada."
        case .naoEncontrada:
            return "Não encontramos assinatura para esta conta."
        case .outraConta:
            return "Esta assinatura pertence a outra conta do SoftSpend."
        case .falha(let texto):
            return texto
        }
    }

    /// Mensagens boas aparecem em verde; as outras, como aviso.
    var ehSucesso: Bool { self == .restaurada }

    var ehFalha: Bool {
        if case .falha = self { return true }
        return false
    }
}

/// O que aconteceu ao mandar uma transação ao servidor.
nonisolated enum ResultadoEnvioTransacao: Equatable, Sendable {
    /// Servidor aceitou; a transação foi finalizada no StoreKit.
    case aceita
    /// Sem usuário logado: fica sem `finish()` até haver login.
    case semUsuario
    /// A compra é de outra conta (409, ou token diferente do da conta logada).
    /// Não finaliza nem repete nesta sessão.
    case outraConta
    /// Servidor fora, rede ou outro erro: fica pendente para a próxima abertura.
    case falhou
}

@MainActor
final class AssinaturaViewModel: ObservableObject {
    static let shared = AssinaturaViewModel()

    static let erroPlanos = "Não foi possível carregar os planos."

    /// Último `GET /api/assinatura` (ou resposta do `/transacoes`). `nil` =
    /// desconhecido (nunca carregou, sem internet ou rota ainda fora do ar).
    @Published private(set) var estado: AssinaturaResponse?
    @Published private(set) var planos: [PlanoLoja] = []
    @Published private(set) var carregandoPlanos = false
    @Published private(set) var erroAoCarregarPlanos: String?
    /// Compra ou restauração em andamento (desliga os botões).
    @Published private(set) var ocupado = false
    @Published var mensagem: MensagemAssinatura?

    private let loja: LojaAssinaturaProtocolo
    private let api: AssinaturaAPI
    private let usuarioLogado: @MainActor () -> String?
    private let sincronizar: @MainActor () async -> Void
    private let logger = Logger(subsystem: "br.com.softspend", category: "Assinatura")

    /// Transações recusadas (outra conta) nesta sessão: não reenviadas em loop.
    private var recusadas: Set<UInt64> = []
    private var tarefaAtualizacoes: Task<Void, Never>?

    /// Os padrões são os de produção (App Store, `NetworkManager`, usuário do
    /// `AuthService`, `SyncManager.sync(forcar: true)`); os testes trocam tudo.
    init(
        loja: LojaAssinaturaProtocolo? = nil,
        api: AssinaturaAPI = NetworkManager.shared,
        usuarioLogado: (@MainActor () -> String?)? = nil,
        sincronizar: (@MainActor () async -> Void)? = nil
    ) {
        self.loja = loja ?? LojaAppStore()
        self.api = api
        // Exige `isAuthenticated`: os testes de outras suítes mexem só no
        // `currentUser`, e uma chamada sem token aqui terminaria em logout.
        self.usuarioLogado = usuarioLogado ?? {
            AuthService.shared.isAuthenticated ? AuthService.shared.currentUser?.id : nil
        }
        self.sincronizar = sincronizar ?? { await SyncManager.shared.sync(forcar: true) }
    }

    // MARK: Estado para a tela

    /// Tem (ou teve, com cobrança falhando) uma assinatura: a tela mostra
    /// "Você já assina" em vez dos planos.
    var jaAssina: Bool {
        guard let status = estado?.status else { return false }
        return ["trial", "active", "grace", "billing_retry"].contains(status)
    }

    /// `grace`/`billing_retry`: "Seu pagamento falhou".
    var pagamentoFalhando: Bool {
        guard let status = estado?.status else { return false }
        return status == "grace" || status == "billing_retry"
    }

    var nomeDoPlano: String? {
        guard let produto = estado?.produto,
              let periodo = ProdutoAssinatura.periodo(de: produto) else { return nil }
        return periodo.nome
    }

    /// Linha do cartão "Assinatura" no Perfil.
    var resumo: String {
        guard let estado else { return "Ver planos" }
        switch estado.status {
        case "trial": return "Teste grátis"
        case "active": return nomeDoPlano.map { "Plano \($0.lowercased())" } ?? "Ativa"
        case "grace", "billing_retry": return "Pagamento falhou"
        case "expired": return "Expirada"
        case "revoked": return "Cancelada"
        default: return "Ver planos"
        }
    }

    // MARK: Abertura do app

    /// Chamado uma vez, na cena raiz: começa a ouvir `Transaction.updates`
    /// (renovações, compras de outro aparelho, aprovação do "Pergunte antes de
    /// comprar") e reenvia as compras que o servidor ainda não aceitou.
    func iniciar() {
        guard tarefaAtualizacoes == nil else { return }
        let fluxo = loja.atualizacoes()
        tarefaAtualizacoes = Task { [weak self] in
            for await transacao in fluxo {
                guard let self else { return }
                let resultado = await self.enviar(transacao)
                if resultado == .aceita {
                    await self.depoisDeLiberar()
                }
            }
        }
        Task { await reenviarPendentes() }
    }

    /// Login, logout ou troca de conta: esquece o estado da conta anterior e,
    /// com alguém logado, relê o estado e reenvia as compras pendentes.
    func trocouUsuario() async {
        estado = nil
        mensagem = nil
        recusadas = []
        guard usuarioLogado() != nil else { return }
        await carregarEstado()
        await reenviarPendentes()
    }

    /// `GET /api/assinatura`. Falha mantém o estado anterior (desconhecido
    /// fica desconhecido): quem decide no envio é o servidor.
    func carregarEstado() async {
        guard usuarioLogado() != nil else { return }
        do {
            estado = try await api.obterAssinatura()
        } catch {
            logger.warning("carregarEstado: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reenvia as transações sem `finish()` (servidor fora na hora da compra,
    /// compra feita sem login). Devolve quantas o servidor aceitou.
    @discardableResult
    func reenviarPendentes() async -> Int {
        guard usuarioLogado() != nil else { return 0 }
        var aceitas = 0
        let pendentes = await loja.naoFinalizadas()
        for transacao in pendentes {
            if await enviar(transacao) == .aceita { aceitas += 1 }
        }
        if aceitas > 0 {
            await depoisDeLiberar()
            if mensagem == .confirmandoComServidor { mensagem = nil }
        }
        return aceitas
    }

    // MARK: Planos

    func carregarPlanos() async {
        carregandoPlanos = true
        erroAoCarregarPlanos = nil
        defer { carregandoPlanos = false }
        do {
            let lista = try await loja.carregarPlanos()
            planos = lista
            if lista.isEmpty { erroAoCarregarPlanos = Self.erroPlanos }
        } catch {
            logger.warning("carregarPlanos: \(error.localizedDescription, privacy: .public)")
            erroAoCarregarPlanos = Self.erroPlanos
        }
    }

    // MARK: Comprar

    func comprar(_ plano: PlanoLoja) async {
        guard !ocupado else { return }
        ocupado = true
        defer { ocupado = false }
        mensagem = nil

        // O token da conta vem do servidor: sem ele, a compra não teria como
        // ser ligada a esta conta.
        if estado == nil { await carregarEstado() }
        guard let textoToken = estado?.appAccountToken,
              let token = UUID(uuidString: textoToken) else {
            mensagem = .falha("Não foi possível falar com o servidor. Confira a internet e tente de novo.")
            return
        }

        let resultado: ResultadoCompraLoja
        do {
            resultado = try await loja.comprar(planoId: plano.id, appAccountToken: token)
        } catch {
            logger.error("comprar: \(error.localizedDescription, privacy: .public)")
            mensagem = .falha("Não foi possível concluir a compra. Tente de novo.")
            return
        }

        switch resultado {
        case .aprovada(let transacao):
            switch await enviar(transacao) {
            case .aceita:
                await depoisDeLiberar()
            case .outraConta:
                mensagem = .outraConta
            case .semUsuario, .falhou:
                // A Apple já cobrou; a transação segue sem `finish()` e é
                // reenviada na próxima abertura (nunca cobra duas vezes).
                mensagem = .confirmandoComServidor
            }
        case .pendente:
            mensagem = .aguardandoAprovacao
        case .cancelada:
            break
        case .naoVerificada:
            mensagem = .falha("Não foi possível confirmar a compra com a App Store.")
        }
    }

    // MARK: Restaurar

    func restaurar() async {
        guard !ocupado else { return }
        ocupado = true
        defer { ocupado = false }
        mensagem = nil

        do {
            try await loja.sincronizarComAppStore()
        } catch ErroLoja.cancelado {
            return
        } catch {
            // Sem o `sync`, ainda vale reenviar o que o aparelho já conhece.
            logger.warning("restaurar: AppStore.sync falhou: \(error.localizedDescription, privacy: .public)")
        }

        var vistas: Set<UInt64> = []
        var transacoes: [TransacaoLoja] = []
        let direitos = await loja.direitosAtuais()
        let pendentes = await loja.naoFinalizadas()
        for transacao in direitos + pendentes where !vistas.contains(transacao.id) {
            vistas.insert(transacao.id)
            transacoes.append(transacao)
        }

        var resultados: [ResultadoEnvioTransacao] = []
        for transacao in transacoes {
            resultados.append(await enviar(transacao))
        }

        if resultados.contains(.aceita) {
            await depoisDeLiberar()
            mensagem = .restaurada
        } else if resultados.contains(.outraConta) {
            mensagem = .outraConta
        } else if resultados.contains(.falhou) {
            mensagem = .falha("Não foi possível falar com o servidor. Tente de novo em instantes.")
        } else {
            mensagem = .naoEncontrada
        }
    }

    // MARK: Envio ao servidor

    /// Manda a transação a `POST /api/assinatura/transacoes` e só então chama
    /// `finish()`. Nunca finaliza sem o servidor aceitar.
    func enviar(_ transacao: TransacaoLoja) async -> ResultadoEnvioTransacao {
        guard usuarioLogado() != nil else { return .semUsuario }
        if recusadas.contains(transacao.id) { return .outraConta }
        // Token de outra conta (compra feita por outro login neste Apple ID):
        // nem envia; o servidor responderia 409.
        if let daTransacao = transacao.appAccountToken,
           let textoConta = estado?.appAccountToken,
           let daConta = UUID(uuidString: textoConta),
           daTransacao != daConta {
            recusadas.insert(transacao.id)
            return .outraConta
        }
        do {
            estado = try await api.enviarTransacaoAssinatura(jws: transacao.jws)
            await transacao.finalizar()
            return .aceita
        } catch APIError.serverError(_, _, let statusCode) where statusCode == 409 {
            recusadas.insert(transacao.id)
            logger.warning("enviar: compra de outra conta (409)")
            return .outraConta
        } catch {
            logger.warning("enviar: \(error.localizedDescription, privacy: .public)")
            return .falhou
        }
    }

    /// Depois de compra ou restauração aceita: relê o estado e sobe o que
    /// ficou parado pela falta de assinatura (§3.4).
    private func depoisDeLiberar() async {
        await carregarEstado()
        await sincronizar()
    }
}
