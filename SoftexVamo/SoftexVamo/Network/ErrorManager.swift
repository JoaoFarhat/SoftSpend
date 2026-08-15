import Foundation
import Combine
import SwiftUI

@MainActor
class ErrorManager: ObservableObject {
    @Published var isPresented = false
    @Published var title = "Erro"
    @Published var message = ""
    @Published var requestId: String?

    func show(title: String = "Erro", message: String, requestId: String? = nil) {
        self.title = title
        self.message = message
        self.requestId = requestId
        self.isPresented = true
    }

    func show(error: Error, requestId: String? = nil) {
        let message = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        show(message: message, requestId: requestId ?? (error as? APIError)?.requestId)
    }
}
