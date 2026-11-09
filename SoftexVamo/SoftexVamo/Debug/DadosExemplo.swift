#if DEBUG
import SwiftUI
import SwiftData

/// Viagem de exemplo do spec (Cuiabá, 20 a 25/07/2026, R$ 2.700, diária R$ 450,
/// "hoje" = 23/07) num banco em memória. Só para vitrine e previews.
final class DadosExemplo {
    static let compartilhado = DadosExemplo()

    let container: ModelContainer
    let ciclo: CicloSoftex
    /// Viagens anteriores (Porto Alegre em junho, Recife em abril), para a tela de Viagens.
    private(set) var anteriores: [CicloSoftex] = []
    let calendario: Calendar = .current
    let periodo = "20 a 25 de julho"

    /// "Hoje" fixo da viagem de exemplo: 23/07/2026, meio-dia.
    var hoje: Date { dia(23) }

    func dia(_ n: Int, _ hora: Int = 12, _ minuto: Int = 0) -> Date {
        calendario.date(from: DateComponents(year: 2026, month: 7, day: n, hour: hora, minute: minuto))!
    }

    func resumo(hoje: Date? = nil) -> ResumoViagem {
        ResumoViagem(ciclo: ciclo, hoje: hoje ?? self.hoje, calendario: calendario)
    }

    /// Gastos do dia de hoje (23/07), do mais recente para o mais antigo.
    var gastosDeHoje: [GastosDia] {
        let hojeInicio = calendario.startOfDay(for: hoje)
        let diaHoje = (ciclo.dias ?? []).first { calendario.startOfDay(for: $0.data) == hojeInicio }
        return (diaHoje?.gastos ?? []).sorted { $0.criadoEm > $1.criadoEm }
    }

    private init() {
        container = try! ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let diaria: Decimal = 450
        ciclo = CicloSoftex(valor_total: 2700, gasto_total: 0, periodo: "20/07 - 25/07",
                            diaria: diaria, titulo: "Cuiabá, MT", dias: [])
        ctx.insert(ciclo)

        var dias: [Int: DiaSoftex] = [:]
        for n in 20...25 {
            let d = DiaSoftex(data: dia(n, 0), saldo: diaria)
            ctx.insert(d)
            d.ciclo = ciclo
            dias[n] = d
        }

        // (dia, hora, minuto, título, valor, categoria, tem foto)
        let lancamentos: [(Int, Int, Int, String, String, Categoria, Bool)] = [
            (20, 9, 10, "Táxi até o hotel", "88.00", .TRANSPORTE, true),
            (20, 13, 5, "Almoço", "162.00", .ALIMENTACAO, true),
            (20, 20, 30, "Jantar", "180.00", .ALIMENTACAO, true),
            (21, 12, 40, "Almoço", "72.40", .ALIMENTACAO, true),
            (21, 18, 15, "Uber", "100.00", .TRANSPORTE, true),
            (21, 21, 0, "Jantar com a equipe", "315.60", .ALIMENTACAO, true),
            (22, 12, 20, "Almoço", "55.70", .ALIMENTACAO, true),
            (22, 17, 45, "Farmácia", "36.30", .COMPRAS, false),
            (22, 20, 10, "Jantar com cliente", "320.00", .ALIMENTACAO, true),
            (23, 8, 5, "Táxi aeroporto", "104.60", .TRANSPORTE, false),
            (23, 13, 42, "Spoleto", "43.10", .ALIMENTACAO, true),
        ]
        for (n, hora, minuto, titulo, valor, categoria, foto) in lancamentos {
            let g = GastosDia(valor: Decimal(string: valor)!, titulo: titulo, categoria: categoria,
                              dia: dias[n], comprovanteUrl: foto ? "https://exemplo.invalid/\(n)-\(hora).jpg" : nil)
            ctx.insert(g)
            g.criadoEm = dia(n, hora, minuto)
        }
        ciclo.gasto_total = lancamentos.reduce(0) { $0 + Decimal(string: $1.4)! }

        // (título, mês, primeiro dia, último dia, total, gasto)
        let passadas: [(String, Int, Int, Int, Decimal, Decimal)] = [
            ("Porto Alegre, RS", 6, 2, 6, 2250, 1640),
            ("Recife, PE", 4, 14, 19, 2700, 2115),
        ]
        var anteriores: [CicloSoftex] = []
        for (titulo, mes, ini, fim, total, gasto) in passadas {
            let n = fim - ini + 1
            let c = CicloSoftex(valor_total: total, gasto_total: gasto,
                                periodo: String(format: "%02d/%02d - %02d/%02d", ini, mes, fim, mes),
                                diaria: total / Decimal(n), titulo: titulo, dias: [])
            ctx.insert(c)
            for d in ini...fim {
                let data = calendario.date(from: DateComponents(year: 2026, month: mes, day: d))!
                let dia = DiaSoftex(data: data, saldo: total / Decimal(n))
                ctx.insert(dia)
                dia.ciclo = c
            }
            anteriores.append(c)
        }
        self.anteriores = anteriores
        try? ctx.save()
    }
}

extension DadosExemplo {
    /// Foto de exemplo do comprovante do Spoleto (papel pautado), para as capturas.
    @MainActor
    static func imagemComprovante() -> UIImage {
        let linhas = ["SPOLETO CUIABÁ", "23/07/2026 13:42", "-------------------", "PRATO DO DIA 38,90",
                      "SUCO 4,20", "-------------------", "TOTAL R$ 43,10"]
        let papel = ZStack(alignment: .topLeading) {
            Color(red: 0.914, green: 0.906, blue: 0.886)
            VStack(spacing: 0) {
                ForEach(0..<36, id: \.self) { _ in
                    Color.clear.frame(height: 15)
                    Color(red: 0.863, green: 0.851, blue: 0.824).frame(height: 1.5)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(linhas, id: \.self) { Text($0) }
            }
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(Color(white: 0.2))
            .padding(28)
        }
        .frame(width: 400, height: 600, alignment: .topLeading)
        .clipped()
        let renderer = ImageRenderer(content: papel)
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }
}
#endif
