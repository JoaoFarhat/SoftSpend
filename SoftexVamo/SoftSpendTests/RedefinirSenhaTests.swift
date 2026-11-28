import Testing
import Foundation
@testable import SoftSpend

/// "Esqueci minha senha" (`RedefinirSenhaViewModel`) e o aviso de e-mail já
/// cadastrado no cadastro (`APIError.emailJaCadastrado`).
@MainActor
struct RedefinirSenhaTests {
    let api = FakeRedefinicaoSenhaAPI()
    let senhaBoa = "Nova#Senha9"

    func viewModel(email: String = " joao@empresa.com ", entrou: Bool = true,
                   entradas: Entradas? = nil) -> RedefinirSenhaViewModel {
        let entradas = entradas ?? Entradas()
        return RedefinirSenhaViewModel(email: email, api: api) { email, senha in
            entradas.registrar(email, senha)
            return entrou
        }
    }

    @MainActor
    final class Entradas {
        private(set) var feitas: [(String, String)] = []
        func registrar(_ email: String, _ senha: String) { feitas.append((email, senha)) }
    }

    func falhaServidor(_ codigo: String, _ status: Int) -> APIError {
        .serverError(message: codigo, requestId: "r", statusCode: status)
    }

    // MARK: Etapa do e-mail

    @Test func enviarCodigoVaiParaAEtapaDoCodigo() async {
        let vm = viewModel()
        await vm.enviarCodigo()

        #expect(api.chamadas == [.pedir(email: "joao@empresa.com")])
        #expect(vm.etapa == .codigo)
        #expect(vm.minutosValidade == 15)
        #expect(vm.segundosParaReenviar == 60)
        #expect(vm.podeReenviar == false)
        #expect(vm.erro == nil)
    }

    @Test func emailMalFormadoNaoChamaOServidor() async {
        let vm = viewModel(email: "joao@empresa")
        #expect(vm.podeEnviarCodigo == false)
        await vm.enviarCodigo()

        #expect(api.chamadas.isEmpty)
        #expect(vm.etapa == .email)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.emailInvalido)
    }

    @Test func servidorSemEmailMostraIndisponivel() async {
        api.erroAoPedir = falhaServidor("email_unavailable", 503)
        let vm = viewModel()
        await vm.enviarCodigo()

        #expect(vm.etapa == .email)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.indisponivel)
    }

    @Test func semConexaoMantemOEmail() async {
        api.erroAoPedir = URLError(.timedOut)
        let vm = viewModel()
        await vm.enviarCodigo()

        #expect(vm.etapa == .email)
        #expect(vm.email == "joao@empresa.com")
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.semConexao)
    }

    @Test func limiteDeTentativasMostraAviso() async {
        api.erroAoPedir = falhaServidor("Rate limit exceeded", 429)
        let vm = viewModel()
        await vm.enviarCodigo()

        #expect(vm.erro == RedefinirSenhaViewModel.Texto.muitasTentativas)
    }

    // MARK: Etapa do código

    @Test func codigoAceitaSoSeisDigitos() {
        let vm = viewModel()
        vm.codigo = "12 34a5678"
        #expect(vm.codigo == "123456")
    }

    @Test func redefinirTrocaASenhaEEntraComAsenhaNova() async {
        let entradas = Entradas()
        let vm = viewModel(entradas: entradas)
        await vm.enviarCodigo()
        vm.codigo = "042917"
        vm.novaSenha = senhaBoa
        vm.confirmarSenha = senhaBoa
        #expect(vm.podeRedefinir)

        await vm.redefinir()

        #expect(api.chamadas.last == .redefinir(email: "joao@empresa.com", codigo: "042917", novaSenha: senhaBoa))
        #expect(entradas.feitas.count == 1)
        #expect(entradas.feitas.first?.0 == "joao@empresa.com")
        #expect(entradas.feitas.first?.1 == senhaBoa)
        // Código e senhas saem da memória depois da troca.
        #expect(vm.codigo.isEmpty && vm.novaSenha.isEmpty && vm.confirmarSenha.isEmpty)
        #expect(vm.etapa == .codigo)
    }

    @Test func senhaTrocadaMasLoginFalhouMostraSenhaAlterada() async {
        let vm = viewModel(entrou: false)
        await vm.enviarCodigo()
        vm.codigo = "042917"
        vm.novaSenha = senhaBoa
        vm.confirmarSenha = senhaBoa

        await vm.redefinir()

        #expect(vm.etapa == .senhaAlterada)
    }

    @Test func codigoRecusadoOferecePedirOutro() async {
        api.erroAoRedefinir = falhaServidor("invalid_reset_code", 400)
        let entradas = Entradas()
        let vm = viewModel(entradas: entradas)
        await vm.enviarCodigo()
        vm.codigo = "000000"
        vm.novaSenha = senhaBoa
        vm.confirmarSenha = senhaBoa

        await vm.redefinir()

        #expect(vm.erro == RedefinirSenhaViewModel.Texto.codigoInvalido)
        #expect(vm.codigoRecusado)
        #expect(vm.etapa == .codigo)
        #expect(entradas.feitas.isEmpty)
        // A senha digitada fica para tentar de novo com outro código.
        #expect(vm.novaSenha == senhaBoa)
    }

    @Test func senhasDiferentesOuFracasNaoChamamOServidor() async {
        let vm = viewModel()
        await vm.enviarCodigo()
        vm.codigo = "042917"

        vm.novaSenha = senhaBoa
        vm.confirmarSenha = "Outra#Senha9"
        #expect(vm.podeRedefinir == false)
        await vm.redefinir()
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.senhasDiferentes)

        vm.novaSenha = "fraca"
        vm.confirmarSenha = "fraca"
        await vm.redefinir()
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.senhaFraca)

        #expect(api.chamadas == [.pedir(email: "joao@empresa.com")])
    }

    @Test func usarOutroEmailVoltaAoComecoELimpaOCodigo() async {
        let vm = viewModel()
        await vm.enviarCodigo()
        vm.codigo = "042917"
        vm.novaSenha = senhaBoa

        vm.usarOutroEmail()

        #expect(vm.etapa == .email)
        #expect(vm.codigo.isEmpty && vm.novaSenha.isEmpty)
        #expect(vm.podeReenviar)
    }

    @Test func reenviarSoDepoisDaEspera() async {
        api.resposta = EsqueciSenhaResponse(expiresInSeconds: 600, resendAfterSeconds: 0)
        let vm = viewModel()
        await vm.enviarCodigo()
        #expect(vm.minutosValidade == 10)
        #expect(vm.podeReenviar)

        vm.codigo = "111111"
        await vm.reenviarCodigo()

        #expect(api.chamadas.count == 2)
        #expect(vm.codigo.isEmpty)
    }

    // MARK: Bloqueio depois de 5 códigos errados

    /// Deixa a tela na etapa do código com senha válida e o servidor
    /// respondendo `invalid_reset_code`; sem espera para reenviar.
    func telaDeCodigoRecusado() async -> RedefinirSenhaViewModel {
        api.resposta = EsqueciSenhaResponse(expiresInSeconds: 900, resendAfterSeconds: 0)
        api.erroAoRedefinir = falhaServidor("invalid_reset_code", 400)
        let vm = viewModel()
        await vm.enviarCodigo()
        vm.codigo = "000000"
        vm.novaSenha = senhaBoa
        vm.confirmarSenha = senhaBoa
        return vm
    }

    @Test func quatroRecusasSeguemOferecendoPedirOutro() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...4 { await vm.redefinir() }

        #expect(!vm.bloqueado)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.codigoInvalido)
        #expect(vm.codigoRecusado)
        #expect(vm.podeReenviar)
        #expect(vm.podeRedefinir)
    }

    @Test func quintaRecusaBloqueia() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...5 { await vm.redefinir() }

        #expect(vm.bloqueado)
        #expect(vm.erro == "Muitas tentativas erradas. Por segurança, peça um novo código daqui a 24 horas.")
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.bloqueado)
        #expect(!vm.codigoRecusado)
        #expect(!vm.podeReenviar)
        #expect(!vm.podeRedefinir)
    }

    @Test func reenviarCodigoNaoZeraAsRecusas() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...4 { await vm.redefinir() }
        #expect(!vm.bloqueado)

        await vm.reenviarCodigo()   // o servidor herda as erradas no código novo
        #expect(vm.codigo.isEmpty)
        #expect(!vm.bloqueado)

        vm.codigo = "111111"
        await vm.redefinir()        // 5ª recusa do mesmo e-mail

        #expect(vm.bloqueado)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.bloqueado)
    }

    @Test func trocarOEmailZeraAsRecusas() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...5 { await vm.redefinir() }
        #expect(vm.bloqueado)

        vm.usarOutroEmail()
        #expect(!vm.bloqueado)
        #expect(vm.etapa == .email)

        vm.email = "maria@empresa.com"
        await vm.enviarCodigo()
        vm.codigo = "000000"
        vm.novaSenha = senhaBoa
        vm.confirmarSenha = senhaBoa

        for _ in 1...4 { await vm.redefinir() }

        #expect(!vm.bloqueado)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.codigoInvalido)
        #expect(vm.codigoRecusado)
    }

    @Test func mesmoEmailMantemAsRecusasDepoisDeUsarOutroEmail() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...4 { await vm.redefinir() }

        vm.usarOutroEmail()         // volta à etapa do e-mail sem trocá-lo
        await vm.enviarCodigo()
        vm.codigo = "000000"
        vm.novaSenha = senhaBoa
        vm.confirmarSenha = senhaBoa

        await vm.redefinir()        // 5ª recusa do mesmo e-mail

        #expect(vm.bloqueado)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.bloqueado)
    }

    @Test func usarOutroEmailComOMesmoEmailMantemOBloqueio() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...5 { await vm.redefinir() }
        #expect(vm.bloqueado)
        let chamadasAteAqui = api.chamadas.count

        vm.usarOutroEmail()         // volta à etapa do e-mail sem trocá-lo
        await vm.enviarCodigo()     // o servidor responderia 202 sem mandar e-mail

        #expect(api.chamadas.count == chamadasAteAqui)
        #expect(vm.bloqueado)
        #expect(vm.erro == RedefinirSenhaViewModel.Texto.bloqueado)
        #expect(vm.etapa == .email)
    }

    @Test func bloqueadoNaoSaiChamadaNovaParaAAPI() async {
        let vm = await telaDeCodigoRecusado()

        for _ in 1...5 { await vm.redefinir() }
        #expect(vm.bloqueado)
        let chamadasAteAqui = api.chamadas.count

        await vm.redefinir()
        await vm.reenviarCodigo()
        await vm.enviarCodigo()

        #expect(api.chamadas.count == chamadasAteAqui)
    }

    // MARK: Cadastro com e-mail já usado

    @Test func emailJaCadastradoSoNo409ComOCodigo() {
        #expect(falhaServidor("email_in_use", 409).emailJaCadastrado)
        #expect(!falhaServidor("Dados de cadastro ja em uso", 400).emailJaCadastrado)
        #expect(!falhaServidor("email_in_use", 400).emailJaCadastrado)
    }

    @Test func regraSenhaIgualAoServidor() {
        #expect(RegraSenha(senha: "Senha#2026").valida)
        #expect(!RegraSenha(senha: "senha#2026").valida)  // sem maiúscula
        #expect(!RegraSenha(senha: "Senha2026").valida)   // sem especial
        #expect(!RegraSenha(senha: "Se#1").valida)        // curta
        #expect(!RegraSenha(senha: "A#1" + String(repeating: "a", count: 126)).valida)  // > 128
    }
}
