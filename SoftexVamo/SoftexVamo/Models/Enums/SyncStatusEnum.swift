//
//  SyncStatusEnum.swift
//  SoftSpend
//
//  Created by Joao Victor on 14/08/26.
//

import Foundation

enum SyncStatus: Codable {
    case pending    // nunca foi sync
    case syncing    // tentando agora
    case synced     // sucesso
    case failed     // erro
}
