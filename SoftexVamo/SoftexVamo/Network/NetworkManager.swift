//
//  NetworkManager.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 26/03/26.
//

import Foundation
import Combine
import os

/// Esperas entre as tentativas de `/auth/refresh` quando a falha é transitória:
/// 1 s antes da 2ª tentativa e 3 s antes da 3ª (3 tentativas no total).
/// Tudo cabe com folga na janela de 60 s em que o servidor aceita a réplica
/// do mesmo refresh token (ver `docs/refresh-token-janela-tolerancia.md`).
nonisolated let esperasRefreshTransitorio: [Duration] = [.seconds(1), .seconds(3)]

/// Falha que vale repetir o refresh: rede (timeout, sem conexão) ou 5xx.
/// 401/403 e qualquer outro erro significam que o token não vale mais.
/// `URLError(.cancelled)` não repete: quem cancelou não quer nova tentativa.
nonisolated func ehFalhaTransitoriaDeRefresh(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        return urlError.code != .cancelled
    }
    if case APIError.serverError(_, _, let statusCode) = error {
        return statusCode >= 500
    }
    return false
}

/// Falha do refresh que derruba a sessão. O `429` não desloga: o limitador
/// do `/auth/refresh` recusa antes de a rota trocar o token, então o mesmo
/// refresh token continua valendo e pode ser reenviado depois sem virar
/// reuso — quem chamou recebe o próprio 429 (o `SyncActor` o trata como
/// limite por minuto). Cancelamento (`CancellationError`, `URLError(.cancelled)`)
/// também não desloga: a pessoa cancelou a operação, o login não ficou
/// inválido. Qualquer outro erro desloga como antes.
nonisolated func deveDeslogarAposFalhaDeRefresh(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let urlError = error as? URLError, urlError.code == .cancelled { return false }
    if case APIError.serverError(_, _, let statusCode) = error {
        return statusCode != 429
    }
    return true
}

/// Executa `operacao` e, se falhar de forma transitória, repete após cada
/// espera de `esperas` (no máximo `esperas.count` repetições). Erro não
/// transitório ou o erro da última tentativa é propagado.
///
/// A operação deve reenviar sempre o MESMO refresh token: guardar o token
/// para tentar mais tarde não é seguro, porque depois de 60 s a réplica vira
/// reuso e o servidor derruba todas as sessões do usuário.
nonisolated func repetindoSeTransitorio<T: Sendable>(
    esperas: [Duration],
    ehTransitorio: @Sendable (Error) -> Bool = ehFalhaTransitoriaDeRefresh,
    dormir: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operacao: @Sendable () async throws -> T
) async throws -> T {
    var esperasRestantes = esperas[...]
    while true {
        do {
            return try await operacao()
        } catch {
            guard ehTransitorio(error), let espera = esperasRestantes.popFirst() else {
                throw error
            }
            try await dormir(espera)
        }
    }
}

/// Renova o token e reenvia o pedido com o token novo — o reenvio fica FORA
/// do `catch` do refresh: falha dele (timeout, sem rede, 404, 422, 500,
/// cancelamento) sobe intacta sem deslogar, porque o login renovado
/// continua válido.
///
/// Falha do refresh, sim, pode derrubar a sessão: o refresh token não vale
/// mais (401/403) ou a rede/servidor falhou nas 3 tentativas do refresher.
/// Não adianta chamar `/auth/logout`, e o token antigo não é guardado:
/// passados 60 s, reenviá-lo seria reuso. `deveDeslogarAposFalhaDeRefresh`
/// guarda as exceções (429 do limitador, cancelamento): o erro sobe intacto
/// para quem chamou, sem logout e sem apagar os tokens.
nonisolated func renovandoEReenviando<T: Sendable>(
    renovar: @Sendable () async throws -> String,
    reenviar: @Sendable (String) async throws -> T,
    deslogar: @Sendable () -> Void
) async throws -> T {
    let token: String
    do {
        token = try await renovar()
    } catch {
        guard deveDeslogarAposFalhaDeRefresh(error) else {
            throw error
        }
        deslogar()
        throw APIError.authentication
    }
    return try await reenviar(token)
}

/// Onde o `NetworkManager` lê e grava os tokens da sessão. Existe para o
/// `execute` poder ser testado sem mexer no Keychain: em produção a
/// implementação é o `CofreDeTokensKeychain` (delega para o
/// `KeychainManager`); nos testes, um cofre em memória.
nonisolated protocol CofreDeTokens: Sendable {
    func lerAccessToken() -> String?
    func lerRefreshToken() -> String?
    func gravarAccessToken(_ token: String)
    func gravarRefreshToken(_ token: String)
    func apagarTokens()
}

/// `CofreDeTokens` padrão do app: cada chamada delega para o
/// `KeychainManager`, que continua lendo/gravando no mesmo lugar de antes.
nonisolated struct CofreDeTokensKeychain: CofreDeTokens {
    init() {}

    func lerAccessToken() -> String? { KeychainManager.getAccessToken() }
    func lerRefreshToken() -> String? { KeychainManager.getRefreshToken() }
    func gravarAccessToken(_ token: String) { KeychainManager.saveAccessToken(token) }
    func gravarRefreshToken(_ token: String) { KeychainManager.saveRefreshToken(token) }
    func apagarTokens() { KeychainManager.deleteAllTokens() }
}

private actor TokenRefresher {
    private var currentTask: Task<AuthResponse, Error>?
    private let cofre: any CofreDeTokens

    init(cofre: any CofreDeTokens) {
        self.cofre = cofre
    }

    /// `manager` é o `NetworkManager` dono do refresher — injetado na chamada
    /// (e não no `init`) porque o refresher é criado junto com o manager,
    /// quando ainda não existe `self` para passar. Antes o refresh ia sempre
    /// pelo `NetworkManager.shared`, o que impedia testar o fluxo.
    func refresh(atravesDe manager: NetworkManager) async throws -> AuthResponse {
        if let task = currentTask {
            return try await task.value
        }

        // Lido uma vez só: todas as tentativas reenviam este mesmo token.
        guard let refreshToken = cofre.lerRefreshToken() else {
            throw APIError.authentication
        }

        let task = Task {
            let response = try await repetindoSeTransitorio(esperas: esperasRefreshTransitorio) {
                try await manager.refreshAccessToken(refreshToken: refreshToken)
            }
            cofre.gravarAccessToken(response.accessToken)
            cofre.gravarRefreshToken(response.refreshToken)
            return response
        }

        currentTask = task

        do {
            let response = try await task.value
            currentTask = nil
            return response
        } catch {
            currentTask = nil
            throw error
        }
    }
}

/// Só o `401` (sessão vencida) renova o token e, se não der, desloga. Qualquer
/// outro status, inclusive o `403 subscription_required` da assinatura
/// (`docs/assinatura.md` §3.1), volta como `APIError.serverError` sem mexer
/// na sessão.
nonisolated func deveRenovarToken(statusCode: Int, logout401: Bool) -> Bool {
    statusCode == 401 && logout401
}

final class NetworkManager: Sendable {

    nonisolated static let shared = NetworkManager()
    nonisolated private let logger = Logger(subsystem: "br.com.softspend", category: "NetworkManager")
    private nonisolated let refresher: TokenRefresher
    private nonisolated let session: URLSession

    /// Sessão dedicada a uploads de imagem (OCR/comprovantes) e a chamadas
    /// que podem demorar no servidor (o `DELETE /auth/conta`, por exemplo).
    /// O timeout é maior para não abortar envios de notas fiscais.
    private nonisolated let uploadSession: URLSession

    /// Onde os tokens da sessão são lidos e gravados (Keychain no app,
    /// cofre em memória nos testes).
    private nonisolated let tokens: any CofreDeTokens

    /// O que rodar quando a sessão morre de vez — no app, o logout sem
    /// revogar no servidor; nos testes, uma closure que só conta a chamada.
    private nonisolated let aoDeslogar: @Sendable () -> Void

    /// Configuração das duas sessões do app: sem `waitsForConnectivity` e
    /// com o `InsecureSessionDelegate` (que só confia no certificado do
    /// `.local` em DEBUG). Nos testes as sessões são substituídas por uma
    /// `URLSession` de `URLProtocol` falso.
    nonisolated static func sessaoPadrao(
        timeoutRequisicao: TimeInterval,
        timeoutRecurso: TimeInterval
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeoutRequisicao
        config.timeoutIntervalForResource = timeoutRecurso
        return URLSession(
            configuration: config,
            delegate: InsecureSessionDelegate(),
            delegateQueue: nil
        )
    }

    nonisolated init(
        session: URLSession = NetworkManager.sessaoPadrao(timeoutRequisicao: 8, timeoutRecurso: 8),
        uploadSession: URLSession = NetworkManager.sessaoPadrao(timeoutRequisicao: 90, timeoutRecurso: 300),
        tokens: any CofreDeTokens = CofreDeTokensKeychain(),
        aoDeslogar: @escaping @Sendable () -> Void = {
            Task { @MainActor in AuthService.shared.logout(revogandoNoServidor: false) }
        }
    ) {
        self.session = session
        self.uploadSession = uploadSession
        self.tokens = tokens
        self.aoDeslogar = aoDeslogar
        self.refresher = TokenRefresher(cofre: tokens)
    }

    /// Formatadores de data criados uma vez só: antes um
    /// `ISO8601DateFormatter`/`DateFormatter` novo era montado para CADA data
    /// decodificada — uma lista de 100 dias com gastos criava centenas.
    /// Compartilhar é seguro: `ISO8601DateFormatter` é thread-safe e
    /// `DateFormatter` é thread-safe (iOS 7+/macOS 10.9+, 64 bits) desde que
    /// a configuração não mude depois de criado — e aqui nunca muda.
    nonisolated private static let isoComFracao: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static let isoSemFracao: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated private static let utcSemFuso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private nonisolated let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = NetworkManager.isoComFracao.date(from: value) {
                return date
            }

            if let date = NetworkManager.isoSemFracao.date(from: value) {
                return date
            }

            if let date = NetworkManager.utcSemFuso.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Data inválida: \(value)"
            )
        }
        return d
    }()

    private nonisolated let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated private func makeRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        contentType: String = "application/json",
        includeToken: Bool = true
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if includeToken, let token = tokens.lerAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    @discardableResult
    nonisolated private func execute(
        _ request: URLRequest,
        logout401: Bool = true,
        session: URLSession,
        allowRefresh: Bool = true,
        mensagem422: @Sendable ([String]?) -> String? = CampoRecusado.mensagem
    ) async throws -> Data {
        logger.info("execute: \(request.httpMethod ?? "?", privacy: .private) \(request.url?.absoluteString ?? "?", privacy: .private)")
        let start = Date()

        // Sem corrida contra Task.sleep: o teto total do pedido já é o
        // `timeoutIntervalForResource` da sessão (8 s na comum, 300 s na de
        // upload). O teto extra de 90 s cortava relatórios e envios longos.
        let (data, response) = try await session.data(for: request)

        let duration = Date().timeIntervalSince(start)
        logger.info("execute: completed in \(duration, privacy: .public)s")

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        logger.info("execute: status \(http.statusCode, privacy: .public) for \(request.url?.absoluteString ?? "?", privacy: .private)")

        if deveRenovarToken(statusCode: http.statusCode, logout401: logout401) {
            if allowRefresh {
                // O reenvio com o token novo roda fora do catch do refresh:
                // falha dele não é falha de login e não desloga.
                return try await renovandoEReenviando(
                    renovar: { [self] in
                        try await refresher.refresh(atravesDe: self).accessToken
                    },
                    reenviar: { [self] token in
                        var retryRequest = request
                        retryRequest.setValue(
                            "Bearer \(token)",
                            forHTTPHeaderField: "Authorization"
                        )
                        return try await execute(
                            retryRequest,
                            logout401: true,
                            session: session,
                            allowRefresh: false,
                            mensagem422: mensagem422
                        )
                    },
                    deslogar: aoDeslogar
                )
            } else {
                aoDeslogar()
                throw APIError.authentication
            }
        }

        guard 200...299 ~= http.statusCode else {
            let decoded = try? decoder.decode(APIErrorResponse.self, from: data)
            // O 422 de validação traz `campos` com o que o servidor recusou:
            // a frase gravada no item diz o que editar em vez do genérico
            // "Dados de entrada invalidos". Sem `campos` nada muda — o
            // `total_da_viagem_acima_do_limite` (#166), que não traz a chave,
            // segue com a frase própria do `errorDescription`.
            let message = (http.statusCode == 422 ? mensagem422(decoded?.campos) : nil)
                ?? decoded?.error
                ?? "Erro no servidor"
            let requestId = decoded?.request_id ?? "-"
            throw APIError.serverError(message: message, requestId: requestId, statusCode: http.statusCode)
        }

        return data
    }

    @discardableResult
    nonisolated private func execute(
        _ request: URLRequest,
        logout401: Bool = true,
        allowRefresh: Bool = true,
        mensagem422: @Sendable ([String]?) -> String? = CampoRecusado.mensagem
    ) async throws -> Data {
        try await execute(request, logout401: logout401, session: session, allowRefresh: allowRefresh, mensagem422: mensagem422)
    }

    @discardableResult
    nonisolated private func executeUpload(
        _ request: URLRequest,
        logout401: Bool = true,
        allowRefresh: Bool = true,
        mensagem422: @Sendable ([String]?) -> String? = CampoRecusado.mensagem
    ) async throws -> Data {
        try await execute(request, logout401: logout401, session: uploadSession, allowRefresh: allowRefresh, mensagem422: mensagem422)
    }

    nonisolated func fetchCicloResumo(antesDe: Int? = nil, skip: Int = 0, limit: Int = 5) async throws -> [CicloSoftex] {
        guard var components = URLComponents(string: "\(APIConfig.shared.baseURL)/usuario/ciclos/resumo") else {
            throw URLError(.badURL)
        }
        var queryItems = [
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let antesDe {
            queryItems.append(URLQueryItem(name: "antes_de", value: String(antesDe)))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let response = try decoder.decode([CicloResponse].self, from: try await execute(makeRequest(url: url)))
        return response.map { CicloSoftex(from: $0) }
    }

    nonisolated func fetchCicloById(cicloId: Int) async throws -> CicloSoftex {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)") else {
            throw URLError(.badURL)
        }
        let response = try decoder.decode(CicloResponse.self, from: try await execute(makeRequest(url: url)))
        return CicloSoftex(from: response)
    }

    nonisolated func fetchDias(cicloId: Int, skip: Int = 0, limit: Int = 20) async throws -> [DiaSoftex] {
        guard var components = URLComponents(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)/dias") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let response = try decoder.decode([DiaSoftexResponse].self, from: try await execute(makeRequest(url: url)))
        return response.map { DiaSoftex(from: $0) }
    }

    nonisolated func postCiclo(request: CicloCreateRequest) async throws -> CicloSoftex {
        logger.info("postCiclo: client_id=\(request.client_id ?? "nil", privacy: .private) titulo=\(request.titulo, privacy: .private)")
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos") else {
            throw URLError(.badURL)
        }
        let req = makeRequest(url: url, method: "POST", body: try encoder.encode(request))
        let response = try decoder.decode(CicloResponse.self, from: try await execute(req))
        return CicloSoftex(from: response)
    }

    nonisolated func putCiclo(cicloId: Int, request: CicloUpdateRequest) async throws -> CicloSoftex {
        logger.info("putCiclo: cicloId=\(cicloId, privacy: .public) titulo=\(request.titulo, privacy: .private)")
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)") else {
            throw URLError(.badURL)
        }
        let req = makeRequest(url: url, method: "PUT", body: try encoder.encode(request))
        let response = try decoder.decode(CicloResponse.self, from: try await execute(req))
        return CicloSoftex(from: response)
    }

    nonisolated func deleteCiclo(cicloId: Int) async throws {
        logger.info("deleteCiclo: cicloId=\(cicloId, privacy: .public)")
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)") else {
            throw URLError(.badURL)
        }

        try await execute(makeRequest(url: url, method: "DELETE"))
    }

    nonisolated func postDiasLote(cicloId: Int, dias: [DiaLoteRequest]) async throws -> [DiaSoftex] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)/dias/lote") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(dias))
        let response = try decoder.decode([DiaSoftexResponse].self, from: try await execute(request))
        return response.map { DiaSoftex(from: $0) }
    }

    nonisolated func deleteDia(diaId: Int) async throws {
        logger.info("deleteDia: diaId=\(diaId, privacy: .public)")
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/dias/\(diaId)") else {
            throw URLError(.badURL)
        }
        try await execute(makeRequest(url: url, method: "DELETE"))
    }

    nonisolated func postGasto(request: GastoCreateRequest) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/dias/\(request.dia_id)/gastos") else {
            throw URLError(.badURL)
        }
        let req = makeRequest(url: url, method: "POST", body: try encoder.encode(request))
        let response = try decoder.decode(GastosDiaResponse.self, from: try await execute(req))
        return GastosDia(from: response)
    }

    nonisolated func putGasto(gastoId: Int, request: GastoUpdateRequest) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)") else {
            throw URLError(.badURL)
        }
        let req = makeRequest(url: url, method: "PUT", body: try encoder.encode(request))
        let response = try decoder.decode(GastosDiaResponse.self, from: try await execute(req))
        return GastosDia(from: response)
    }

    nonisolated func deleteGasto(gastoId: Int) async throws {
        logger.info("deleteGasto: gastoId=\(gastoId, privacy: .public)")
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)") else {
            throw URLError(.badURL)
        }
        try await execute(makeRequest(url: url, method: "DELETE"))
    }

    /// Monta um `multipart/form-data` com campos de texto opcionais e um
    /// arquivo. O `filename="..."` vai sem `"`, `\r` e `\n`: um nome escolhido
    /// pela pessoa (`fatura "nov".pdf`) quebraria o cabeçalho da parte e o
    /// servidor leria outro nome ou recusaria o arquivo.
    nonisolated private func makeMultipartUploadRequest(
        url: URL,
        campoArquivo: String,
        arquivo: Data,
        nomeArquivo: String,
        mime: String,
        campos: [(String, String)] = []
    ) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (nome, valor) in campos {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(nome)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(valor)\r\n".data(using: .utf8)!)
        }
        let nomeSeguro = nomeArquivo.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(campoArquivo)\"; filename=\"\(nomeSeguro)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(arquivo)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        return makeRequest(url: url, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    nonisolated private func makeImageUploadRequest(
        url: URL,
        imageData: Data,
        mime: String = "image/jpeg"
    ) -> URLRequest {
        // O backend valida os magic bytes, então o Content-Type da parte precisa
        // corresponder ao conteúdo real (JPEG ou PDF).
        let nomeArquivo = mime == "application/pdf" ? "comprovante.pdf" : "comprovante.jpg"
        return makeMultipartUploadRequest(
            url: url,
            campoArquivo: "imagem",
            arquivo: imageData,
            nomeArquivo: nomeArquivo,
            mime: mime
        )
    }

    nonisolated func extrairGastoDeImagem(imageData: Data) async throws -> GastoExtraidoResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/extrair") else {
            throw URLError(.badURL)
        }

        let request = makeImageUploadRequest(url: url, imageData: imageData)

        return try decoder.decode(GastoExtraidoResponse.self, from: try await executeUpload(request))
    }

    nonisolated func uploadComprovante(
        gastoId: Int,
        imageData: Data,
        mime: String = "image/jpeg"
    ) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)/comprovante") else {
            throw URLError(.badURL)
        }

        let request = makeImageUploadRequest(url: url, imageData: imageData, mime: mime)

        let response = try decoder.decode(GastosDiaResponse.self, from: try await executeUpload(request))
        return GastosDia(from: response)
    }

    /// Baixa o relatório de gastos de um ciclo.
    nonisolated func exportarCiclo(
        cicloId: Int,
        formato: ExportFormato,
        comprovantes: ExportComprovantes = .imagem
    ) async throws -> Data {
        guard var components = URLComponents(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)/export") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "formato", value: formato.rawValue),
            URLQueryItem(name: "comprovantes", value: comprovantes.rawValue)
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        return try await executeUpload(makeRequest(url: url))
    }

    nonisolated func deleteComprovante(gastoId: Int) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)/comprovante") else {
            throw URLError(.badURL)
        }

        let response = try decoder.decode(GastosDiaResponse.self, from: try await execute(makeRequest(url: url, method: "DELETE")))
        return response.toGastosDia()
    }

    nonisolated func fetchFeatures() async throws -> FeaturesResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/features") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(FeaturesResponse.self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func fetchOpenFinanceConnections() async throws -> [OpenFinanceConnectionResponse] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/connections") else {
            throw URLError(.badURL)
        }
        return try decoder.decode([OpenFinanceConnectionResponse].self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func sincronizarOpenFinanceItem(itemId: String) async throws -> ImportacaoOpenFinanceResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/items/\(itemId)/sync") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(
            ImportacaoOpenFinanceResponse.self,
            from: try await executeUpload(makeRequest(url: url, method: "POST"))
        )
    }

    nonisolated func fetchOpenFinanceCards() async throws -> [CreditCardAccountResponse] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/cards") else {
            throw URLError(.badURL)
        }
        return try decoder.decode([CreditCardAccountResponse].self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func fetchOpenFinanceBills(cartaoId: Int) async throws -> [CreditCardBillResponse] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/cards/\(cartaoId)/bills") else {
            throw URLError(.badURL)
        }
        return try decoder.decode([CreditCardBillResponse].self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func fetchOpenFinanceBill(faturaId: Int) async throws -> CreditCardBillDetailResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/bills/\(faturaId)") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(CreditCardBillDetailResponse.self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func fetchOpenFinanceTransactions(cartaoId: Int) async throws -> [CreditCardTransactionResponse] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/cards/\(cartaoId)/transactions") else {
            throw URLError(.badURL)
        }
        return try decoder.decode([CreditCardTransactionResponse].self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func fetchOpenFinanceMatches() async throws -> [ExpenseTransactionMatchResponse] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/matches") else {
            throw URLError(.badURL)
        }
        return try decoder.decode([ExpenseTransactionMatchResponse].self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func confirmarOpenFinanceMatch(matchId: Int) async throws -> ExpenseTransactionMatchResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/matches/\(matchId)/confirm") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(
            ExpenseTransactionMatchResponse.self,
            from: try await execute(makeRequest(url: url, method: "POST"))
        )
    }

    nonisolated func removerOpenFinanceMatch(matchId: Int) async throws -> ExpenseTransactionMatchResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/open-finance/matches/\(matchId)") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(
            ExpenseTransactionMatchResponse.self,
            from: try await execute(makeRequest(url: url, method: "DELETE"))
        )
    }

    // MARK: - Fatura importada por arquivo (§2)

    /// Multipart da `POST /api/faturas/ler`: `arquivo` + os campos de texto
    /// `senha?` e `ciclo_id?`. A senha do PDF só vive nesta requisição.
    nonisolated private func makeFaturaUploadRequest(
        url: URL,
        arquivo: Data,
        nomeArquivo: String,
        mime: String,
        senha: String?,
        cicloId: Int?
    ) -> URLRequest {
        var campos: [(String, String)] = []
        if let senha, !senha.isEmpty { campos.append(("senha", senha)) }
        if let cicloId { campos.append(("ciclo_id", String(cicloId))) }
        return makeMultipartUploadRequest(
            url: url,
            campoArquivo: "arquivo",
            arquivo: arquivo,
            nomeArquivo: nomeArquivo,
            mime: mime,
            campos: campos
        )
    }

    /// Só leitura (o servidor não grava nada). A IA pode demorar: sobe pela
    /// `uploadSession`, com teto de 300 s no total (§2.5).
    nonisolated func lerFatura(
        arquivo: Data,
        nomeArquivo: String,
        tipo: ArquivoFatura.Tipo,
        senha: String?,
        cicloId: Int?
    ) async throws -> FaturaLida {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/faturas/ler") else {
            throw URLError(.badURL)
        }
        let request = makeFaturaUploadRequest(
            url: url, arquivo: arquivo, nomeArquivo: nomeArquivo,
            mime: tipo.mime, senha: senha, cicloId: cicloId
        )
        return try decoder.decode(FaturaLida.self, from: try await executeUpload(request))
    }

    /// Grava a fatura e as compras mantidas na conferência (idempotente no
    /// servidor) e roda a conciliação. Devolve a fatura com as transações e
    /// os vínculos já com id.
    nonisolated func gravarFatura(_ lida: FaturaLida) async throws -> CreditCardBillDetailResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/faturas") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(lida))
        return try decoder.decode(CreditCardBillDetailResponse.self, from: try await executeUpload(request))
    }

    /// Concilia de novo depois que os gastos criados na conferência subiram.
    nonisolated func conciliarFatura(faturaId: Int) async throws -> CreditCardBillDetailResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/faturas/\(faturaId)/conciliar") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(
            CreditCardBillDetailResponse.self,
            from: try await execute(makeRequest(url: url, method: "POST"))
        )
    }

    nonisolated func confirmarMatchFatura(matchId: Int) async throws -> ExpenseTransactionMatchResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/faturas/matches/\(matchId)/confirm") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(
            ExpenseTransactionMatchResponse.self,
            from: try await execute(makeRequest(url: url, method: "POST"))
        )
    }

    nonisolated func removerMatchFatura(matchId: Int) async throws -> ExpenseTransactionMatchResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/faturas/matches/\(matchId)") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(
            ExpenseTransactionMatchResponse.self,
            from: try await execute(makeRequest(url: url, method: "DELETE"))
        )
    }

    // MARK: - Assinatura (docs/assinatura.md §2.3)

    nonisolated func obterAssinatura() async throws -> AssinaturaResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/assinatura") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(AssinaturaResponse.self, from: try await execute(makeRequest(url: url)))
    }

    nonisolated func enviarTransacaoAssinatura(jws: String) async throws -> AssinaturaResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/assinatura/transacoes") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(
            url: url,
            method: "POST",
            body: try encoder.encode(TransacaoAssinaturaRequest(jws: jws))
        )
        // O servidor verifica o JWS e pode consultar a Apple: 8 s é pouco.
        return try decoder.decode(AssinaturaResponse.self, from: try await executeUpload(request))
    }

    nonisolated func login(dados: LoginRequest) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/login") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(
            url: url,
            method: "POST",
            body: try encoder.encode(dados),
            includeToken: false
        )
        return try decoder.decode(
            AuthResponse.self,
            from: try await execute(request, logout401: false, mensagem422: CampoRecusado.mensagemConta)
        )
    }

    nonisolated func register(dados: RegisterRequest) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/register") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(
            url: url,
            method: "POST",
            body: try encoder.encode(dados),
            includeToken: false
        )
        return try decoder.decode(
            AuthResponse.self,
            from: try await execute(request, logout401: false, mensagem422: CampoRecusado.mensagemConta)
        )
    }

    nonisolated func refreshAccessToken(refreshToken: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/refresh") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(
            url: url,
            method: "POST",
            body: try encoder.encode(RefreshTokenRequest(refreshToken: refreshToken)),
            includeToken: false
        )
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
    }

    nonisolated func logout(refreshToken: String) async throws {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/logout") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(
            url: url,
            method: "POST",
            body: try encoder.encode(LogoutRequest(refreshToken: refreshToken)),
            includeToken: false
        )
        try await execute(request, logout401: false)
    }

    nonisolated func deleteAccount() async throws {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/conta") else {
            throw URLError(.badURL)
        }
        // Apagar a conta demora no servidor (apaga viagens, dias, gastos e
        // comprovantes em cascata): vai pela sessão de 90 s. Com os 8 s de
        // antes o app estourava com o servidor ainda apagando, mostrava erro
        // e a limpeza local (`apagarDadosLocais`, exigência da Apple) não
        // rodava.
        try await executeUpload(makeRequest(url: url, method: "DELETE"))
    }
}

final class InsecureSessionDelegate: NSObject, URLSessionDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if DEBUG
        if APIConfig.shared.current == .local,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
        #else
        completionHandler(.performDefaultHandling, nil)
        #endif
    }
}
