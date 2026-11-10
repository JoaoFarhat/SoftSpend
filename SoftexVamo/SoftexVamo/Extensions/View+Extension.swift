//
//  View+Extension.swift
//  SoftexVamo
//
//  Created by Joao Victor on 07/04/26.
//

import SwiftUI

struct ErrorAlertModifier: ViewModifier {
    @ObservedObject var errorManager: ErrorManager

    func body(content: Content) -> some View {
        content
            .alert(errorManager.title, isPresented: $errorManager.isPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(errorManager.message)
                    if let requestId = errorManager.requestId {
                        Text("ID: \(requestId)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
    }
}

extension View {
    func errorAlert(errorManager: ErrorManager) -> some View {
        modifier(ErrorAlertModifier(errorManager: errorManager))
    }
}
