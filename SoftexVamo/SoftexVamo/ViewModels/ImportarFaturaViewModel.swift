//
//  ImportarFaturaViewModel.swift
//  SoftSpend
//
//  Fluxo A1 de docs/cartao-sem-open-finance.md (§2.1, §2.5, §2.8):
//  escolher a fatura (PDF/OFX/CSV) da viagem → consentimento → ler →
//  conferir em três grupos → "Importar".
//
//  Nada é gravado antes do "Importar": o `ler` é só leitura, e os gastos só
//  são criados depois que o `POST /api/faturas` confirma a gravação — se ele
//  falha, nenhum gasto existe (§2.11). O `importar` reentra em `.importando`
//  para um toque duplo não mandar duas requisições.
//

import Foundation
import Combine
import SwiftData
import os

/// Validação do arquivo no aparelho, antes de qualquer envio (§2.3): extensão
/// e tamanho; o conteúdo quem confere é o servidor.
nonisolated enum ArquivoFatura {
    enum Tipo: String, Sendable {
        case pdf, ofx, csv

        var mime: String {
            switch self {
            case .pdf: return "application/pdf"
            case .ofx: return "application/octet-stream"
            case .csv: return "text/csv"
            }
        }
    }

    enum Erro: LocalizedError, Equatable {
        case ilegivel
        case vazio
        case tipoInvalido
        case muitoGrande(limiteMB: Int)

        var errorDescription: String? {
            switch self {
            case .ilegivel:
                return "Não foi possível ler o arquivo escolhido."
            case .vazio:
                return "O arquivo está vazio."
            case .tipoInvalido:
                return "Formato não reconhecido. Envie a fatura em PDF, OFX ou CSV."
            case .muitoGrande(let limite):
                return "O arquivo passa do tamanho máximo (\(limite) MB)."
            }
        }
    }

    static let tamanhoMaximoPDF = 10 * 1024 * 1024
    static let tamanhoMaximoTexto = 2 * 1024 * 1024

    static func tipo(eLimite nomeArquivo: String) -> (Tipo, Int)? {
        switch (nomeArquivo as NSString).pathExtension.lowercased() {
        case "pdf": return (.pdf, tamanhoMaximoPDF)
        case "ofx": return (.ofx, tamanhoMaximoTexto)
        case "csv": return (.csv, tamanhoMaximoTexto)
        default: return nil
        }
    }

    /// Extensão + tamanho, sem abrir o conteúdo (é o servidor que confere).
    /// `Data` vazia e tipo errado são barrados no aparelho (§2.11).
    static func validar(dados: Data, nomeArquivo: String) throws -> Tipo {
        guard !dados.isEmpty else { throw Erro.vazio }
        guard let (tipo, limite) = tipo(eLimite: nomeArquivo) else { throw Erro.tipoInvalido }
        guard dados.count <= limite else {
            throw Erro.muitoGrande(limiteMB: limite / (1024 * 1024))
        }
        return tipo
    }

    /// Lê o arquivo escolhido no `.fileImporter` (URL com escopo de segurança,
    /// como `NotaFiscal.abrir`) e valida.
    static func abrir(_ url: URL) throws -> (dados: Data, tipo: Tipo, nome: String) {
        let acessou = url.startAccessingSecurityScopedResource()
        defer { if acessou { url.stopAccessingSecurityScopedResource() } }
        guard let dados = try? Data(contentsOf: url) else { throw Erro.ilegivel }
        let tipo = try validar(dados: dados, nomeArquivo: url.lastPathComponent)
        return (dados, tipo, url.lastPathComponent)
    }
}

/// Qual tela de consentimento o `.consentindo` mostra (§2.8).
nonisolated enum ConsentimentoFatura: Equatable, Sendable {
    /// A pergunta padrão da leitura automática (primeira vez ou já negada).
    case pergunta
    /// O aviso de uma tela da primeira importação de fatura.
    case avisoFatura
}

@MainActor
final class ImportarFaturaViewModel: ObservableObject {
    enum Etapa: Equatable {
        case escolhendo
        case consentindo(ConsentimentoFatura)
        case lendo
        case pedindoSenha
        case conferindo
        case importando
        case pronto
        case erro(String)
    }

    /// Uma compra da prévia com as escolhas da pessoa na conferência.
    /// Struct: a view nunca muta `@Model` durante o `body`.
    struct CompraConferencia: Identifiable {
        let compra: CompraLida
        /// Dia local da viagem com a data da compra; `nil` = fora da viagem.
        /// O `dia_id` da prévia é o id do servidor — para criar o gasto o app
        /// precisa do `DiaSoftex` local.
        let dia: DiaSoftex?
        /// "Faltam": desmarcada por padrão — a pessoa decide o que vira gasto.
        var marcada = false
        /// "Desvincular" na já lançada: o match da prévia não vale; a compra
        /// desce para "Faltam" (desmarcada).
        var desvinculada = false
        /// "Confirmar" no "Revisar": a pessoa já confirma o vínculo aqui.
        var confirmada = false
        var id: Int { compra.indice }
    }

    @Published private(set) var etapa: Etapa = .escolhendo
    @Published private(set) var compras: [CompraConferencia] = []
    @Published private(set) var fatura: FaturaLida?
    /// Senha do PDF: só em memória, nunca gravada nem logada (§2.4).
    @Published var senha = ""
    @Published private(set) var senhaIncorreta = false
    @Published private(set) var resumoImportacao = ""
    /// Aviso local: gastos ainda não enviados podem aparecer como "faltam" (§2.5).
    @Published private(set) var avisoPendentes: String?
    /// Vencimento que a pessoa informa quando o arquivo não traz a data
    /// (CSV/OFX sem vencimento): sem ele o `POST /api/faturas` dá 422.
    @Published var vencimentoInformado = Date()
    /// `true` quando a leitura não achou o vencimento — a conferência pede
    /// a data antes do "Importar" em vez de falhar com 422 no fim.
    var precisaVencimento: Bool { fatura?.vencimento == nil }

    let ciclo: CicloSoftex
    /// Setado pela view no `task` (o `init` não lê o environment).
    var contexto: ModelContext?

    private let api: FaturaAPI
    private let sincronizar: @MainActor () async -> Void
    private let criarGasto: @MainActor (CompraLida, DiaSoftex) async throws -> Void
    private let acesso: AssinaturaViewModel
    private let defaults: UserDefaults
    private var arquivo: Data?
    private var nomeArquivo = "fatura"
    private var tipoArquivo: ArquivoFatura.Tipo = .pdf
    private var gastosCriados = 0
    private var gastosFalharam = 0
    /// A `Task` da leitura, guardada para a folha cancelar pelo
    /// `onDisappear` — uma leitura em voo não segue em background.
    private var tarefaLeitura: Task<Void, Never>?
    /// Teto da espera do `sync(forcar:)` antes da leitura (20 s em
    /// produção; injetável para os testes não esperarem).
    private let tetoSync: Duration
    private let logger = Logger(subsystem: "br.com.softspend", category: "ImportarFatura")

    init(
        ciclo: CicloSoftex,
        api: FaturaAPI = NetworkManager.shared,
        sincronizar: @escaping @MainActor () async -> Void = {
            await SyncManager.shared.sync(forcar: true)
        },
        criarGasto: @escaping @MainActor (CompraLida, DiaSoftex) async throws -> Void,
        acesso: AssinaturaViewModel = .shared,
        defaults: UserDefaults = .standard,
        tetoSync: Duration = .seconds(20)
    ) {
        self.ciclo = ciclo
        self.api = api
        self.sincronizar = sincronizar
        self.criarGasto = criarGasto
        self.acesso = acesso
        self.defaults = defaults
        self.tetoSync = tetoSync
    }

    // MARK: - Arquivo e consentimento

    /// O arquivo escolhido no `.fileImporter` (view).
    func receberArquivo(_ url: URL) {
        do {
            let (dados, tipo, nome) = try ArquivoFatura.abrir(url)
            receber(dados: dados, tipo: tipo, nome: nome)
        } catch {
            etapa = .erro(error.localizedDescription)
        }
    }

    /// Caminho da view: valida, cobra o consentimento se preciso e dispara a
    /// leitura. Os testes chamam `preparar` + `await ler()` direto.
    func receber(dados: Data, tipo: ArquivoFatura.Tipo, nome: String) {
        guard preparar(dados: dados, tipo: tipo, nome: nome) else { return }
        dispararLeitura()
    }

    /// Só a decisão, sem efeito assíncrono. `true` = pode chamar `ler()`.
    /// PDF precisa da leitura por IA permitida e mostra o aviso uma vez (§2.8);
    /// OFX e CSV não passam pela IA e vão direto.
    @discardableResult
    func preparar(dados: Data, tipo: ArquivoFatura.Tipo, nome: String) -> Bool {
        arquivo = dados
        tipoArquivo = tipo
        nomeArquivo = nome
        senha = ""
        senhaIncorreta = false
        if tipo == .pdf {
            if Consentimento.leitura(em: defaults) != true {
                etapa = .consentindo(.pergunta)
                return false
            }
            if !Consentimento.avisoFatura(em: defaults) {
                etapa = .consentindo(.avisoFatura)
                return false
            }
        }
        return true
    }

    /// Caminho da view: resposta da `ConsentimentoLeituraView`.
    func responderConsentimento(_ permitiu: Bool) {
        guard decidirConsentimento(permitiu) else { return }
        dispararLeitura()
    }

    /// Só a decisão, sem efeito assíncrono. `true` = pode chamar `ler()`.
    @discardableResult
    func decidirConsentimento(_ permitiu: Bool) -> Bool {
        Consentimento.gravar(permitiu, em: defaults)
        guard permitiu else {
            etapa = .erro("A fatura em PDF só é lida com a leitura por IA. Ative em Perfil e ajustes — ou envie OFX/CSV, que não passam pela IA.")
            return false
        }
        guard Consentimento.avisoFatura(em: defaults) else {
            etapa = .consentindo(.avisoFatura)
            return false
        }
        return true
    }

    /// "Continuar" do aviso da primeira importação (§2.8).
    func continuarAvisoFatura() {
        Consentimento.gravarAvisoFatura(true, em: defaults)
        dispararLeitura()
    }

    /// Dispara `ler()` numa `Task` guardada — o `onDisappear` da folha
    /// cancela por `cancelarLeitura()` para a leitura não seguir em
    /// background depois de fechar.
    private func dispararLeitura() {
        tarefaLeitura?.cancel()
        tarefaLeitura = Task { await ler() }
    }

    /// `onDisappear` da folha: cancela a leitura em voo. Nada foi gravado
    /// (a leitura é só prévia), então parar no meio não deixa pendência.
    func cancelarLeitura() {
        tarefaLeitura?.cancel()
        tarefaLeitura = nil
    }

    /// "Agora não" do aviso (não grava: aparece de novo na próxima importação)
    /// e "escolher outro arquivo" do erro.
    func voltarParaEscolha() {
        etapa = .escolhendo
    }

    // MARK: - Leitura

    /// `sync(forcar:)` antes, para a conciliação ver os gastos do dia (§2.5);
    /// o `ciclo_id` é lido depois do sync — a viagem criada offline pode ter
    /// acabado de subir. Só começa a partir de um estado que espera leitura —
    /// um `Task` duplicado depois de `.conferindo` não lê de novo.
    func ler() async {
        guard let arquivo else { return }
        switch etapa {
        case .lendo, .conferindo, .importando, .pronto: return
        case .escolhendo, .consentindo, .pedindoSenha, .erro: break
        }
        // §3.5: sem acesso conhecido a leitura não sai — a tela de planos
        // abre por cima da folha e a etapa fica onde estava.
        guard acesso.exigirAcesso() else { return }
        etapa = .lendo
        await sincronizarComTeto()
        guard !Task.isCancelled else { return }
        do {
            let lida = try await api.lerFatura(
                arquivo: arquivo,
                nomeArquivo: nomeArquivo,
                tipo: tipoArquivo,
                senha: senha.isEmpty ? nil : senha,
                cicloId: ciclo.backendId
            )
            guard !Task.isCancelled else { return }
            fatura = lida
            if lida.vencimento == nil {
                // CSV/OFX podem não trazer vencimento: a pessoa informa na
                // conferência; o padrão é a data da última compra lida.
                vencimentoInformado = lida.compras.map(\.data).max() ?? Date()
            }
            compras = lida.compras.map {
                CompraConferencia(compra: $0, dia: diaPara($0.data))
            }
            let pendentes = gastosPendentes()
            avisoPendentes = pendentes == 0 ? nil
                : "\(pendentes) \(pendentes == 1 ? "gasto ainda não enviado pode" : "gastos ainda não enviados podem") aparecer como faltando"
            etapa = .conferindo
        } catch {
            guard !Task.isCancelled else { return }
            // 403 `subscription_required` direto: planos, não "Erro no servidor".
            if acesso.tratarErroDeAcesso(error) {
                etapa = .escolhendo
                return
            }
            // §2.4: o 422 de senha volta para a pergunta da senha, não para erro.
            if case APIError.serverError(let message, _, let code) = error,
               code == 422, message.localizedCaseInsensitiveContains("senha") {
                senhaIncorreta = message.localizedCaseInsensitiveContains("incorreta")
                etapa = .pedindoSenha
                return
            }
            etapa = .erro(mensagemDeErro(error))
        }
    }

    /// "Ler" da tela de senha do PDF.
    func enviarSenha() {
        guard !senha.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dispararLeitura()
    }

    /// O `sync(forcar:)` antes da leitura é um aquecimento: com a rede
    /// ruim ele não pode segurar a tela — espera no máximo `tetoSync` e a
    /// leitura segue. O sync **não é cancelado** (continua sozinho em
    /// background): cancelar marcaria os itens em voo como `.failed` no
    /// `SyncActor`, um backoff que não existiria sem a tela.
    private func sincronizarComTeto() async {
        let corrida = CorridaDoTeto()
        await withCheckedContinuation { (continuacao: CheckedContinuation<Void, Never>) in
            Task {
                await self.sincronizar()
                if await corrida.responder() { continuacao.resume() }
            }
            Task {
                try? await Task.sleep(for: self.tetoSync)
                if await corrida.responder() { continuacao.resume() }
            }
        }
    }

    // MARK: - Conferência (três grupos + estornos/encargos)

    /// Dia local da viagem com a data da compra (`diasValidos` já desempata
    /// duplicatas antigas ficando com o dia sincronizado).
    private func diaPara(_ data: Date) -> DiaSoftex? {
        diasValidos(ciclo).first {
            Calendar.current.isDate($0.data, inSameDayAs: data)
        }
    }

    /// "Já lançadas": a compra bateu com um gasto da viagem e a pessoa não
    /// desvinculou.
    var jaLancadas: [CompraConferencia] {
        compras.filter { $0.dia != nil && $0.compra.match != nil && !$0.desvinculada }
    }

    /// "Faltam na viagem": compras dentro das datas sem vínculo (ou
    /// desvinculadas), desmarcadas por padrão (§2.5).
    var faltam: [CompraConferencia] {
        compras.filter(ehFaltam)
    }

    /// Estornos e encargos dentro da viagem: aparecem na lista, mas nunca
    /// viram gasto nem casam (§2.5, §2.10).
    var estornosEEncargos: [CompraConferencia] {
        compras.filter { $0.dia != nil && $0.compra.tipo != .compra }
    }

    /// "Fora desta viagem": o resto da fatura (o mês inteiro), recolhido.
    var foraDaViagem: [CompraConferencia] {
        compras.filter { $0.dia == nil }
    }

    private func ehFaltam(_ item: CompraConferencia) -> Bool {
        item.dia != nil && item.compra.tipo == .compra
            && (item.compra.match == nil || item.desvinculada)
    }

    func alternarMarcada(_ compraId: Int) {
        guard let i = compras.firstIndex(where: { $0.id == compraId }),
              ehFaltam(compras[i]) else { return }
        compras[i].marcada.toggle()
    }

    /// "Marcar todas" do "Faltam" (§2.5).
    func marcarTodas() {
        for i in compras.indices where ehFaltam(compras[i]) {
            compras[i].marcada = true
        }
    }

    func desmarcarTodas() {
        for i in compras.indices where ehFaltam(compras[i]) {
            compras[i].marcada = false
        }
    }

    /// "Confirmar" no match "Revisar".
    func confirmar(_ compraId: Int) {
        guard let i = compras.firstIndex(where: { $0.id == compraId }),
              compras[i].compra.match != nil, !compras[i].desvinculada else { return }
        compras[i].confirmada = true
    }

    /// "Desvincular": a compra desce para "Faltam" desmarcada; o vínculo sai
    /// do servidor no "Importar".
    func desvincular(_ compraId: Int) {
        guard let i = compras.firstIndex(where: { $0.id == compraId }),
              compras[i].compra.match != nil else { return }
        compras[i].desvinculada = true
        compras[i].confirmada = false
        compras[i].marcada = false
    }

    /// Desfaz o "Desvincular" (a compra volta para "Já lançadas").
    func revincular(_ compraId: Int) {
        guard let i = compras.firstIndex(where: { $0.id == compraId }) else { return }
        compras[i].desvinculada = false
    }

    // MARK: - Importar

    /// "Importar": só agora algo é gravado. O servidor grava a fatura e as
    /// compras mantidas primeiro; se falhar, nenhum gasto é criado (§2.1,
    /// §2.11). Depois os gastos marcados sobem pelo caminho normal
    /// (`createNewGasto`, `.pending`), o sync forçado manda tudo e a
    /// conciliação roda de novo para casar os gastos novos.
    func importar() async {
        guard etapa == .conferindo, let fatura else { return }
        etapa = .importando
        var envio = fatura
        // CSV/OFX podem não trazer vencimento: a data informada na
        // conferência vai no envio — sem ela o POST responderia 422.
        if envio.vencimento == nil {
            envio.vencimento = vencimentoInformado
        }
        // "As compras mantidas": tudo o que ficou na conferência dentro da
        // viagem — já lançadas, faltam (marcadas ou não), estornos e encargos.
        envio.compras = compras.filter { $0.dia != nil }.map(\.compra)
        gastosCriados = 0
        gastosFalharam = 0
        do {
            var detalhe = try await api.gravarFatura(envio)
            for item in compras where item.marcada && ehFaltam(item) {
                guard let dia = item.dia else { continue }
                do {
                    try await criarGasto(item.compra, dia)
                    gastosCriados += 1
                } catch {
                    gastosFalharam += 1
                    logger.error("Gasto da fatura não criado: \(error.localizedDescription, privacy: .public)")
                }
            }
            await sincronizar()
            if let conciliado = try? await api.conciliarFatura(faturaId: detalhe.id) {
                detalhe = conciliado
            }
            aplicarMatches(detalhe)
            await resolverVinculos(detalhe)
            try? contexto?.save()
            resumoImportacao = resumo()
            etapa = .pronto
        } catch {
            guard !Task.isCancelled else { return }
            etapa = .erro(mensagemDeErro(error))
        }
    }

    /// Selo do gasto no aparelho, com os vínculos que o servidor confirmou
    /// ("Aguardando fatura" → "Na fatura"/"Revisar").
    private func aplicarMatches(_ detalhe: CreditCardBillDetailResponse) {
        for transacao in detalhe.transacoes {
            guard let match = transacao.openFinanceMatch,
                  let gasto = gastoLocal(backendId: match.gastoId) else { continue }
            gasto.aplicarOpenFinanceStatus(match.status, match: match)
        }
    }

    /// "Desvincular" e "Confirmar" decididos na conferência, refeitos agora
    /// que os vínculos existem de verdade no servidor (o `match` da prévia
    /// não tem id; o vínculo é localizado pelo `gasto_id`).
    private func resolverVinculos(_ detalhe: CreditCardBillDetailResponse) async {
        for item in compras {
            guard let matchPrevia = item.compra.match,
                  let transacao = detalhe.transacoes.first(where: {
                      $0.openFinanceMatch?.gastoId == matchPrevia.gastoId
                  }),
                  let matchId = transacao.openFinanceMatch?.id else { continue }
            if item.desvinculada {
                if (try? await api.removerMatchFatura(matchId: matchId)) != nil,
                   let gasto = gastoLocal(backendId: matchPrevia.gastoId) {
                    gasto.limparOpenFinanceMatch()
                }
            } else if item.confirmada {
                if let match = try? await api.confirmarMatchFatura(matchId: matchId),
                   let gasto = gastoLocal(backendId: match.gastoId) {
                    gasto.aplicarOpenFinanceStatus(match.status, match: match)
                }
            }
        }
    }

    /// O match pode apontar para um gasto de outra viagem (a conciliação do
    /// servidor é do usuário inteiro): busca no banco, não só na viagem.
    private func gastoLocal(backendId: Int) -> GastosDia? {
        if let contexto {
            let desc = FetchDescriptor<GastosDia>(
                predicate: #Predicate { $0.backendId == backendId }
            )
            if let gasto = try? contexto.fetch(desc).first { return gasto }
        }
        return (ciclo.dias ?? []).flatMap(\.gastos).first { $0.backendId == backendId }
    }

    /// Gastos vivos da viagem ainda não enviados (podem aparecer como
    /// "faltam" na fatura). Contado depois do `sync(forcar:)` da leitura.
    private func gastosPendentes() -> Int {
        (ciclo.dias ?? []).flatMap(\.gastos).reduce(0) {
            $0 + ($1.deletadoEm == nil && $1.syncStatus != .synced ? 1 : 0)
        }
    }

    private func resumo() -> String {
        var partes: [String] = []
        if gastosCriados > 0 {
            partes.append("\(gastosCriados) \(gastosCriados == 1 ? "gasto criado" : "gastos criados")")
        } else if gastosFalharam == 0 {
            partes.append("nenhum gasto novo")
        }
        if gastosFalharam > 0 {
            partes.append("\(gastosFalharam) \(gastosFalharam == 1 ? "gasto não foi criado" : "gastos não foram criados")")
        }
        let vinculadas = jaLancadas.count
        if vinculadas > 0 {
            partes.append("\(vinculadas) \(vinculadas == 1 ? "compra já era lançada" : "compras já eram lançadas")")
        }
        return partes.joined(separator: " · ")
    }

    private func mensagemDeErro(_ error: Error) -> String {
        if case APIError.serverError(let message, _, let code) = error {
            if code == 503 {
                return "Leitura por IA indisponível no momento. Tente de novo mais tarde — OFX e CSV não passam pela IA e podem funcionar."
            }
            if code == 429 {
                return "Muitas leituras seguidas. Espere um minuto e tente de novo."
            }
            return message
        }
        return "Sem conexão com o servidor. Confira a internet e tente de novo."
    }

    /// Título do gasto criado: a descrição da fatura, formatada como o
    /// registro do Apple Pay faz com o estabelecimento, com a parcela no fim.
    static func tituloDoGasto(_ compra: CompraLida) -> String {
        var titulo = RegistroApplePay.tituloDoGasto(compra.descricao)
        if let parcela = compra.textoParcela {
            titulo = "\(titulo) (\(parcela))"
        }
        return titulo
    }
}

/// Quem vence a corrida do `sincronizarComTeto`: o primeiro `responder()`
/// devolve `true` e retoma a continuação; o segundo é no-op (uma
/// `CheckedContinuation` não pode ser retomada duas vezes).
private actor CorridaDoTeto {
    private var respondeu = false

    func responder() -> Bool {
        if respondeu { return false }
        respondeu = true
        return true
    }
}
