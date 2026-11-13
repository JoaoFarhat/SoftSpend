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
nonisolated func ehFalhaTransitoriaDeRefresh(_ error: Error) -> Bool {
    if error is URLError { return true }
    if case APIError.serverError(_, _, let statusCode) = error {
        return statusCode >= 500
    }
    return false
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

private actor TokenRefresher {
    private var currentTask: Task<AuthResponse, Error>?

    func refresh() async throws -> AuthResponse {
        if let task = currentTask {
            return try await task.value
        }

        // Lido uma vez só: todas as tentativas reenviam este mesmo token.
        guard let refreshToken = KeychainManager.getRefreshToken() else {
            throw APIError.authentication
        }

        let task = Task {
            let response = try await repetindoSeTransitorio(esperas: esperasRefreshTransitorio) {
                try await NetworkManager.shared.refreshAccessToken(refreshToken: refreshToken)
            }
            KeychainManager.saveAccessToken(response.accessToken)
            KeychainManager.saveRefreshToken(response.refreshToken)
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

final class NetworkManager: Sendable {

    nonisolated static let shared = NetworkManager()
    nonisolated private let logger = Logger(subsystem: "br.com.softspend", category: "NetworkManager")
    private let refresher = TokenRefresher()

    private nonisolated let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        return URLSession(
            configuration: config,
            delegate: InsecureSessionDelegate(),
            delegateQueue: nil
        )
    }()

    /// Sessão dedicada a uploads de imagem (OCR/comprovantes).
    /// O timeout é maior para não abortar envios de notas fiscais.
    private nonisolated let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        return URLSession(
            configuration: config,
            delegate: InsecureSessionDelegate(),
            delegateQueue: nil
        )
    }()

    private nonisolated let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: value) {
                return date
            }

            isoFormatter.formatOptions = [.withInternetDateTime]
            if let date = isoFormatter.date(from: value) {
                return date
            }

            let utcFormatter = DateFormatter()
            utcFormatter.locale = Locale(identifier: "en_US_POSIX")
            utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            utcFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let date = utcFormatter.date(from: value) {
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

        if includeToken, let token = KeychainManager.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    @discardableResult
    nonisolated private func execute(
        _ request: URLRequest,
        logout401: Bool = true,
        session: URLSession,
        timeoutSeconds: UInt64,
        allowRefresh: Bool = true
    ) async throws -> Data {
        logger.info("execute: \(request.httpMethod ?? "?", privacy: .private) \(request.url?.absoluteString ?? "?", privacy: .private)")
        let start = Date()
        let requestTimeout: UInt64 = timeoutSeconds * 1_000_000_000

        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                var req = request
                req.timeoutInterval = TimeInterval(timeoutSeconds)
                return try await session.data(for: req)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: requestTimeout)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw APIError.unknown
            }
            group.cancelAll()
            return result
        }

        let duration = Date().timeIntervalSince(start)
        logger.info("execute: completed in \(duration, privacy: .public)s")

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        logger.info("execute: status \(http.statusCode, privacy: .public) for \(request.url?.absoluteString ?? "?", privacy: .private)")

        if http.statusCode == 401, logout401 {
            if allowRefresh {
                do {
                    let authResponse = try await refresher.refresh()
                    var retryRequest = request
                    retryRequest.setValue(
                        "Bearer \(authResponse.accessToken)",
                        forHTTPHeaderField: "Authorization"
                    )
                    return try await execute(
                        retryRequest,
                        logout401: true,
                        session: session,
                        timeoutSeconds: timeoutSeconds,
                        allowRefresh: false
                    )
                } catch {
                    // O refresh token tambem nao vale mais (401/403) ou a
                    // rede/servidor falhou nas 3 tentativas do refresher.
                    // Nao adianta chamar /auth/logout, e o token antigo nao
                    // e guardado: passados 60 s, reenvia-lo seria reuso.
                    Task { @MainActor in AuthService.shared.logout(revogandoNoServidor: false) }
                    throw APIError.authentication
                }
            } else {
                Task { @MainActor in AuthService.shared.logout(revogandoNoServidor: false) }
                throw APIError.authentication
            }
        }

        guard 200...299 ~= http.statusCode else {
            let decoded = try? decoder.decode(APIErrorResponse.self, from: data)
            let message = decoded?.error ?? "Erro no servidor"
            let requestId = decoded?.request_id ?? "-"
            throw APIError.serverError(message: message, requestId: requestId, statusCode: http.statusCode)
        }

        return data
    }

    @discardableResult
    nonisolated private func execute(_ request: URLRequest, logout401: Bool = true, allowRefresh: Bool = true) async throws -> Data {
        try await execute(request, logout401: logout401, session: session, timeoutSeconds: 8, allowRefresh: allowRefresh)
    }

    @discardableResult
    nonisolated private func executeUpload(_ request: URLRequest, logout401: Bool = true, allowRefresh: Bool = true) async throws -> Data {
        try await execute(request, logout401: logout401, session: uploadSession, timeoutSeconds: 90, allowRefresh: allowRefresh)
    }

    nonisolated func fetchCicloResumo(skip: Int = 0, limit: Int = 5) async throws -> [CicloSoftex] {
        guard var components = URLComponents(string: "\(APIConfig.shared.baseURL)/usuario/ciclos/resumo") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
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

    nonisolated func syncDiasLote(cicloId: Int, dias: [DiaLoteRequest]) async throws -> [DiaSoftex] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)/dias/lote") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "PUT", body: try encoder.encode(dias))
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

    nonisolated private func makeImageUploadRequest(
        url: URL,
        imageData: Data,
        mime: String = "image/jpeg"
    ) -> URLRequest {
        // O backend valida os magic bytes, então o Content-Type da parte precisa
        // corresponder ao conteúdo real (JPEG ou PDF).
        let nomeArquivo = mime == "application/pdf" ? "comprovante.pdf" : "comprovante.jpg"
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"imagem\"; filename=\"\(nomeArquivo)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = makeRequest(url: url, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        request.timeoutInterval = 90
        return request
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
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func campo(_ nome: String, _ valor: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(nome)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(valor)\r\n".data(using: .utf8)!)
        }
        if let senha, !senha.isEmpty { campo("senha", senha) }
        if let cicloId { campo("ciclo_id", String(cicloId)) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"arquivo\"; filename=\"\(nomeArquivo)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(arquivo)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = makeRequest(url: url, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        request.timeoutInterval = 90
        return request
    }

    /// Só leitura (o servidor não grava nada). A IA pode demorar: sobe pela
    /// `uploadSession`, com timeout de 90 s (§2.5).
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
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
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
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
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
        try await execute(makeRequest(url: url, method: "DELETE"))
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
