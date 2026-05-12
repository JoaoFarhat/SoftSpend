//
//  CameraPicker.swift
//  SoftexVamo

import SwiftUI
import UIKit

/// View que apresenta o `UIImagePickerController` nativo para captura de fotos.
///
/// Conforma `UIViewControllerRepresentable` para integrar uma view UIKit no
/// ciclo de vida do SwiftUI.
///
/// - Parameters:
///   - image: Binding opcional para a `UIImage` resultante. Recebe a imagem
///     capturada quando o usuario confirma, ou permanece inalterado se cancelar.
struct CameraPicker: UIViewControllerRepresentable {
    
    /// Imagem capturada pelo usuario. Atualizada quando a captura e confirmada.
    @Binding var image: UIImage?
    
    /// Action de dismiss injetada pelo SwiftUI. Usado para fechar o picker automaticamente ao finalizar (confirmar ou cancelar) a captura.
    @Environment(\.dismiss) var dismiss
    
    /// Cria a instancia do `UIImagePickerController` configurada.
    ///
    /// Se a camera estiver disponivel no dispositivo, abre direto na camera.
    /// Caso contrario (ex: simulador iOS), faz fallback para `.photoLibrary` para testar o fluxo em desenvolvimento.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    
    /// Nao ha estado a sincronizar apos a criacao - o picker e descartavel.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    /// Cria o `Coordinator` que faz a ponte entre os delegates UIKit e o estado SwiftUI desta view.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    /// Coordinator que recebe os callbacks do `UIImagePickerController`.
    ///
    /// Implementa `UIImagePickerControllerDelegate` (para receber a foto) e `UINavigationControllerDelegate` (exigido pelo protocolo da Apple, mesmo que nao usemos navegacao customizada).
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        
        /// Referencia para a view pai, usada para escrever no binding `image` e disparar o `dismiss`.
        let parent: CameraPicker
        
        init(_ parent: CameraPicker) {
            self.parent = parent
        }
        
        /// Chamado quando o usuario confirma a foto.
        ///
        /// Extrai a imagem original (sem edicao) do dicionario de info, atualiza o binding `image` e fecha o picker.
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }
        
        /// Chamado quando o usuario cancela a captura. Apenas fecha o picker sem alterar o binding.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
