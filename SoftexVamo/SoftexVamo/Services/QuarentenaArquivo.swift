//
//  QuarentenaArquivo.swift
//  SoftexVamo
//
//  Nome e poda dos `.corrompido-*` das listas JSON fora do SwiftData
//  (ComprasAguardandoViagem e CartoesApplePay).
//

import Foundation

/// Regra compartilhada do nome e do teto dos `.corrompido-*`: a cópia do
/// JSON ilegível que fica guardada, recuperável, em vez de sobrescrita.
nonisolated enum QuarentenaArquivo {
    /// Quantas cópias ficam guardadas; a poda apaga as mais velhas. Um
    /// arquivo que corrompe sempre não pode encher o disco.
    static let maximoGuardadas = 5

    /// Destino único `<arquivo>.corrompido-<yyyyMMdd-HHmmss>-<uuid8>`. Só o
    /// carimbo de segundo fazia dois corrompidos no mesmo segundo darem
    /// `moveItem` num destino já existente, e o erro subia para a ação
    /// ("lance no app") sem motivo. `agora` entra por parâmetro para o
    /// teste provar a unicidade com o carimbo igual.
    static func destino(para arquivo: URL, em agora: Date) -> URL {
        arquivo.appendingPathExtension(
            "corrompido-\(carimbo.string(from: agora))-\(uuidCurto())")
    }

    /// Apaga os `.corrompido-*` de `arquivo` além dos `maximoGuardadas`
    /// mais novos — o carimbo no nome já ordena do mais velho para o mais
    /// novo. Falha na poda não derruba a quarentena: o pior caso é sobrar
    /// cópia velha. Chamada depois do `moveItem`, sob a trava de quem usa.
    static func podar(de arquivo: URL) {
        let pasta = arquivo.deletingLastPathComponent()
        guard let nomes = try? FileManager.default.contentsOfDirectory(atPath: pasta.path)
        else { return }
        let prefixo = "\(arquivo.lastPathComponent).corrompido-"
        for nome in nomes.filter({ $0.hasPrefix(prefixo) }).sorted().dropLast(maximoGuardadas) {
            try? FileManager.default.removeItem(at: pasta.appendingPathComponent(nome))
        }
    }

    private static let carimbo: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func uuidCurto() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    }
}
