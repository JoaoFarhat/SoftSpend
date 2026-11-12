import SwiftUI

/// Estado de envio de um gasto ao servidor, derivado de `syncStatus` e
/// `syncError`. `de(_:)` é só leitura: nunca muta o `@Model`, então pode ser
/// chamado no `body` da view (armadilha 2 do `AGENTS.md`).
nonisolated enum EstadoEnvio: Equatable, Sendable {
    /// Chegou no servidor.
    case enviado
    /// Na fila: nunca enviado, enviando agora ou com mudança local nova.
    case aguardando
    /// A última tentativa falhou (o texto é o `syncError`); a fila ainda tenta de novo.
    case falhou(String)
    /// Falha final por 404 (T4) gravada por versões anteriores: o dia/a viagem
    /// (ou o próprio gasto) foi apagado em outro aparelho. Hoje esse gasto é
    /// descartado no começo do próximo `sync`; o caso só cobre o intervalo até lá.
    case apagadoEmOutroAparelho

    static func de(_ gasto: GastosDia) -> EstadoEnvio {
        // O texto fixo do `syncError` é o identificador da falha final por 404.
        if gasto.syncError == SyncActor.erroApagadoEmOutroAparelho {
            return .apagadoEmOutroAparelho
        }
        switch gasto.syncStatus {
        case .synced: return .enviado
        case .failed: return .falhou(gasto.syncError ?? "Não foi possível enviar")
        case .pending, .syncing: return .aguardando
        }
    }
}

nonisolated extension EstadoEnvio {
    /// SF Symbol do indicador nas listas; `nil` quando enviado (nada a mostrar).
    var simbolo: String? {
        switch self {
        case .enviado: nil
        case .aguardando: "icloud.slash"
        case .falhou, .apagadoEmOutroAparelho: "exclamationmark.triangle"
        }
    }

    /// Frase do VoiceOver; `nil` quando enviado (nada a dizer).
    var rotuloAcessivel: String? {
        switch self {
        case .enviado: nil
        case .aguardando: "Aguardando envio"
        case .falhou: "Falha ao enviar"
        case .apagadoEmOutroAparelho: SyncActor.erroApagadoEmOutroAparelho
        }
    }

    /// Texto do estado na linha "Envio" do detalhe do gasto.
    var rotulo: String {
        switch self {
        case .enviado: "Enviado"
        case .aguardando: "Aguardando envio"
        case .falhou: "Falha ao enviar"
        case .apagadoEmOutroAparelho: "Apagado em outro aparelho"
        }
    }

    /// Detalhe da falha (o `syncError`) mostrado embaixo do `rotulo` no detalhe.
    var detalhe: String? {
        switch self {
        case .falhou(let erro): erro
        case .apagadoEmOutroAparelho: SyncActor.erroApagadoEmOutroAparelho
        case .enviado, .aguardando: nil
        }
    }
}

/// "1 alteração aguardando envio" / "N alterações aguardando envio" (aviso da `MainView`).
nonisolated func textoAlteracoesAguardando(_ quantidade: Int) -> String {
    quantidade == 1 ? "1 alteração aguardando envio" : "\(quantidade) alterações aguardando envio"
}

/// Ícone pequeno que marca o gasto ainda não enviado: `icloud.slash`
/// aguardando, triângulo nas falhas. Nada quando enviado.
struct IconeEstadoEnvio: View {
    let estado: EstadoEnvio

    var body: some View {
        if let simbolo = estado.simbolo {
            Image(systemName: simbolo)
                .font(.caption)
                .foregroundStyle(cor)
                .accessibilityLabel(estado.rotuloAcessivel ?? "")
        }
    }

    private var cor: Color {
        switch estado {
        case .enviado, .aguardando: Tema.textoFraco
        case .falhou, .apagadoEmOutroAparelho: Tema.alertaTexto
        }
    }
}
