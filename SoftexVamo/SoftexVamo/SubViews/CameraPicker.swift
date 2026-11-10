//
//  CameraPicker.swift
//  SoftexVamo

import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import Combine

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

// MARK: - Escolha do comprovante

/// O que o usuário escolheu na câmera (tela 9) ou no "Adicionar comprovante".
enum ResultadoComprovante {
    case foto(UIImage)
    case arquivo(URL)
    case semFoto
}

extension View {
    /// Diálogo "Adicionar comprovante": tirar foto (câmera do sistema; sem
    /// câmera, como no simulador, abre as fotos), escolher das fotos ou de Arquivos.
    func escolherComprovante(
        isPresented: Binding<Bool>,
        aoEscolher: @escaping (ResultadoComprovante) -> Void
    ) -> some View {
        modifier(EscolherComprovante(aberto: isPresented, aoEscolher: aoEscolher))
    }
}

private struct EscolherComprovante: ViewModifier {
    @Binding var aberto: Bool
    let aoEscolher: (ResultadoComprovante) -> Void

    @State private var camera = false
    @State private var fotos = false
    @State private var arquivos = false
    @State private var fotoTirada: UIImage?
    @State private var itemFotos: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Adicionar comprovante", isPresented: $aberto, titleVisibility: .visible) {
                Button("Tirar foto") { camera = true }
                Button("Escolher das fotos") { fotos = true }
                Button("Escolher arquivo") { arquivos = true }
                Button("Cancelar", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker(image: $fotoTirada).ignoresSafeArea()
            }
            .onChange(of: fotoTirada) { _, nova in
                guard let nova else { return }
                fotoTirada = nil
                aoEscolher(.foto(nova))
            }
            .photosPicker(isPresented: $fotos, selection: $itemFotos, matching: .images)
            .onChange(of: itemFotos) { _, item in
                guard let item else { return }
                Task {
                    if let dados = try? await item.loadTransferable(type: Data.self),
                       let imagem = UIImage(data: dados) {
                        aoEscolher(.foto(imagem))
                    }
                    itemFotos = nil
                }
            }
            .fileImporter(isPresented: $arquivos, allowedContentTypes: [.image, .pdf]) { resultado in
                if case .success(let url) = resultado {
                    aoEscolher(.arquivo(url))
                }
            }
    }
}

// MARK: - Câmera ao vivo (tela 9)

/// Sessão de captura da câmera traseira para a tela "Comprovante".
/// Sem câmera (simulador) ou sem permissão, fica `indisponivel`/`semPermissao`
/// e a tela oferece só "Galeria" e "Sem foto".
@MainActor
final class CameraComprovante: NSObject, ObservableObject {
    enum Estado { case preparando, pronta, indisponivel, semPermissao }

    @Published private(set) var estado: Estado = .preparando
    @Published var flash = false
    @Published private(set) var fotografando = false
    /// A última foto falhou (erro, sessão parada ou tempo esgotado).
    @Published private(set) var falhouFoto = false

    let sessao = AVCaptureSession()
    private let saida = AVCapturePhotoOutput()
    private let fila = DispatchQueue(label: "br.com.softspend.camera")
    private var continuacao: CheckedContinuation<UIImage?, Never>?
    private var configurada = false

    var temFlash: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.hasFlash ?? false
    }

    func preparar() async {
        guard let dispositivo = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            estado = .indisponivel
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                estado = .semPermissao
                return
            }
        default:
            estado = .semPermissao
            return
        }

        if !configurada {
            guard let entrada = try? AVCaptureDeviceInput(device: dispositivo) else {
                estado = .indisponivel
                return
            }
            sessao.beginConfiguration()
            sessao.sessionPreset = .photo
            if sessao.canAddInput(entrada) { sessao.addInput(entrada) }
            if sessao.canAddOutput(saida) { sessao.addOutput(saida) }
            sessao.commitConfiguration()
            configurada = true
        }
        nonisolated(unsafe) let s = sessao
        fila.async { if !s.isRunning { s.startRunning() } }
        estado = .pronta
    }

    /// Para a sessão. Uma captura em andamento termina com `nil` (nunca fica pendurada).
    func parar() {
        entregar(nil)
        nonisolated(unsafe) let s = sessao
        fila.async { if s.isRunning { s.stopRunning() } }
    }

    /// Tempo máximo esperando a foto antes de desistir com `nil`.
    private static let limiteCaptura: Duration = .seconds(10)

    /// Tira a foto em resolução cheia. `nil` se falhar, se a sessão parar no
    /// meio ou se a foto não chegar em `limiteCaptura`: a continuação é sempre
    /// retomada exatamente uma vez.
    func fotografar() async -> UIImage? {
        guard estado == .pronta, !fotografando, continuacao == nil else { return nil }
        guard let conexao = saida.connection(with: .video), conexao.isEnabled, conexao.isActive else {
            falhouFoto = true
            return nil
        }
        fotografando = true
        falhouFoto = false
        defer { fotografando = false }
        let ajustes = AVCapturePhotoSettings()
        if flash, saida.supportedFlashModes.contains(.on) {
            ajustes.flashMode = .on
        }
        let limite = Task { [weak self] in
            try? await Task.sleep(for: Self.limiteCaptura)
            guard !Task.isCancelled else { return }
            self?.entregar(nil)
        }
        defer { limite.cancel() }
        let foto = await withCheckedContinuation { cont in
            continuacao = cont
            saida.capturePhoto(with: ajustes, delegate: self)
        }
        falhouFoto = foto == nil
        return foto
    }

    /// Retoma a captura pendente. Chamadas extras (delegate duplo, tempo
    /// esgotado, `parar`) não fazem nada.
    fileprivate func entregar(_ imagem: UIImage?) {
        guard let cont = continuacao else { return }
        continuacao = nil
        cont.resume(returning: imagem)
    }
}

extension CameraComprovante: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let imagem = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        // Fila principal (FIFO): a foto chega antes do "fim da captura" abaixo.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.entregar(imagem) } }
    }

    /// Fim da captura (com ou sem erro): se a foto não foi entregue, entrega `nil`.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.entregar(nil) } }
    }
}

/// Camada de pré-visualização da câmera.
struct PreviewCamera: UIViewRepresentable {
    let sessao: AVCaptureSession

    final class Tela: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var camada: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Tela {
        let tela = Tela()
        tela.camada.session = sessao
        tela.camada.videoGravity = .resizeAspectFill
        return tela
    }

    func updateUIView(_ uiView: Tela, context: Context) {}
}
