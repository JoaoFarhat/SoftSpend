import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Consentimento

/// Resposta do usuário à leitura automática de comprovante ou fatura
/// (Google Gemini). Exigência do `AGENTS.md` (LGPD): sem `true`, a foto ou o
/// arquivo nunca sai para leitura.
enum Consentimento {
    static let chave = "consentimentoLeituraAutomatica"
    /// §2.8: quem respondeu "sim" antes aceitou só o comprovante, e a fatura
    /// tem mais dado pessoal — a primeira importação mostra um aviso de uma
    /// tela, guardado aqui (é informativo, não um segundo interruptor).
    static let chaveAvisoFatura = "consentimentoAvisoFatura"

    /// `nil` = ainda não perguntado; `true` = permitiu; `false` = "Agora não".
    static var leituraAutomatica: Bool? {
        get { leitura(em: .standard) }
        set { gravar(newValue, em: .standard) }
    }

    /// `true` = o aviso da primeira importação de fatura já foi aceito com
    /// "Continuar". "Agora não" não grava: o aviso aparece de novo na próxima.
    static var avisoFatura: Bool {
        get { avisoFatura(em: .standard) }
        set { gravarAvisoFatura(newValue, em: .standard) }
    }

    static func leitura(em defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: chave) as? Bool
    }

    static func gravar(_ valor: Bool?, em defaults: UserDefaults) {
        if let valor {
            defaults.set(valor, forKey: chave)
        } else {
            defaults.removeObject(forKey: chave)
        }
    }

    static func avisoFatura(em defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: chaveAvisoFatura)
    }

    static func gravarAvisoFatura(_ valor: Bool, em defaults: UserDefaults) {
        defaults.set(valor, forKey: chaveAvisoFatura)
    }
}

// MARK: - Cálculo

/// Quanto ainda dá para gastar hoje depois de um gasto de `valor`
/// (`livreHoje − valor`). Negativo = passa da diária.
func sobraDepois(de valor: Decimal, resumo: ResumoViagem) -> Decimal {
    resumo.livreHoje - valor
}

/// 43.10 → "43,10", como o campo de valor mostra.
func textoValorBRL(_ valor: Decimal) -> String {
    formatarValorSemSimbolo(valor)
}

// MARK: - Nota fiscal

/// Codificação da foto do comprovante: a nota guardada mantém a resolução
/// original; só a cópia enviada para leitura é reduzida.
enum NotaFiscal {
    /// Teto de upload da nota. O servidor rejeita acima de 10MB.
    static let tamanhoMaximo = 9 * 1024 * 1024

    /// Codifica a nota preservando a resolução original.
    ///
    /// A nota arquivada precisa continuar legível para fins fiscais, então não
    /// há redimensionamento: só a conversão para JPEG (o HEIC da galeria não é
    /// universalmente legível). A qualidade cai apenas se o arquivo passar do
    /// teto aceito pelo servidor.
    static func codificar(_ image: UIImage) -> Data? {
        var qualidade: CGFloat = 0.95
        var dados = image.jpegData(compressionQuality: qualidade)
        while let atual = dados, atual.count > tamanhoMaximo, qualidade > 0.4 {
            qualidade -= 0.15
            dados = image.jpegData(compressionQuality: qualidade)
        }
        return dados
    }

    /// Reduz a imagem (maior lado 1280px, JPEG 0.8) antes de enviar à leitura.
    ///
    /// O servidor reduz para 1280px antes de enviar ao Gemini; subir a
    /// resolução total só gasta tempo de rede.
    static func comprimirParaOCR(_ image: UIImage) -> Data? {
        let ladoMaximo: CGFloat = 1280
        let maiorLado = max(image.size.width, image.size.height)
        guard maiorLado > 0 else { return nil }
        let escala = min(1, ladoMaximo / maiorLado)
        let novoTamanho = CGSize(width: image.size.width * escala, height: image.size.height * escala)

        let formato = UIGraphicsImageRendererFormat.default()
        formato.scale = 1
        let redimensionada = UIGraphicsImageRenderer(size: novoTamanho, format: formato).image { _ in
            image.draw(in: CGRect(origin: .zero, size: novoTamanho))
        }
        return redimensionada.jpegData(compressionQuality: 0.8)
    }

    enum Arquivo {
        case imagem(UIImage)
        case pdf(Data)
        case erro(String)
    }

    /// Lê um arquivo escolhido em Arquivos: PDF (até o teto) ou imagem.
    static func abrir(_ url: URL) -> Arquivo {
        let acessou = url.startAccessingSecurityScopedResource()
        defer { if acessou { url.stopAccessingSecurityScopedResource() } }
        guard let dados = try? Data(contentsOf: url) else {
            return .erro("Não foi possível ler o arquivo escolhido.")
        }
        let ext = url.pathExtension.lowercased()
        let tipo = UTType(filenameExtension: ext) ?? .data
        if tipo.conforms(to: .pdf) || ext == "pdf" {
            guard dados.count <= tamanhoMaximo else { return .erro("O PDF passa do tamanho máximo permitido.") }
            return .pdf(dados)
        }
        guard let imagem = UIImage(data: dados) else { return .erro("Arquivo de imagem não reconhecido.") }
        return .imagem(imagem)
    }
}

// MARK: - Leitura do comprovante

enum LeituraComprovante {
    private static let logger = Logger(subsystem: "br.com.softspend", category: "LeituraComprovante")

    /// Aviso mostrado no lançamento quando a assinatura barra a leitura por
    /// IA (§3.5): a tela de planos abre junto; o preenchimento à mão segue livre.
    static let avisoAssinatura =
        "A leitura por IA faz parte da assinatura. Os campos seguem livres para preencher à mão."

    /// Leitura no aparelho e depois no servidor (Gemini), aplicando cada
    /// resultado em `aplicar`. Não faz nada sem `Consentimento.leituraAutomatica == true`.
    ///
    /// `acesso`, `lerLocal` e `extrair` são as costuras de teste: em produção
    /// são o `AssinaturaViewModel.shared`, o OCR no aparelho e a leitura por
    /// IA do servidor.
    ///
    /// - Returns: aviso para mostrar ao usuário quando a leitura do servidor falha
    ///   ou a assinatura barra; `nil` em sucesso, cancelamento ou sem consentimento.
    @MainActor
    static func ler(
        _ imagem: UIImage,
        acesso: AssinaturaViewModel = .shared,
        lerLocal: (UIImage) async -> GastoLocalExtraido = {
            await ComprovanteOCRLocal.extrair(de: $0)
        },
        extrair: (Data) async throws -> GastoExtraidoResponse = {
            try await NetworkManager.shared.extrairGastoDeImagem(imageData: $0)
        },
        aplicar: @MainActor (_ titulo: String?, _ valor: Decimal?, _ categoria: Categoria?) -> Void
    ) async -> String? {
        guard Consentimento.leituraAutomatica == true else { return nil }
        // §3.5: sem acesso conhecido a leitura por IA não roda — abre os planos.
        guard acesso.exigirAcesso() else { return avisoAssinatura }
        guard let dadosOCR = NotaFiscal.comprimirParaOCR(imagem) else { return nil }

        let local = await lerLocal(imagem)
        let teveLeituraLocal = local.temAlgoUtil
        if teveLeituraLocal {
            aplicar(local.titulo, local.valor, local.categoria)
        }
        guard !Task.isCancelled else { return nil }

        do {
            let resultado = try await extrair(dadosOCR)
            guard !Task.isCancelled else { return nil }
            aplicar(resultado.titulo, resultado.valor, resultado.categoria)
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            // 403 `subscription_required` direto: planos, não "Erro no servidor".
            if acesso.tratarErroDeAcesso(error) { return avisoAssinatura }
            logger.error("Erro ao extrair gasto: \(error.localizedDescription, privacy: .public)")
            return teveLeituraLocal
                ? "Leitura feita no aparelho. Confira os valores antes de salvar."
                : "Não foi possível ler o comprovante. Preencha os campos."
        }
    }
}

// MARK: - Rascunho do gasto

/// Estado e ações do gasto sendo lançado ou editado (tela 10), sem visual.
///
/// Salva com as mesmas funções do `CiclosViewModel` (SwiftData primeiro,
/// sincronização em segundo plano); o comprovante sobe depois que o gasto existe.
@MainActor
@Observable
final class RascunhoGasto {
    enum Campo: Hashable { case titulo, valor, categoria }

    var titulo: String = ""
    var valorTexto: String = ""
    var categoria: Categoria = .ALIMENTACAO
    var dia: DiaSoftex?
    /// Hora mostrada: a do gasto em edição, ou a hora de agora.
    var criadoEm: Date = .now

    var imagem: UIImage?
    var dadosComprovante: Data?
    var mime: String = "image/jpeg"
    var urlSalva: String?
    /// O gasto em edição já tinha comprovante (enviado ou pendente de envio).
    private(set) var comprovanteSalvo = false
    var removerSalvo = false

    var lendo = false
    /// Algum resultado da leitura já preencheu os campos.
    var leuComprovante = false
    var aviso: String?
    var salvando = false

    private(set) var camposEditados: Set<Campo> = []
    private(set) var gastoId: UUID?
    /// Valor e dia do gasto antes da edição (já contados no resumo do dia).
    private(set) var valorOriginal: Decimal = 0
    private(set) var diaOriginal: DiaSoftex?
    private var tarefaLeitura: Task<Void, Never>?

    var editando: Bool { gastoId != nil }
    /// "43,10" ou "43.10" (teclado decimal em inglês) → 43.10, arredondado a 2 casas. Inválido = 0.
    var valor: Decimal { lerValorDigitado(valorTexto) ?? 0 }

    var temComprovante: Bool {
        dadosComprovante != nil || imagem != nil || (comprovanteSalvo && !removerSalvo)
    }

    var comprovanteEhPdf: Bool {
        mime == "application/pdf" || (dadosComprovante == nil && (urlSalva?.contains(".pdf") ?? false))
    }

    var podeSalvar: Bool {
        !titulo.trimmingCharacters(in: .whitespaces).isEmpty && valor > 0 && dia != nil && !salvando
    }

    init(dia: DiaSoftex?) {
        self.dia = dia
    }

    init(editando gasto: GastosDia) {
        gastoId = gasto.id
        titulo = gasto.titulo
        valorTexto = textoValorBRL(gasto.valor)
        categoria = gasto.categoria
        dia = gasto.dia
        valorOriginal = gasto.valor
        diaOriginal = gasto.dia
        criadoEm = gasto.criadoEm
        mime = gasto.comprovanteMime
        // Remoção pendente de sync (feita offline): o comprovante já não conta.
        comprovanteSalvo = temComprovanteValido(gasto)
        urlSalva = comprovanteSalvo ? gasto.comprovanteUrl : nil
        if comprovanteSalvo, let dados = gasto.comprovanteData {
            // Comprovante local ainda não enviado: mostra a miniatura.
            imagem = UIImage(data: dados)
        }
    }

    /// Edição feita pelo usuário: a leitura não sobrescreve mais esse campo.
    func marcarEditado(_ campo: Campo) {
        camposEditados.insert(campo)
    }

    // MARK: Comprovante

    /// Anexa a foto (resolução original) e, se `ler` e houver consentimento,
    /// preenche os campos com a leitura.
    func receberImagem(_ nova: UIImage, ler: Bool) {
        imagem = nova
        dadosComprovante = NotaFiscal.codificar(nova)
        mime = "image/jpeg"
        removerSalvo = false
        guard ler, Consentimento.leituraAutomatica == true else { return }
        iniciarLeitura(nova)
    }

    /// Imagem ou PDF escolhido em Arquivos (PDF não passa pela leitura).
    func receberArquivo(_ url: URL, ler: Bool) {
        switch NotaFiscal.abrir(url) {
        case .pdf(let dados):
            dadosComprovante = dados
            mime = "application/pdf"
            imagem = nil
            removerSalvo = false
        case .imagem(let nova):
            receberImagem(nova, ler: ler)
        case .erro(let mensagem):
            aviso = mensagem
        }
    }

    func removerComprovante() {
        if imagem != nil || dadosComprovante != nil {
            imagem = nil
            dadosComprovante = nil
            mime = "image/jpeg"
        }
        if comprovanteSalvo {
            removerSalvo = true
        }
    }

    private func iniciarLeitura(_ foto: UIImage) {
        tarefaLeitura?.cancel()
        lendo = true
        aviso = nil
        tarefaLeitura = Task { [weak self] in
            let aviso = await LeituraComprovante.ler(foto) { titulo, valor, categoria in
                self?.aplicar(titulo: titulo, valor: valor, categoria: categoria)
            }
            guard let self, !Task.isCancelled else { return }
            self.aviso = aviso
            self.lendo = false
        }
    }

    func cancelarLeitura() {
        tarefaLeitura?.cancel()
        tarefaLeitura = nil
        lendo = false
    }

    private func aplicar(titulo: String?, valor: Decimal?, categoria: Categoria?) {
        if let titulo, !titulo.isEmpty, !camposEditados.contains(.titulo) {
            self.titulo = titulo
            leuComprovante = true
        }
        if let valor, valor > 0, !camposEditados.contains(.valor) {
            valorTexto = textoValorBRL(valor)
            leuComprovante = true
        }
        if let categoria, !camposEditados.contains(.categoria) {
            self.categoria = categoria
        }
    }

    // MARK: Salvar

    /// Marca o salvamento como em andamento. `false` se já estava salvando ou
    /// se ainda não dá para salvar: o segundo toque é ignorado.
    func iniciarSalvamento() -> Bool {
        guard podeSalvar else { return false }
        salvando = true
        return true
    }

    /// Cria ou edita o gasto com as funções de hoje do `CiclosViewModel`.
    /// O `CiclosViewModel` precisa estar apontado para o ciclo do dia (`garantirAtual`).
    ///
    /// Quem chama deve usar `iniciarSalvamento()` de forma síncrona antes de
    /// criar a `Task`, para que dois toques seguidos não criem dois gastos.
    func salvar(em viewModel: CiclosViewModel) async throws {
        salvando = true
        defer { salvando = false }
        guard let dia else { return }
        cancelarLeitura()
        let titulo = self.titulo.trimmingCharacters(in: .whitespaces)

        if let gastoId {
            try await viewModel.editGasto(gastoId: gastoId, novoDia: dia, titulo: titulo,
                                          value: valor, categoria: categoria)
            do {
                if let dadosComprovante {
                    try await viewModel.anexarComprovante(gastoId: gastoId, imageData: dadosComprovante, mime: mime)
                } else if removerSalvo {
                    try await viewModel.removerComprovante(gastoId: gastoId)
                }
            } catch {
                // O gasto já foi salvo; só o comprovante falhou.
                throw FalhaComprovante(causa: error)
            }
        } else {
            try await viewModel.createNewGasto(title: titulo, value: valor, dia: dia, categoria: categoria,
                                               comprovante: dadosComprovante, comprovanteMime: mime)
        }
    }
}

/// A edição do gasto foi salva, mas anexar ou remover o comprovante falhou.
struct FalhaComprovante: Error {
    let causa: Error
}

/// O gasto tem comprovante que vale: enviado ou pendente de envio, e sem
/// remoção pendente (`comprovanteParaRemover`, feita offline).
func temComprovanteValido(_ gasto: GastosDia) -> Bool {
    !gasto.comprovanteParaRemover && (gasto.comprovanteUrl != nil || gasto.comprovanteDataCriptografado != nil)
}
