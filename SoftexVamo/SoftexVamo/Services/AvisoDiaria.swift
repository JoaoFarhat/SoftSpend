import Foundation
import UserNotifications
import os

/// "Segunda", "Terça", ..., sempre em português.
nonisolated func diaDaSemana(_ data: Date, calendario: Calendar = .current) -> String {
    let nomes = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"]
    let indice = calendario.component(.weekday, from: data) - 1
    return nomes.indices.contains(indice) ? nomes[indice] : ""
}

/// Aviso local de diária (tela 13): ao chegar a 80% da diária do dia e ao
/// passar dela. No máximo um de cada por dia (chaves guardadas em `UserDefaults`).
enum AvisoDiaria: Equatable {
    case oitentaPorCento(livre: Decimal, data: Date)
    case passou(valor: Decimal, data: Date)

    /// Preferência "Avisos de diária" (Ajustes, Tarefa 9). Ausente = ligada.
    static let chaveAtivos = "avisosDiariaAtivos"
    /// Chaves dos avisos já enviados ("80-yyyy-MM-dd", "passou-yyyy-MM-dd").
    static let chaveEnviados = "avisosDiariaEnviados"

    private static let logger = Logger(subsystem: "br.com.softspend", category: "AvisoDiaria")

    // MARK: Regra

    /// Avisos que o gasto de hoje pede e que ainda não foram dados hoje.
    /// Passar da diária também conta como ter chegado a 80% (as duas chaves são gravadas).
    static func avaliar(gastoHoje: Decimal, diaria: Decimal, jaAvisados: Set<String>, hoje: Date) -> [AvisoDiaria] {
        guard diaria > 0 else { return [] }
        var avisos: [AvisoDiaria] = []
        let oitenta = AvisoDiaria.oitentaPorCento(livre: max(0, diaria - gastoHoje), data: hoje)
        if gastoHoje * 10 >= diaria * 8, !jaAvisados.contains(oitenta.chave) {
            avisos.append(oitenta)
        }
        let passou = AvisoDiaria.passou(valor: gastoHoje - diaria, data: hoje)
        if gastoHoje > diaria, !jaAvisados.contains(passou.chave) {
            avisos.append(passou)
        }
        return avisos
    }

    var data: Date {
        switch self {
        case .oitentaPorCento(_, let data), .passou(_, let data): return data
        }
    }

    /// "yyyy-MM-dd" no calendário gregoriano e no fuso atual, qualquer que seja
    /// o calendário ou o idioma do aparelho (budista, árabe...).
    private static let formatoChave: DateFormatter = {
        let f = DateFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .autoupdatingCurrent
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var chave: String {
        let dia = Self.formatoChave.string(from: data)
        switch self {
        case .oitentaPorCento: return "80-\(dia)"
        case .passou: return "passou-\(dia)"
        }
    }

    /// Título e texto da notificação, como na tela 13.
    func conteudo(cidade: String, diaria: Decimal) -> (titulo: String, corpo: String) {
        switch self {
        case .oitentaPorCento(let livre, _):
            return ("Você usou 80% da diária de hoje",
                    "Ainda dá para gastar \(formatarBRL(livre)) em \(cidade).")
        case .passou(let valor, let data):
            return ("Passou \(formatarBRL(valor)) da diária",
                    "\(diaDaSemana(data)), \(dataCurta(data)). Os próximos dias continuam com \(formatarBRLCurto(diaria)).")
        }
    }

    // MARK: Preferências

    static func ativos(em defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: chaveAtivos) as? Bool ?? true
    }

    static func avisados(em defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: chaveEnviados) ?? [])
    }

    /// Grava as chaves, guardando só as dos últimos 60 dias.
    static func registrar(_ chaves: Set<String>, em defaults: UserDefaults = .standard) {
        let todas = avisados(em: defaults).union(chaves)
        let recentes = todas.sorted { $0.suffix(10) > $1.suffix(10) }.prefix(120)
        defaults.set(Array(recentes), forKey: chaveEnviados)
    }

    // MARK: Disparo

    /// Confere o dia de hoje do ciclo depois de salvar ou editar um gasto de hoje
    /// e agenda os avisos que faltam. Não faz nada com a preferência desligada.
    @MainActor
    static func verificar(ciclo: CicloSoftex, hoje: Date, defaults: UserDefaults = .standard) {
        guard ativos(em: defaults) else { return }
        let resumo = ResumoViagem(ciclo: ciclo, hoje: hoje)
        guard case .durante = resumo.estado else { return }
        let avisos = avaliar(gastoHoje: resumo.gastoHoje, diaria: resumo.diaria,
                             jaAvisados: avisados(em: defaults), hoje: hoje)
        guard !avisos.isEmpty else { return }
        registrar(Set(avisos.map(\.chave)), em: defaults)

        // Chegou direto acima da diária: o "ainda dá para gastar R$ 0,00" não ajuda,
        // vai só o de passou (a chave dos 80% fica gravada mesmo assim).
        let passou = avisos.contains { if case .passou = $0 { true } else { false } }
        let enviar = passou ? avisos.filter { if case .passou = $0 { true } else { false } } : avisos
        let cidade = nomeCidade(ciclo.titulo)
        let diaria = resumo.diaria
        Task {
            for aviso in enviar {
                await agendar(aviso, cidade: cidade, diaria: diaria)
            }
        }
    }

    /// Mostra a notificação na hora. Pede a permissão na primeira vez.
    static func agendar(_ aviso: AvisoDiaria, cidade: String, diaria: Decimal) async {
        let central = UNUserNotificationCenter.current()
        let status = await central.notificationSettings().authorizationStatus
        if status == .notDetermined {
            let permitiu = (try? await central.requestAuthorization(options: [.alert, .sound])) ?? false
            guard permitiu else { return }
        } else if status == .denied {
            return
        }

        let (titulo, corpo) = aviso.conteudo(cidade: cidade, diaria: diaria)
        let conteudo = UNMutableNotificationContent()
        conteudo.title = titulo
        conteudo.body = corpo
        conteudo.sound = .default
        let pedido = UNNotificationRequest(identifier: aviso.chave, content: conteudo, trigger: nil)
        do {
            try await central.add(pedido)
        } catch {
            logger.error("Falha ao agendar aviso de diária: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Mostra os avisos de diária também com o app aberto (é quando o gasto é salvo).
final class AvisosNotificacaoDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let compartilhado = AvisosNotificacaoDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
