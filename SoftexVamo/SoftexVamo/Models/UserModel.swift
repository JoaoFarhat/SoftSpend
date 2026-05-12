//
//  UserModel.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import Foundation

struct UserModel: Codable, Identifiable {
    let id: Int
    let nome: String
    let username: String
    let email: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case nome
        case username
        case email
    }
}

struct RegisterRequest: Codable {
    let nome: String
    let username: String
    let email: String
    let senha: String
}

struct LoginRequest: Codable {
    let email: String
    let senha: String
}

struct AuthResponse: Codable {
    let id: Int
    let nome: String
    let username: String
    let email: String
    let token: String
}
