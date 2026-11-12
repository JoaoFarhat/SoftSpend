import SwiftUI
import PhotosUI

extension View {
    /// Seletor de foto da galeria + carregamento (`PhotosPickerItem` → `Data` →
    /// `UIImage`) + alerta de falha. Enquanto a foto carrega, mostra um
    /// `ProgressView`: sem internet, a foto do iCloud pode demorar a falhar e a
    /// tela parecer parada.
    func carregarFotoDaGaleria(
        isPresented: Binding<Bool>,
        aoEscolher: @escaping (UIImage) -> Void
    ) -> some View {
        modifier(CarregarFotoGaleria(aberto: isPresented, aoEscolher: aoEscolher))
    }
}

private struct CarregarFotoGaleria: ViewModifier {
    @Binding var aberto: Bool
    let aoEscolher: (UIImage) -> Void

    @State private var item: PhotosPickerItem?
    /// Foto da galeria que não abriu (ex.: arquivo no iCloud sem internet).
    @State private var erroFoto = false
    /// `loadTransferable` em andamento (a espera do iCloud pode ser longa).
    @State private var carregando = false
    /// Carregamento da escolha atual; uma escolha nova enquanto a anterior
    /// carrega (o iCloud pode demorar) a cancela — só a última foto entrega.
    @State private var tarefa: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $aberto, selection: $item, matching: .images)
            .onChange(of: item) { _, novo in
                guard let novo else { return }
                carregando = true
                tarefa?.cancel()
                tarefa = Task {
                    do {
                        let dados = try await novo.loadTransferable(type: Data.self)
                        guard !Task.isCancelled else { return }
                        if let dados, let imagem = UIImage(data: dados) {
                            aoEscolher(imagem)
                        } else {
                            erroFoto = true
                        }
                    } catch {
                        if Task.isCancelled { return }
                        erroFoto = true
                    }
                    item = nil
                    carregando = false
                }
            }
            .alert("Não deu para abrir a foto", isPresented: $erroFoto) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Não deu para abrir essa foto. Se ela estiver no iCloud, conecte-se à internet ou tire a foto com a câmera.")
            }
            .overlay {
                if carregando {
                    ProgressView()
                        .tint(.white)
                        .padding(Espaco.g)
                        .background(.black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: Raio.lista, style: .continuous))
                }
            }
            .animation(.default, value: carregando)
    }
}
