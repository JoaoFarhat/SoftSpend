import SwiftUI
import PhotosUI

/// Tela 9: câmera do comprovante, com "Galeria" (fotos ou PDF em Arquivos) e
/// "Sem foto". Sem câmera (simulador) ou sem permissão, as duas saídas continuam.
struct CameraComprovanteView: View {
    let aoFechar: () -> Void
    let aoEscolher: (ResultadoComprovante) -> Void
    /// Imagem fixa no lugar da câmera (modo de demonstração, para capturas).
    var previewFixo: UIImage? = nil

    @StateObject private var camera = CameraComprovante()
    @State private var fotos = false
    @State private var arquivos = false
    @State private var itemFotos: PhotosPickerItem?
    /// `loadTransferable` da escolha atual; uma escolha nova enquanto a anterior
    /// carrega (o iCloud pode demorar) a cancela — só a última foto entrega.
    @State private var tarefaFoto: Task<Void, Never>?
    /// Câmera do sistema (`CameraPicker`), quando a câmera própria não abre mas o aparelho tem câmera.
    @State private var cameraDoSistema = false
    @State private var fotoDoSistema: UIImage?
    /// Foto da galeria que não abriu (ex.: arquivo no iCloud sem internet).
    @State private var erroFoto = false
    @ScaledMetric(relativeTo: .body) private var ladoObturador: CGFloat = 72

    private var podeFotografar: Bool { previewFixo == nil && camera.estado == .pronta && !camera.fotografando }

    var body: some View {
        VStack(spacing: 0) {
            topo
            Spacer(minLength: Espaco.g)
            moldura
                .padding(.horizontal, 30)
            Text(camera.falhouFoto ? "Não foi possível tirar a foto. Tente de novo ou use a galeria."
                            : "Enquadre o comprovante inteiro")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, Espaco.g)
                .padding(.top, Espaco.g + 4)
            Spacer(minLength: Espaco.g)
            controles
                .padding(.bottom, Espaco.g)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            guard previewFixo == nil else { return }
            await camera.preparar()
        }
        .onDisappear { camera.parar() }
        .photosPicker(isPresented: $fotos, selection: $itemFotos, matching: .images)
        .onChange(of: itemFotos) { _, item in
            guard let item else { return }
            tarefaFoto?.cancel()
            tarefaFoto = Task {
                defer { itemFotos = nil }
                do {
                    let dados = try await item.loadTransferable(type: Data.self)
                    guard !Task.isCancelled else { return }
                    if let dados, let imagem = UIImage(data: dados) {
                        aoEscolher(.foto(imagem))
                    } else {
                        erroFoto = true
                    }
                } catch {
                    if !Task.isCancelled { erroFoto = true }
                }
            }
        }
        .alert("Não deu para abrir a foto", isPresented: $erroFoto) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Não deu para abrir essa foto. Se ela estiver no iCloud, conecte-se à internet ou tire a foto com a câmera.")
        }
        .fullScreenCover(isPresented: $cameraDoSistema) {
            CameraPicker(image: $fotoDoSistema).ignoresSafeArea()
        }
        .onChange(of: fotoDoSistema) { _, nova in
            guard let nova else { return }
            fotoDoSistema = nil
            aoEscolher(.foto(nova))
        }
        .fileImporter(isPresented: $arquivos, allowedContentTypes: [.image, .pdf]) { resultado in
            if case .success(let url) = resultado {
                aoEscolher(.arquivo(url))
            }
        }
    }

    private var topo: some View {
        HStack {
            Button(action: aoFechar) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Fechar")
            Spacer()
            Text("Comprovante")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { camera.flash.toggle() } label: {
                Image(systemName: camera.flash ? "bolt.fill" : "bolt")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(camera.flash ? "Desligar flash" : "Ligar flash")
            .opacity(camera.estado == .pronta && camera.temFlash ? 1 : 0)
            .disabled(!(camera.estado == .pronta && camera.temFlash))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Espaco.p)
        .padding(.top, Espaco.p)
    }

    private var moldura: some View {
        let forma = RoundedRectangle(cornerRadius: Raio.lista, style: .continuous)
        return Color.clear
            .aspectRatio(0.66, contentMode: .fit)
            .overlay { conteudoMoldura }
            .clipShape(forma)
            .padding(6)
            .overlay {
                RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
            }
    }

    @ViewBuilder
    private var conteudoMoldura: some View {
        if let previewFixo {
            Image(uiImage: previewFixo).resizable().scaledToFill()
        } else {
            switch camera.estado {
            case .pronta:
                PreviewCamera(sessao: camera.sessao)
            case .preparando:
                Color(white: 0.11).overlay { ProgressView().tint(.white) }
            case .indisponivel:
                aviso("Câmera indisponível neste aparelho. Escolha uma foto na galeria ou lance sem foto.")
            case .semPermissao:
                aviso("O SoftSpend não tem acesso à câmera. Libere em Ajustes ou escolha uma foto na galeria.",
                      ajustes: true)
            }
        }
    }

    private func aviso(_ texto: String, ajustes: Bool = false) -> some View {
        VStack(spacing: Espaco.m) {
            Image(systemName: "camera")
                .font(.title2)
                .accessibilityHidden(true)
            Text(texto)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if ajustes, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Abrir Ajustes", destination: url)
                    .font(.subheadline.weight(.semibold))
            } else if UIImagePickerController.isSourceTypeAvailable(.camera) {
                // O aparelho tem câmera, mas a sessão própria não abriu.
                Button("Usar a câmera do sistema") { cameraDoSistema = true }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(Espaco.g + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.11))
    }

    private var controles: some View {
        HStack {
            Menu {
                Button("Fotos", systemImage: "photo.on.rectangle") { fotos = true }
                Button("Arquivos", systemImage: "folder") { arquivos = true }
            } label: {
                Text("Galeria")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }

            Button {
                Task {
                    // A falha fica no `camera` (objeto), não em @State: a tela pode já ter saído.
                    if let foto = await camera.fotografar() {
                        aoEscolher(.foto(foto))
                    }
                }
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: ladoObturador, height: ladoObturador)
                    .padding(5)
                    .background(Circle().strokeBorder(.white, lineWidth: 3))
            }
            .buttonStyle(.plain)
            .disabled(!podeFotografar && previewFixo == nil)
            .opacity(podeFotografar || previewFixo != nil ? 1 : 0.35)
            .accessibilityLabel("Tirar foto")

            Button { aoEscolher(.semFoto) } label: {
                Text("Sem foto")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .font(.body)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, Espaco.g)
    }
}

#Preview { CameraComprovanteView(aoFechar: {}, aoEscolher: { _ in }) }
