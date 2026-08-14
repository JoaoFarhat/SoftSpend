//
//  UserModel.swift
//  SoftexVamo
//
//  Created by Joao Victor on 30/04/26.
//

import Foundation
import SwiftData

@Model
final class UserModel {
    var id: Int
    var nome: String
    var username: String
    var email: String
    
    var syncStatus: SyncStatus = SyncStatus.synced
    var criadoEm: Date = Date.now
    var atualizadoEm: Date = Date.now
    
    init(
        id: Int,
        nome: String,
        username: String,
        email: String
    ) {
        self.id = id
        self.nome = nome
        self.username = username
        self.email = email
    }
    
    convenience init(from dto: UserDTO) {
        self.init(
            id: dto.id,
            nome: dto.nome,
            username: dto.username,
            email: dto.email
        )
    }
}


