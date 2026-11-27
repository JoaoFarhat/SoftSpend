import Testing
import Foundation
import SwiftData
@testable import SoftSpend

/// `docs/data-do-dia.md` (app): o dia da viagem trafega como data de calendário
/// (`data_local`, `"yyyy-MM-dd"`), não só como instante. O `DiaLoteRequest`
/// leva o texto dos componentes do `Calendar.current`, e a resposta com
/// `data_local` reconstrói `DiaSoftex.data` como o início daquele dia no fuso
/// do aparelho — dois aparelhos em fusos diferentes concordam sobre qual é o
/// dia (sem `data_local`, a meia-noite de Paris cai no dia anterior em fusos
/// adiantados). Os testes usam calendários de fuso fixo, para não dependerem
/// do fuso do CI.
@MainActor
struct DiaDoCalendarioTests {
    let container: ModelContainer
    let api = FakeSyncAPI()
    let userId = "usuario-teste"

    /// Paris (UTC+2 em julho), São Paulo (UTC−3) e Auckland (UTC+12 em julho):
    /// a "meia-noite local de 21/07" é um instante diferente em cada um, mas a
    /// mesma data de calendário.
    static func calendario(_ fuso: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: fuso)!
        return cal
    }
    let paris = calendario("Europe/Paris")
    let saoPaulo = calendario("America/Sao_Paulo")
    let auckland = calendario("Pacific/Auckland")

    init() throws {
        container = try ModelContainer(
            for: CicloSoftex.self, DiaSoftex.self, GastosDia.self,
            configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
        )
    }

    // MARK: Apoio

    func meiaNoite(de dia: Int, no cal: Calendar) throws -> Date {
        try #require(cal.date(from: DateComponents(year: 2026, month: 7, day: dia)))
    }

    func diasLocais() throws -> [DiaSoftex] {
        try ModelContext(container).fetch(FetchDescriptor<DiaSoftex>())
    }

    func sync() async -> Int {
        await SyncActor(modelContainer: container, api: api).sync(agora: .now, userId: userId)
    }

    // MARK: texto(de:)

    /// A meia-noite local de 21/07 é um instante diferente em cada fuso — é por
    /// isso que o instante sozinho não diz qual é o dia — mas `texto(de:)`
    /// devolve a mesma `"2026-07-21"` nos três.
    @Test func textoDevolveAMesmaDataNosTresFusos() throws {
        var instantes = Set<Date>()
        for cal in [paris, saoPaulo, auckland] {
            let meiaNoite = try self.meiaNoite(de: 21, no: cal)
            instantes.insert(meiaNoite)
            #expect(DiaDoCalendario.texto(de: meiaNoite, calendario: cal) == "2026-07-21")
        }
        #expect(instantes.count == 3)
    }

    /// Não é só o `startOfDay`: qualquer instante daquele dia local vira o texto.
    @Test func textoIgnoraAHoraDoInstante() throws {
        let tarde = try #require(saoPaulo.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 23, minute: 59)))
        #expect(DiaDoCalendario.texto(de: tarde, calendario: saoPaulo) == "2026-07-21")
    }

    // MARK: inicioDoDia(de:)

    /// `inicioDoDia` devolve a meia-noite local do calendário passado — o mesmo
    /// `"2026-07-21"` vira três instantes diferentes, um por fuso.
    @Test func inicioDoDiaVoltaAMeiaNoiteLocal() throws {
        for cal in [paris, saoPaulo, auckland] {
            let esperado = try self.meiaNoite(de: 21, no: cal)
            #expect(DiaDoCalendario.inicioDoDia(de: "2026-07-21", calendario: cal) == esperado)
        }
        // 29/02 de ano bissexto é data válida.
        #expect(DiaDoCalendario.inicioDoDia(de: "2024-02-29", calendario: paris) != nil)
    }

    /// Texto fora do formato (ou data normalizada, como 30/02) devolve `nil`
    /// em vez de derrubar a decodificação da resposta.
    @Test func inicioDoDiaRecusaTextoForaDoFormato() {
        for invalido in ["21/07/2026", "2026-7-21", "2026-13-01", "2026-02-30",
                         "hoje", "2026-07-21T00:00:00Z", ""] {
            #expect(DiaDoCalendario.inicioDoDia(de: invalido, calendario: paris) == nil)
        }
    }

    // MARK: Recebimento (DiaSoftex from: DiaSoftexResponse)

    /// O dia foi criado em Paris: `data` é a meia-noite de lá (22:00Z do dia
    /// 20). Com `data_local`, um aparelho em Auckland reconstrói `dia.data`
    /// como a meia-noite de Auckland do dia 21 — os dois aparelhos concordam
    /// sobre qual é o dia. Sem a conversão, o instante de Paris lido em
    /// Auckland apareceria como 21/07 ao meio-dia e a comparação de "mesmo
    /// dia" com outros dias poderia escorregar.
    @Test func respostaComDataLocalReconstroiNoFusoDoAparelho() throws {
        let meiaNoiteParis = try self.meiaNoite(de: 21, no: paris)
        let dto = DiaSoftexResponse(
            id: 1, clientId: "c1", data: meiaNoiteParis, dataLocal: "2026-07-21",
            saldo: 100, gastos: nil
        )
        let dia = DiaSoftex(from: dto, calendario: auckland)
        let meiaNoiteAuckland = try self.meiaNoite(de: 21, no: auckland)
        #expect(dia.data == meiaNoiteAuckland)
        #expect(dia.data != meiaNoiteParis)
    }

    /// Resposta sem `data_local` (servidor antigo): `data` vale como antes, e
    /// `data_local` ilegível cai no mesmo fallback em vez de zerar a data.
    @Test func respostaSemDataLocalUsaOInstante() throws {
        let meiaNoiteParis = try self.meiaNoite(de: 21, no: paris)
        let sem = DiaSoftexResponse(
            id: 1, clientId: "c1", data: meiaNoiteParis, dataLocal: nil,
            saldo: 100, gastos: nil
        )
        #expect(DiaSoftex(from: sem, calendario: auckland).data == meiaNoiteParis)
        let ilegivel = DiaSoftexResponse(
            id: 1, clientId: "c1", data: meiaNoiteParis, dataLocal: "nao-e-data",
            saldo: 100, gastos: nil
        )
        #expect(DiaSoftex(from: ilegivel, calendario: auckland).data == meiaNoiteParis)
    }

    // MARK: Envio e correção pelo sync

    /// Dia guardado fora de meia-noite local (criado por versão antiga, ou com
    /// o aparelho em outro fuso na criação): o `postDiasLote` leva o
    /// `data_local` do dia e a resposta — que o servidor devolve com o mesmo
    /// `data_local` — corrige `dia.data` para o início do dia no fuso do
    /// aparelho. A correção não conta como mudança do usuário (a foto é
    /// comparada antes de aplicá-la), então o dia sobe num envio só.
    @Test func syncCorrigeDataPeloDataLocalDaResposta() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 100, gasto_total: 0,
            periodo: "21/07 - 21/07", diaria: 100, titulo: "Paris", dias: []
        )
        ctx.insert(ciclo)
        let foraDeMeiaNoite = Calendar.current.startOfDay(for: .now).addingTimeInterval(3600)
        let dia = DiaSoftex(data: foraDeMeiaNoite, saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        try ctx.save()

        let inicioEsperado = Calendar.current.startOfDay(for: foraDeMeiaNoite)
        let dataLocalEsperado = DiaDoCalendario.texto(de: foraDeMeiaNoite)
        #expect(inicioEsperado != foraDeMeiaNoite)

        #expect(await sync() == 0)

        // Um envio só, com o data_local do dia; o servidor o gravou.
        #expect(api.chamadas == [.postCiclo, .postDiasLote])
        for lote in api.lotesDias {
            #expect(lote.allSatisfy { $0.dataLocal == dataLocalEsperado })
        }
        #expect(api.dias.allSatisfy { $0.dataLocal == dataLocalEsperado })

        let gravado = try #require(try diasLocais().first)
        #expect(gravado.data == inicioEsperado)
        #expect(gravado.syncStatus == .synced)
        #expect(gravado.backendId != nil)
    }

    /// Edição feita durante o envio não é sobrescrita pela resposta (a guarda
    /// `atual.data == envio.foto.data`): o dia é reenviado com a data do
    /// usuário. Como o servidor não recalcula `data_local` de um `client_id`
    /// já criado, as passadas seguintes convergem para a data que ele tem.
    @Test func edicaoDuranteOEnvioConvergeParaADataDoServidor() async throws {
        let ctx = ModelContext(container)
        let ciclo = CicloSoftex(
            userId: userId, valor_total: 100, gasto_total: 0,
            periodo: "21/07 - 21/07", diaria: 100, titulo: "Paris", dias: []
        )
        ctx.insert(ciclo)
        let dia = DiaSoftex(data: Calendar.current.startOfDay(for: .now), saldo: 100)
        ctx.insert(dia)
        dia.ciclo = ciclo
        try ctx.save()

        let portao = api.segurar(.postDiasLote)
        let syncActor = SyncActor(modelContainer: container, api: api)
        let usuario = userId
        let tarefa = Task { await syncActor.sync(agora: .now, userId: usuario) }
        await portao.aguardarChegada()

        // Como a tela faria: muda a data do dia com o pedido em voo.
        let edicao = ModelContext(container)
        let emVoo = try #require(try edicao.fetch(FetchDescriptor<DiaSoftex>()).first)
        let dataEditada = try #require(Calendar.current.date(byAdding: .day, value: 100, to: emVoo.data))
        emVoo.data = dataEditada
        try edicao.save()
        await portao.liberar()

        // A resposta (data_local do dia enviado) não sobrescreve a edição: o
        // dia é reenviado com a data do usuário. O servidor não recalcula o
        // `data_local` de um client_id já criado, então a releitura converge
        // para a data que ele tem — a edição da data de um dia não pode subir
        // por POST (dedup por client_id), o que vale é o que está no servidor.
        _ = await tarefa.value
        let gravado = try #require(try diasLocais().first)
        #expect(gravado.syncStatus == .synced)
        #expect(gravado.data == Calendar.current.startOfDay(for: .now))
        #expect(gravado.data != dataEditada)
    }
}
