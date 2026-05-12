//
//  SoftexVamoApp.swift
//  SoftexVamo
//
//  Created by Gabriel fontes on 25/03/26.
//

import SwiftUI
import SwiftData

@main
struct SoftexVamoApp: App {
    @StateObject var listViewModel = CiclosListViewModel()
    @StateObject var authService = AuthService.shared
    
    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
                    MainView()
                        .environmentObject(listViewModel)
                        .id(authService.currentUser?.id ?? 0)
                } else {
                    LoginView()
                        .environmentObject(authService)
                }
            }
            .onChange(of: authService.currentUser?.id) { _, _ in
                listViewModel.reset()
            }
        }
    }
}
