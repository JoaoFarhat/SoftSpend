//
//  NetworkManager.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 26/03/26.
//

import Foundation
import Combine

final class NetworkManager {
    
    static let shared = NetworkManager()
    
    private let session = URLSession(
        configuration: .default,
        delegate: InsecureSessionDelegate(),
        delegateQueue: nil
    )
    
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    
    private func makeRequest(
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
    private func execute(_ request: URLRequest, logout401: Bool = true) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if http.statusCode == 401 {
            if logout401 {
                Task { @MainActor in
                    AuthService.shared.logout()
                }
                throw URLError(.userAuthenticationRequired)
            }
        }
        
        guard 200...299 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        
        return data
    }
    
    func fetchCicloResumo() async throws -> [CicloSoftex] {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/usuario/ciclos/resumo") else {
            throw URLError(.badURL)
        }
        return try decoder.decode([CicloSoftex].self, from: try await execute(makeRequest(url: url)))
    }
    
    func fetchCicloById(cicloId: Int) async throws -> CicloSoftex {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos/\(cicloId)") else {
            throw URLError(.badURL)
        }
        return try decoder.decode(CicloSoftex.self, from: try await execute(makeRequest(url: url)))
    }
    
    func postCiclo(newCiclo: CicloSoftex) async throws -> CicloSoftex {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/ciclos") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(newCiclo))
        return try decoder.decode(CicloSoftex.self, from: try await execute(request))
    }
    
    func postGasto(newGasto: GastosDia, diaId: Int) async throws -> GastosDia {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/dias/\(diaId)/gastos") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(newGasto))
        return try decoder.decode(GastosDia.self, from: try await execute(request))
    }
    
    func deleteGasto(gastoId: Int) async throws {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/\(gastoId)") else {
            throw URLError(.badURL)
        }
        try await execute(makeRequest(url: url, method: "DELETE"))
    }
    
    func extrairGastoDeImagem(imageData: Data) async throws -> GastoExtraidoResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/gastos/extrair") else {
            throw URLError(.badURL)
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"imagem\"; filename=\"comprovante.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = makeRequest(url: url, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        request.timeoutInterval = 90
        
        return try decoder.decode(GastoExtraidoResponse.self, from: try await execute(request))
    }
    
    func login(dados: LoginRequest) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/login") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(dados))
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
    }

    func register(dados: RegisterRequest) async throws -> AuthResponse {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/auth/register") else {
            throw URLError(.badURL)
        }
        let request = makeRequest(url: url, method: "POST", body: try encoder.encode(dados))
        return try decoder.decode(AuthResponse.self, from: try await execute(request, logout401: false))
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

