//
//  NetworkManager.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 26/03/26.
//

import Foundation
import Combine

final class NetworkManager: Sendable {

    nonisolated static let shared = NetworkManager()

    private nonisolated let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(
            configuration: config,
            delegate: InsecureSessionDelegate(),
            delegateQueue: nil
        )
    }()
    
    private nonisolated let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
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
        contentType: String = "application/json"
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        
        if let token = KeychainManager.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        return request
    }
    
    @discardableResult
    nonisolated private func execute(_ request: URLRequest, logout401: Bool = true) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        if http.statusCode == 401, logout401 {
            Task { @MainActor in
                AuthService.shared.logout()
            }
            throw APIError.authentication
        }

        guard 200...299 ~= http.statusCode else {
            let decoded = try? decoder.decode(APIErrorResponse.self, from: data)
            let message = decoded?.error ?? "Erro no servidor"
            let requestId = decoded?.request_id ?? "-"
            throw APIError.serverError(message: message, requestId: requestId, statusCode: http.statusCode)
        }

        return data
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
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos") else {
            throw URLError(.badURL)
        }
        let req = makeRequest(url: url, method: "POST", body: try encoder.encode(request))
        let response = try decoder.decode(CicloResponse.self, from: try await execute(req))
        return CicloSoftex(from: response)
    }
    
    nonisolated func putCiclo(cicloId: Int, request: CicloUpdateRequest) async throws -> CicloSoftex {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)") else {
            throw URLError(.badURL)
        }
        let req = makeRequest(url: url, method: "PUT", body: try encoder.encode(request))
        let response = try decoder.decode(CicloResponse.self, from: try await execute(req))
        return CicloSoftex(from: response)
    }
    
    nonisolated func deleteCiclo(cicloId: Int) async throws {
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
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)") else {
            throw URLError(.badURL)
        }
        try await execute(makeRequest(url: url, method: "DELETE"))
    }
    
    nonisolated private func makeImageUploadRequest(url: URL, imageData: Data) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"imagem\"; filename=\"comprovante.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
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
        
        return try decoder.decode(GastoExtraidoResponse.self, from: try await execute(request))
    }
    
    nonisolated func uploadComprovante(gastoId: Int, imageData: Data) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)/comprovante") else {
            throw URLError(.badURL)
        }
        
        let request = makeImageUploadRequest(url: url, imageData: imageData)
        
        let response = try decoder.decode(GastosDiaResponse.self, from: try await execute(request))
        return GastosDia(from: response)
    }
    
    nonisolated func deleteComprovante(gastoId: Int) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)/comprovante") else {
            throw URLError(.badURL)
        }
        
        let response = try decoder.decode(GastosDiaResponse.self, from: try await execute(makeRequest(url: url, method: "DELETE")))
        return response.toGastosDia()
    }
    
    nonisolated func login(dados: LoginRequest) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/login") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(dados))
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
    }

    nonisolated func register(dados: RegisterRequest) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/register") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(dados))
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
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

