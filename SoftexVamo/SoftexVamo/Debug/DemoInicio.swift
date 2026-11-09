#if DEBUG
import SwiftUI
import SwiftData

/// Início com a viagem de exemplo, sem login nem rede, para capturas de tela.
///
/// `xcrun simctl launch <udid> com.joao.softspend -demo durante`
/// (estados: durante, antes, encerrada, vazio, menu; telas de lançar gasto:
/// consentimento, camera, confirmar, detalhe; todos os gastos: todos, semfoto;
/// avisos de diária: aviso; nova viagem: novaviagem; viagens: viagens;
/// fechar viagem: fechar; perfil e ajustes: perfil; acesso: entrar, criarconta).
struct DemoInicioView: View {
    enum Estado: String {
        case durante, antes, encerrada, vazio, menu
        case consentimento, camera, confirmar, detalhe
        case todos, semfoto, aviso
        case novaviagem, viagens
        case fechar, perfil, entrar, criarconta
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
        switch estado {
        case .vazio: vm.allCiclos = []
        case .viagens, .novaviagem: vm.allCiclos = [dados.ciclo] + dados.anteriores
        default: vm.allCiclos = [dados.ciclo]
        }
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
        case .encerrada, .fechar: return dados.dia(30)
        default: return dados.hoje
        }
    }

    /// Tela 11: o Spoleto de hoje (a foto de exemplo é guardada no `init`,
    /// nunca durante o body).
    private var caminhoInicial: [Rota] {
        if estado == .todos { return [.todosGastos(filtro: .todos)] }
        if estado == .semfoto { return [.todosGastos(filtro: .semComprovante)] }
        if estado == .viagens { return [.viagens] }
        if estado == .novaviagem { return [.viagens, .novaViagem] }
        if estado == .fechar { return [.fecharViagem(dados.ciclo.id)] }
        if estado == .perfil { return [.perfil] }
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

    /// Tela 4: Cuiabá, 20 a 25/07, digitando só a diária de R$ 450.
    private var formularioExemplo: FormularioViagem {
        var f = FormularioViagem(ida: dados.dia(20), volta: dados.dia(25), destino: "Cuiabá, MT")
        f.editarDiaria("450")
        f.formatarCampos()
        return f
    }

    @ViewBuilder
    var body: some View {
        switch estado {
        case .entrar:
            LoginView(emailInicial: "joao@empresa.com", senhaInicial: "Senha#2026")
        case .criarconta:
            RegisterView(nome: "João Victor Farhat", email: "joao@empresa.com", senha: "Senha#2026")
        default:
            inicio
        }
    }

    private var inicio: some View {
        MainView(hojeFixo: hoje, sincronizar: false, origem: "São Paulo",
                 usuario: UsuarioMenu(nome: "João Victor Farhat", email: "joao@empresa.com"),
                 menuInicial: estado == .menu,
                 caminhoInicial: caminhoInicial, lancamentoInicial: lancamentoInicial)
            .environmentObject(viewModel)
            .environmentObject(errorManager)
            .environmentObject(AuthService.shared)
            .modelContainer(dados.container)
            .environment(\.formularioNovaViagem, estado == .novaviagem ? formularioExemplo : nil)
            .task {
                // Tela 13: um aviso de cada tipo (a permissão é pedida no primeiro).
                guard estado == .aviso else { return }
                // Espaçados para cada banner poder ser capturado sozinho.
                await AvisoDiaria.agendar(.oitentaPorCento(livre: 90, data: dados.hoje), cidade: "Cuiabá", diaria: 450)
                try? await Task.sleep(for: .seconds(8))
                await AvisoDiaria.agendar(.passou(valor: 38, data: dados.dia(21)), cidade: "Cuiabá", diaria: 450)
            }
    }
}

#Preview("Durante claro") { DemoInicioView(estado: .durante).preferredColorScheme(.light) }
#Preview("Durante escuro") { DemoInicioView(estado: .durante).preferredColorScheme(.dark) }
#Preview("Antes") { DemoInicioView(estado: .antes) }
#Preview("Encerrada") { DemoInicioView(estado: .encerrada) }
#Preview("Vazio") { DemoInicioView(estado: .vazio) }
#Preview("Menu") { DemoInicioView(estado: .menu) }
#endif
