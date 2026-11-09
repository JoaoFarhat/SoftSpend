#if DEBUG
import SwiftUI
import SwiftData

/// Início com a viagem de exemplo, sem login nem rede, para capturas de tela.
///
/// `xcrun simctl launch <udid> com.joao.softspend -demo durante`
/// (estados: durante, antes, encerrada, vazio, menu; telas de lançar gasto:
/// consentimento, camera, confirmar, detalhe).
struct DemoInicioView: View {
    enum Estado: String {
        case durante, antes, encerrada, vazio, menu
        case consentimento, camera, confirmar, detalhe
    }

    static var pedido: Estado? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-demo") else { return nil }
        guard i + 1 < args.count else { return .durante }
        return Estado(rawValue: args[i + 1]) ?? .durante
    }

    let estado: Estado
    private let dados = DadosExemplo.compartilhado
    @StateObject private var viewModel: CiclosViewModel
    @StateObject private var errorManager = ErrorManager()

    init(estado: Estado) {
        self.estado = estado
        let vm = CiclosViewModel()
        let dados = DadosExemplo.compartilhado
        vm.allCiclos = estado == .vazio ? [] : [dados.ciclo]
        vm.atualCiclo = estado == .vazio ? CicloSoftex.vazio : dados.ciclo
        vm.isLoading = false
        vm.modelContext = dados.container.mainContext
        _viewModel = StateObject(wrappedValue: vm)
        if estado == .detalhe,
           let spoleto = dados.gastosDeHoje.first(where: { $0.titulo == "Spoleto" }),
           spoleto.comprovanteDataCriptografado == nil {
            spoleto.comprovanteData = DadosExemplo.imagemComprovante().jpegData(compressionQuality: 0.9)
        }
    }

    /// Antes = 17/07 (começa em 3 dias); encerrada = 30/07; demais = 23/07.
    private var hoje: Date {
        switch estado {
        case .antes: return dados.dia(17)
        case .encerrada: return dados.dia(30)
        default: return dados.hoje
        }
    }

    /// Tela 11: o Spoleto de hoje (a foto de exemplo é guardada no `init`,
    /// nunca durante o body).
    private var caminhoInicial: [Rota] {
        guard estado == .detalhe, let spoleto = dados.gastosDeHoje.first(where: { $0.titulo == "Spoleto" }) else { return [] }
        return [.detalheGasto(spoleto.id)]
    }

    /// Telas 8, 9 e 10 abertas direto, como se viessem de "Fotografar comprovante".
    private var lancamentoInicial: Lancamento? {
        switch estado {
        case .consentimento:
            return Lancamento(ciclo: dados.ciclo, comFoto: true, etapa: .consentimento)
        case .camera:
            return Lancamento(ciclo: dados.ciclo, comFoto: true, etapa: .camera,
                              previewCamera: DadosExemplo.imagemComprovante())
        case .confirmar:
            let r = RascunhoGasto(dia: diaDeHoje(dados.ciclo, hoje: dados.hoje))
            r.imagem = DadosExemplo.imagemComprovante()
            r.titulo = "Spoleto"
            r.valorTexto = "43,10"
            r.categoria = .ALIMENTACAO
            r.leuComprovante = true
            r.criadoEm = dados.dia(23, 13, 42)
            return Lancamento(ciclo: dados.ciclo, comFoto: true, etapa: .confirmar, rascunho: r)
        default:
            return nil
        }
    }

    var body: some View {
        MainView(hojeFixo: hoje, sincronizar: false, origem: "São Paulo",
                 usuario: UsuarioMenu(nome: "João Victor Farhat", email: "joao@empresa.com"),
                 menuInicial: estado == .menu,
                 caminhoInicial: caminhoInicial, lancamentoInicial: lancamentoInicial)
            .environmentObject(viewModel)
            .environmentObject(errorManager)
            .environmentObject(AuthService.shared)
            .modelContainer(dados.container)
    }
}

#Preview("Durante claro") { DemoInicioView(estado: .durante).preferredColorScheme(.light) }
#Preview("Durante escuro") { DemoInicioView(estado: .durante).preferredColorScheme(.dark) }
#Preview("Antes") { DemoInicioView(estado: .antes) }
#Preview("Encerrada") { DemoInicioView(estado: .encerrada) }
#Preview("Vazio") { DemoInicioView(estado: .vazio) }
#Preview("Menu") { DemoInicioView(estado: .menu) }
#endif
