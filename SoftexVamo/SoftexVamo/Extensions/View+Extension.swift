//
//  View+Extension.swift
//  SoftexVamo
//
//  Created by Joao Victor on 07/04/26.
//

import Foundation
import SwiftUI

public extension View {
    
    func skeleton<S>(
        _ shape: S? = nil as Rectangle?, isLoading: Bool) -> some View where S: Shape {
            guard isLoading else {return AnyView(self)}
            let skeletonColor = Color.gray.opacity(0.3)
            
            let skeletonShape: AnyShape = if let shape {
                AnyShape(shape)
            } else {
                AnyShape(Rectangle())
            }
            
            return AnyView(
                opacity(0)
                    .overlay(skeletonShape.fill(skeletonColor))
                    .shimmering()
                
                
            )
        }
    
    func shimmering() -> some View {
        modifier(ShimmeringModifier())
    }
}

public struct ShimmeringModifier: ViewModifier {
    // Começamos em -0.3 para a luz iniciar totalmente fora da tela (à esquerda)
    @State private var phase: CGFloat = -0.3
    
    public func body(content: Content) -> some View {
        content
            .modifier(AnimatedMask(phase: phase))
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5) // Deixei um pouco mais rápido para fluidez
                    .repeatForever(autoreverses: false)
                ) {
                    // Terminamos em 1.3 para a luz sair totalmente pela direita
                    phase = 1.3
                }
            }
    }
}

struct AnimatedMask: AnimatableModifier {
    var phase: CGFloat
    
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }
    
    func body(content: Content) -> some View {
        content.mask(GradientMask(phase: phase))
    }
}

struct GradientMask: View {
    let phase: CGFloat
    let centerColor = Color.white.opacity(0.4)
    let edgeColor = Color.white.opacity(1)
    
    var body: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: edgeColor, location: phase - 0.15),
                .init(color: centerColor, location: phase),
                .init(color: edgeColor, location: phase + 0.15)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
