import SwiftUI

/// Nome e e-mail mostrados no avatar e no menu.
struct UsuarioMenu: Equatable {
    let nome: String
    let email: String

    /// "João Victor Farhat" → "JO" (duas primeiras letras do nome, como já era).
    var iniciais: String {
        let letras = nome.trimmingCharacters(in: .whitespaces).prefix(2).uppercased()
        return letras.isEmpty ? "?" : letras
    }
}

/// Círculo com as iniciais. Aberto (menu visível) fica cheio em roxo.
struct AvatarIniciais: View {
    let usuario: UsuarioMenu
    var destacado: Bool = false
    var tamanho: CGFloat = 40

    @ScaledMetric(relativeTo: .footnote) private var escala: CGFloat = 1

    var body: some View {
        Text(usuario.iniciais)
            .font(.system(size: tamanho * 0.3, weight: .bold))
            .foregroundStyle(destacado ? Tema.sobreCor : Tema.texto)
            .frame(width: tamanho * escala, height: tamanho * escala)
            .background(destacado ? Tema.marcaBotao : Tema.superficie, in: Circle())
    }
}

/// Menu do avatar (tela 7): substitui a barra de abas.
///
/// Sem "Cartão corporativo": o Open Finance só aparece com `GET /api/features`
/// dizendo `open_finance: true`, e esta versão ainda não tem a checagem
/// (sem resposta = desligado). "Ambiente API" só em build de desenvolvimento.
struct MenuAvatar: View {
    let usuario: UsuarioMenu
    /// Viagem que "Fechar viagem e PDF" abre; sem viagem o item some.
    let aoEscolher: (Rota) -> Void
    let aoSair: () -> Void

    #if DEBUG
    @State private var ambiente: APIEnvironment = APIConfig.shared.current
    #endif

    var body: some View {
        VStack(spacing: 0) {
            cabecalho
            divisoria
            // Viagens e Gastos estão na barra de abas; Fechar viagem, no início e em Viagens (10/11).
            item("Perfil e ajustes", simbolo: "gearshape") { aoEscolher(.perfil) }
            #if DEBUG
            if !CommandLine.arguments.contains("-demo") {
                divisoria
                ambienteAPI
            }
            #endif
            divisoria
            Button(action: aoSair) {
                linha(titulo: "Sair", simbolo: "rectangle.portrait.and.arrow.right", cor: Tema.estouro, seta: false)
            }
            .buttonStyle(.plain)
        }
        .background {
            // Sombra só na forma do cartão (no VStack ela vazaria para cada texto).
            RoundedRectangle(cornerRadius: Raio.lista + 4, style: .continuous)
                .fill(Tema.superficie)
                .shadow(color: .black.opacity(0.12), radius: 15, y: 10)
        }
    }

    private var cabecalho: some View {
        HStack(spacing: Espaco.m + 4) {
            Text(usuario.iniciais)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Tema.marcaTexto)
                .frame(width: 48, height: 48)
                .background(Tema.marcaFundo, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(usuario.nome.isEmpty ? "Usuário" : usuario.nome)
                    .font(.headline)
                    .foregroundStyle(Tema.texto)
                    .lineLimit(1)
                if !usuario.email.isEmpty {
                    Text(usuario.email)
                        .font(.subheadline)
                        .foregroundStyle(Tema.textoFraco)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Espaco.g + 2)
        .padding(.vertical, Espaco.g)
        .accessibilityElement(children: .combine)
    }

    private var divisoria: some View {
        Rectangle().fill(Tema.borda).frame(height: 0.5)
    }

    private func item(_ titulo: String, simbolo: String, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            linha(titulo: titulo, simbolo: simbolo, cor: Tema.texto, seta: true)
        }
        .buttonStyle(.plain)
    }

    private func linha(titulo: String, simbolo: String, cor: Color, seta: Bool) -> some View {
        HStack(spacing: Espaco.g) {
            Image(systemName: simbolo)
                .font(.body)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(titulo)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: Espaco.p)
            if seta {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tema.textoFraco)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(cor)
        .padding(.horizontal, Espaco.g + 2)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    #if DEBUG
    private var ambienteAPI: some View {
        VStack(alignment: .leading, spacing: Espaco.p) {
            Text("Ambiente API (só em desenvolvimento)")
                .font(.footnote)
                .foregroundStyle(Tema.textoFraco)
            Picker("Ambiente API", selection: $ambiente) {
                ForEach(APIEnvironment.allCases, id: \.self) { env in
                    Text(env.displayName).tag(env)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: ambiente) { _, novo in
                APIConfig.shared.current = novo
            }
        }
        .padding(.horizontal, Espaco.g + 2)
        .padding(.vertical, Espaco.m)
    }
    #endif
}
