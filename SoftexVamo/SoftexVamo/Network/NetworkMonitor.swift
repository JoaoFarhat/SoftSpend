//
//  NetworkMonitor.swift
//  SoftSpend
//
//  Monitora conectividade de rede usando NWPathMonitor.
//  Permite que o app pule chamadas de rede quando offline,
//  evitando congelamento da UI por timeouts longos.
//

import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "br.com.softspend.networkmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
