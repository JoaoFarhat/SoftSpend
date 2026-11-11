import Foundation
@testable import SoftSpend

/// Servidor falso para testar o `SyncActor` sem rede.
///
/// - Guarda ciclos, dias e gastos em memória, com ids sequenciais e
///   deduplicação por `client_id` (como o backend).
/// - `segurar(_:)` devolve um `Portao`: a chamada àquele endpoint fica parada
///   até `liberar()`. Dá para esperar a chamada chegar (`aguardarChegada()`),
///   mexer no banco local "durante" a requisição e só então liberar.
/// - `falhar(_:)` faz o endpoint lançar erro (depois do portão, se houver) até
///   `pararDeFalhar(_:)`.
///
/// Os métodos são `nonisolated` e rodam no executor de quem chama (o
/// `SyncActor`). O estado fica atrás de um lock, nunca segurado durante `await`.
nonisolated final class FakeSyncAPI: SyncAPI, @unchecked Sendable {

    nonisolated enum Endpoint: Hashable, Sendable {
        case postCiclo, putCiclo, deleteCiclo
        case postDiasLote, syncDiasLote, deleteDia
        case postGasto, putGasto, deleteGasto
        case uploadComprovante, deleteComprovante
    }

    nonisolated struct CicloRemoto: Sendable {
        let id: Int
        let clientId: String?
        var titulo: String
        var valorTotal: Decimal
        var diaria: Decimal
        var periodo: String
    }

    nonisolated struct DiaRemoto: Sendable {
        let id: Int
        let clientId: String?
        let cicloId: Int
        var data: Date
        var saldo: Decimal
    }

    nonisolated struct GastoRemoto: Sendable {
        let id: Int
        let clientId: String?
        var diaId: Int
        var titulo: String
        var valor: Decimal
        var categoria: Categoria
        var comprovanteUrl: String?
        /// Bytes do último comprovante recebido (nil depois do delete).
        var comprovante: Data? = nil
    }

    static let erroSimulado = APIError.serverError(message: "Falha simulada", requestId: "-", statusCode: 500)
    static let naoEncontrado = APIError.serverError(message: "Não encontrado", requestId: "-", statusCode: 404)

    private let lock = NSLock()
    private var _chamadas: [Endpoint] = []
    private var _ciclos: [CicloRemoto] = []
    private var _dias: [DiaRemoto] = []
    private var _gastos: [GastoRemoto] = []
    private var proximoId = 1
    private var portoes: [Endpoint: Portao] = [:]
    private var falhas: [Endpoint: any Error] = [:]
    private var respostasPerdidas: Set<Endpoint> = []

    /// Erro devolvido quando a resposta "se perde" (ver `perderResposta`).
    static let respostaPerdida = URLError(.timedOut)

    init() {}

    // MARK: Leitura do estado (para os testes)

    var chamadas: [Endpoint] { lock.withLock { _chamadas } }
    var ciclos: [CicloRemoto] { lock.withLock { _ciclos } }
    var dias: [DiaRemoto] { lock.withLock { _dias } }
    var gastos: [GastoRemoto] { lock.withLock { _gastos } }

    // MARK: Controle

    /// A próxima (e todas as seguintes) chamada a `endpoint` espera o portão abrir.
    @discardableResult
    func segurar(_ endpoint: Endpoint) -> Portao {
        let portao = Portao()
        lock.withLock { portoes[endpoint] = portao }
        return portao
    }

    func falhar(_ endpoint: Endpoint, com erro: any Error = FakeSyncAPI.erroSimulado) {
        lock.withLock { falhas[endpoint] = erro }
    }

    func pararDeFalhar(_ endpoint: Endpoint) {
        lock.withLock { _ = falhas.removeValue(forKey: endpoint) }
    }

    /// A próxima chamada a `endpoint` é **processada** (o item fica no servidor)
    /// e depois lança `respostaPerdida`, como um timeout com a requisição já
    /// atendida. Só vale uma vez. Suportado em `postCiclo`, `postDiasLote` e `postGasto`.
    func perderResposta(_ endpoint: Endpoint) {
        lock.withLock { _ = respostasPerdidas.insert(endpoint) }
    }

    /// Esquece as chamadas registradas, para o teste conferir só o que o sync
    /// sob avaliação fez (e não o que a montagem do cenário enviou).
    func limparChamadas() {
        lock.withLock { _chamadas.removeAll() }
    }

    // MARK: Infra

    /// Registra a chamada, espera o portão (se houver) e lança a falha (se houver).
    private func entrar(_ endpoint: Endpoint) async throws {
        let portao = lock.withLock { () -> Portao? in
            _chamadas.append(endpoint)
            return portoes[endpoint]
        }
        if let portao { await portao.esperar() }
        if let erro = lock.withLock({ falhas[endpoint] }) { throw erro }
    }

    /// Depois de processar: lança se a resposta desta chamada deve se perder.
    private func entregar<T>(_ resposta: T, _ endpoint: Endpoint) throws -> T {
        let perdeu = lock.withLock { respostasPerdidas.remove(endpoint) != nil }
        if perdeu { throw Self.respostaPerdida }
        return resposta
    }

    private func novoId() -> Int {
        defer { proximoId += 1 }
        return proximoId
    }

    private func respostaCiclo(_ c: CicloRemoto) -> CicloSoftex {
        let idsDias = Set(_dias.filter { $0.cicloId == c.id }.map(\.id))
        let gastoTotal = _gastos.filter { idsDias.contains($0.diaId) }.reduce(Decimal(0)) { $0 + $1.valor }
        return CicloSoftex(from: CicloResponse(
            id: c.id, clientId: c.clientId, valor_total: c.valorTotal, gasto_total: gastoTotal,
            periodo: c.periodo, diaria: c.diaria, titulo: c.titulo, dias: nil
        ))
    }

    private func respostaDia(_ d: DiaRemoto) -> DiaSoftex {
        DiaSoftex(from: DiaSoftexResponse(id: d.id, clientId: d.clientId, data: d.data, saldo: d.saldo, gastos: nil))
    }

    private func respostaGasto(_ g: GastoRemoto) -> GastosDia {
        GastosDia(from: GastosDiaResponse(
            id: g.id, clientId: g.clientId, dia_id: g.diaId, valor: g.valor, titulo: g.titulo,
            categoria: g.categoria, comprovante_url: g.comprovanteUrl, openFinanceStatus: nil, openFinanceMatch: nil
        ))
    }

    /// Cria o dia se não existir um com o mesmo `client_id` no ciclo. Chamar com o lock.
    private func criarOuAcharDia(_ pedido: DiaLoteRequest, ciclo: CicloRemoto) -> DiaRemoto {
        if let clientId = pedido.clientId,
           let existente = _dias.first(where: { $0.cicloId == ciclo.id && $0.clientId == clientId }) {
            return existente
        }
        let dia = DiaRemoto(id: novoId(), clientId: pedido.clientId, cicloId: ciclo.id, data: pedido.data, saldo: ciclo.diaria)
        _dias.append(dia)
        return dia
    }

    private func removerDias(_ ids: Set<Int>) {
        _gastos.removeAll { ids.contains($0.diaId) }
        _dias.removeAll { ids.contains($0.id) }
    }

    // MARK: SyncAPI — ciclos

    func postCiclo(request: CicloCreateRequest) async throws -> CicloSoftex {
        try await entrar(.postCiclo)
        let resposta: CicloSoftex = lock.withLock {
            if let clientId = request.client_id, let existente = _ciclos.first(where: { $0.clientId == clientId }) {
                return respostaCiclo(existente)
            }
            let ciclo = CicloRemoto(
                id: novoId(), clientId: request.client_id, titulo: request.titulo,
                valorTotal: request.valor_total, diaria: request.diaria, periodo: request.periodo
            )
            _ciclos.append(ciclo)
            return respostaCiclo(ciclo)
        }
        return try entregar(resposta, .postCiclo)
    }

    func putCiclo(cicloId: Int, request: CicloUpdateRequest) async throws -> CicloSoftex {
        try await entrar(.putCiclo)
        return try lock.withLock {
            guard let i = _ciclos.firstIndex(where: { $0.id == cicloId }) else { throw Self.naoEncontrado }
            _ciclos[i].titulo = request.titulo
            _ciclos[i].valorTotal = request.valor_total
            _ciclos[i].diaria = request.diaria
            _ciclos[i].periodo = request.periodo
            return respostaCiclo(_ciclos[i])
        }
    }

    func deleteCiclo(cicloId: Int) async throws {
        try await entrar(.deleteCiclo)
        try lock.withLock {
            guard _ciclos.contains(where: { $0.id == cicloId }) else { throw Self.naoEncontrado }
            removerDias(Set(_dias.filter { $0.cicloId == cicloId }.map(\.id)))
            _ciclos.removeAll { $0.id == cicloId }
        }
    }

    // MARK: SyncAPI — dias

    func postDiasLote(cicloId: Int, dias: [DiaLoteRequest]) async throws -> [DiaSoftex] {
        try await entrar(.postDiasLote)
        let resposta: [DiaSoftex] = try lock.withLock {
            guard let ciclo = _ciclos.first(where: { $0.id == cicloId }) else { throw Self.naoEncontrado }
            return dias.map { respostaDia(criarOuAcharDia($0, ciclo: ciclo)) }
        }
        return try entregar(resposta, .postDiasLote)
    }

    func syncDiasLote(cicloId: Int, dias: [DiaLoteRequest]) async throws -> [DiaSoftex] {
        try await entrar(.syncDiasLote)
        return try lock.withLock {
            guard let ciclo = _ciclos.first(where: { $0.id == cicloId }) else { throw Self.naoEncontrado }
            let mantidos = dias.map { criarOuAcharDia($0, ciclo: ciclo) }
            let idsMantidos = Set(mantidos.map(\.id))
            removerDias(Set(_dias.filter { $0.cicloId == cicloId && !idsMantidos.contains($0.id) }.map(\.id)))
            return mantidos.map { respostaDia($0) }
        }
    }

    func deleteDia(diaId: Int) async throws {
        try await entrar(.deleteDia)
        try lock.withLock {
            guard _dias.contains(where: { $0.id == diaId }) else { throw Self.naoEncontrado }
            removerDias([diaId])
        }
    }

    // MARK: SyncAPI — gastos

    func postGasto(request: GastoCreateRequest) async throws -> GastosDia {
        try await entrar(.postGasto)
        let resposta: GastosDia = try lock.withLock {
            guard _dias.contains(where: { $0.id == request.dia_id }) else { throw Self.naoEncontrado }
            if let clientId = request.client_id,
               let existente = _gastos.first(where: { $0.diaId == request.dia_id && $0.clientId == clientId }) {
                return respostaGasto(existente)
            }
            let gasto = GastoRemoto(
                id: novoId(), clientId: request.client_id, diaId: request.dia_id,
                titulo: request.titulo, valor: request.valor, categoria: request.categoria, comprovanteUrl: nil
            )
            _gastos.append(gasto)
            return respostaGasto(gasto)
        }
        return try entregar(resposta, .postGasto)
    }

    func putGasto(gastoId: Int, request: GastoUpdateRequest) async throws -> GastosDia {
        try await entrar(.putGasto)
        return try lock.withLock {
            guard let i = _gastos.firstIndex(where: { $0.id == gastoId }) else { throw Self.naoEncontrado }
            _gastos[i].titulo = request.titulo
            _gastos[i].valor = request.valor
            _gastos[i].categoria = request.categoria
            if let diaId = request.dia_id { _gastos[i].diaId = diaId }
            return respostaGasto(_gastos[i])
        }
    }

    func deleteGasto(gastoId: Int) async throws {
        try await entrar(.deleteGasto)
        try lock.withLock {
            guard _gastos.contains(where: { $0.id == gastoId }) else { throw Self.naoEncontrado }
            _gastos.removeAll { $0.id == gastoId }
        }
    }

    // MARK: SyncAPI — comprovantes

    func uploadComprovante(gastoId: Int, imageData: Data, mime: String) async throws -> GastosDia {
        try await entrar(.uploadComprovante)
        return try lock.withLock {
            guard let i = _gastos.firstIndex(where: { $0.id == gastoId }) else { throw Self.naoEncontrado }
            let extensao = mime == "application/pdf" ? "pdf" : "jpg"
            _gastos[i].comprovanteUrl = "https://fake.softspend/gastos/\(gastoId)/comprovante.\(extensao)"
            _gastos[i].comprovante = imageData
            return respostaGasto(_gastos[i])
        }
    }

    func deleteComprovante(gastoId: Int) async throws -> GastosDia {
        try await entrar(.deleteComprovante)
        return try lock.withLock {
            guard let i = _gastos.firstIndex(where: { $0.id == gastoId }) else { throw Self.naoEncontrado }
            _gastos[i].comprovanteUrl = nil
            _gastos[i].comprovante = nil
            return respostaGasto(_gastos[i])
        }
    }
}

/// Segura uma chamada da API falsa até o teste liberar.
actor Portao {
    private var chegou = false
    private var liberado = false
    private var desistiu = false
    private var esperandoChegada: [CheckedContinuation<Void, Never>] = []
    private var esperandoLiberacao: [CheckedContinuation<Void, Never>] = []

    /// Chamado pela API falsa: avisa que a requisição chegou e espera a liberação.
    func esperar() async {
        chegou = true
        esperandoChegada.forEach { $0.resume() }
        esperandoChegada.removeAll()
        guard !liberado else { return }
        await withCheckedContinuation { esperandoLiberacao.append($0) }
    }

    /// Chamado pelo teste: volta quando a requisição já está "no servidor".
    func aguardarChegada() async {
        guard !chegou, !desistiu else { return }
        await withCheckedContinuation { esperandoChegada.append($0) }
    }

    var jaChegou: Bool { chegou }

    /// Solta quem espera a chegada (agora e depois) mesmo sem ela acontecer.
    func desistirDaChegada() {
        desistiu = true
        esperandoChegada.forEach { $0.resume() }
        esperandoChegada.removeAll()
    }

    /// Espera a chamada chegar, ou o sync terminar sem ela (devolve `false`):
    /// um teste que falha não fica travado esperando uma chamada que não vem.
    func chegouAntes(doFimDe tarefa: Task<Int, Never>) async -> Bool {
        Task { [weak self] in
            _ = await tarefa.value
            await self?.desistirDaChegada()
        }
        await aguardarChegada()
        return chegou
    }

    /// Deixa passar a chamada parada e as próximas.
    func liberar() {
        liberado = true
        esperandoLiberacao.forEach { $0.resume() }
        esperandoLiberacao.removeAll()
    }
}
