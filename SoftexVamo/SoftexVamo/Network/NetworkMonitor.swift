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

    @Published private(set) var isConnected: Bool

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "br.com.softspend.networkmonitor")

    private init() {
        // currentPath antes de start() não reflete o estado real da rede
        // (costuma ser .requiresConnection). Iniciar como true preserva o
        // comportamento anterior de tentar sync na primeira carga; o handler
        // corrige assim que o monitor publica o path real.
        isConnected = true

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
