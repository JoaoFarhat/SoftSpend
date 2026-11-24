//
//  SyncManager.swift
//  SoftexVamo
//

import Foundation
import SwiftData
import Combine
import os

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var isSyncing = false
    @Published var pendentesRestantes: Int = 0
    @Published var lastSyncError: Error?
    private var syncActor: SyncActor?
    /// T9: pedidos de sync que chegam com `isSyncing == true` não são mais
    /// descartados — `pedidoPendente` manda rodar mais uma vez ao fim e
    /// `forcarPendente` junta o `forcar` dos pedidos com OU.
    private var pedidoPendente = false
    private var forcarPendente = false
    private var networkObservationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "br.com.softspend", category: "SyncManager")
    /// Conectividade consultada antes de chamar a rede; injetável para os
    /// testes — produção usa `NetworkMonitor.shared.isConnected` (padrão do
    /// `init`), como no `CiclosViewModel`. Sem ela, um teste com a `SyncAPI`
    /// falsa cairia no ramo offline quando o CI rodasse sem rede.
    private let estaConectado: @MainActor () -> Bool

    init(estaConectado: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected }) {
        self.estaConectado = estaConectado
        observeNetwork()
    }

    deinit {
        networkObservationTask?.cancel()
    }

    private func observeNetwork() {
        networkObservationTask = Task {
            var wasConnected = NetworkMonitor.shared.isConnected
            for await connected in NetworkMonitor.shared.$isConnected.values {
                if connected && !wasConnected {
                    logger.info("SyncManager: conexão voltou, sync forçado")
                    await sync(forcar: true)
                }
                wasConnected = connected
            }
        }
    }

    func configure(container: ModelContainer) {
        syncActor = SyncActor(modelContainer: container)
        if estaConectado() {
            Task {
                await sync(forcar: true)
            }
        }
    }

    /// Liga um `SyncActor` pronto sem disparar sync. Usado pelos testes para
    /// injetar a `FakeSyncAPI`; em produção o caminho é o `configure`.
    func injetarSyncActor(_ syncActor: SyncActor) {
        self.syncActor = syncActor
    }

    /// Remove do banco local ciclos, dias e gastos que já foram sincronizados
    /// como deletados há mais de 7 dias. Evita acúmulo de registros mortos.
    func limparDadosMortos(context: ModelContext) {
        let limite = Date().addingTimeInterval(-7 * 24 * 3600)
        let synced = SyncStatus.synced.rawValue

        do {
            let cicloDesc = FetchDescriptor<CicloSoftex>(
                predicate: #Predicate { $0.deletadoEm != nil && $0.syncStatusRaw == synced }
            )
            let ciclos = (try? context.fetch(cicloDesc)) ?? []
            for ciclo in ciclos where ciclo.deletadoEm ?? Date.distantFuture < limite {
                context.delete(ciclo)
            }

            let diaDesc = FetchDescriptor<DiaSoftex>(
                predicate: #Predicate { $0.deletadoEm != nil && $0.syncStatusRaw == synced }
            )
            let dias = (try? context.fetch(diaDesc)) ?? []
            for dia in dias where dia.deletadoEm ?? Date.distantFuture < limite {
                context.delete(dia)
            }

            let gastoDesc = FetchDescriptor<GastosDia>(
                predicate: #Predicate { $0.deletadoEm != nil && $0.syncStatusRaw == synced }
            )
            let gastos = (try? context.fetch(gastoDesc)) ?? []
            for gasto in gastos where gasto.deletadoEm ?? Date.distantFuture < limite {
                context.delete(gasto)
            }

            try context.save()
            logger.info("limparDadosMortos: cleanup concluido")
        } catch {
            logger.error("limparDadosMortos: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// - Parameter forcar: ignora o backoff pendente dos itens que falharam.
    ///   Use em ações explícitas do usuário (pull to refresh) e quando a
    ///   conexão volta — senão um item que falhou algumas vezes fica até 1h
    ///   sem ser reenviado, mesmo com internet disponível.
    func sync(forcar: Bool = false) async {
        guard let syncActor else {
            logger.error("SyncManager: syncActor ainda não configurado")
            return
        }
        if isSyncing {
            // T9: lembra o pedido e roda mais uma vez ao fim — uma edição
            // feita durante o envio não espera o próximo gatilho (abrir o
            // app, a rede voltar) para subir.
            pedidoPendente = true
            forcarPendente = forcarPendente || forcar
            logger.info("SyncManager: sync já em andamento, pedido guardado para o fim")
            return
        }
        let userId = AuthService.shared.currentUser?.id ?? ""
        guard estaConectado() else {
            // Sem conexão nenhuma etapa roda e nenhuma requisição sai, mas a
            // faixa "N alterações aguardando envio" do MainView precisa
            // refletir o que já está na fila — sem isso ela some justamente
            // quando há gastos novos esperando para subir.
            pendentesRestantes = userId.isEmpty ? 0 : await syncActor.pendentes(userId: userId)
            logger.warning("SyncManager: sem conexão, sync ignorado (pendentes=\(self.pendentesRestantes, privacy: .public))")
            return
        }
        guard !userId.isEmpty else {
            logger.error("SyncManager: userId vazio, sync ignorado")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        var forcarAtual = forcar
        repeat {
            pedidoPendente = false
            lastSyncError = nil
            let agora = Date()
            logger.info("SyncManager: iniciando sync para userId \(userId, privacy: .private), forcar=\(forcarAtual, privacy: .public)")
            let restantes = await syncActor.sync(agora: agora, userId: userId, forcar: forcarAtual)
            pendentesRestantes = restantes
            logger.info("SyncManager: sync finalizado, pendentes restantes=\(restantes, privacy: .public)")
            // O forcar da próxima rodada vem dos pedidos guardados durante
            // ESTA rodada (OU) — não pode ser lido no início da volta, senão
            // um pedido forçado chegado no meio se perde.
            forcarAtual = forcarPendente
            forcarPendente = false
        } while pedidoPendente
    }

}

/// Sincronização em background.
///
/// Conformidade com `ModelActor` escrita à mão (é o mesmo que o macro
/// `@ModelActor` gera) para o `init` poder receber a API: em produção o
/// `NetworkManager.shared`, nos testes uma API falsa.
///
/// **Mudança durante o envio (T2 de `docs/revisao-sync-offline-ios.md`).** O
/// usuário pode editar, apagar ou trocar o comprovante de um item enquanto a
/// requisição dele está em voo. Por isso cada envio segue três passos:
/// 1. lista os itens e monta o pedido num contexto novo (vê o que a tela já salvou)
///    e tira uma foto (`Foto*`) dos campos que o servidor vai receber;
/// 2. faz o `await`;
/// 3. relê o item em **outro** contexto novo (`gravar`), grava sempre o que o
///    servidor devolveu (`backendId`, URL do comprovante), e só marca `.synced` se a
///    releitura bate com a foto. Se não bate, o item fica `.pending` sem backoff e
///    `sync` roda mais uma passada para enviar o valor novo.
///
/// O `modelContext` do próprio actor não é usado: um contexto que já carregou o
/// objeto pode não enxergar o que outro contexto salvou durante o `await`.
actor SyncActor: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private let api: any SyncAPI
    /// Abre as notas guardadas no aparelho. Nos testes, com um armazém de
    /// chave falso (`ArmazemDeChaveFalso`) que simula o iPhone trancado.
    private let crypto: ComprovanteCrypto

    /// Algum item mudou durante o envio nesta passada: vale rodar outra.
    private var mudouDuranteEnvio = false

    /// Viagens recusadas com `403 subscription_required` neste `sync`: não são
    /// reenviadas nas passadas seguintes (um POST por viagem bloqueada por `sync`).
    private var aguardandoAssinaturaNesteSync: Set<UUID> = []

    /// Uma resposta 429 (limite por minuto) chegou neste `sync`: as etapas
    /// param de chamar a API e as passadas seguintes não rodam — insistir só
    /// toma mais 429. Vale mesmo com `forcar: true`.
    private var limiteAtingidoNesteSync = false

    init(
        modelContainer: ModelContainer,
        api: any SyncAPI = NetworkManager.shared,
        crypto: ComprovanteCrypto = .shared
    ) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
        self.api = api
        self.crypto = crypto
    }

    private let logger = Logger(subsystem: "br.com.softspend", category: "SyncActor")

    private func contextoNovo() -> ModelContext {
        ModelContext(modelContainer)
    }

    private func salvar(_ contexto: ModelContext, etapa: String) {
        do {
            try contexto.save()
        } catch {
            logger.error("Falha ao salvar após \(etapa, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Relê o item num contexto novo (depois do `await`), aplica `alterar` e salva.
    private func gravar<T: PersistentModel>(
        _ descritor: FetchDescriptor<T>,
        etapa: String,
        _ alterar: (T, ModelContext) -> Void
    ) {
        let contexto = contextoNovo()
        var descritor = descritor
        descritor.fetchLimit = 1
        guard let item = (try? contexto.fetch(descritor))?.first else {
            logger.warning("\(etapa, privacy: .public): item não existe mais no banco local, resposta descartada")
            return
        }
        alterar(item, contexto)
        salvar(contexto, etapa: etapa)
    }

    private func gravarCiclo(_ uuid: UUID, etapa: String, _ alterar: (CicloSoftex, ModelContext) -> Void) {
        gravar(FetchDescriptor<CicloSoftex>(predicate: #Predicate { $0.id == uuid }), etapa: etapa, alterar)
    }

    private func gravarDia(_ uuid: UUID, etapa: String, _ alterar: (DiaSoftex) -> Void) {
        gravar(FetchDescriptor<DiaSoftex>(predicate: #Predicate { $0.id == uuid }), etapa: etapa) { dia, _ in alterar(dia) }
    }

    private func gravarGasto(_ uuid: UUID, etapa: String, _ alterar: (GastosDia) -> Void) {
        gravar(FetchDescriptor<GastosDia>(predicate: #Predicate { $0.id == uuid }), etapa: etapa) { gasto, _ in alterar(gasto) }
    }

    // MARK: - Descarte do que foi apagado em outro aparelho (decisão de 12/11)

    /// Apaga o gasto no aparelho e tira o valor dele do `gasto_total` da viagem.
    /// Gasto já marcado como apagado (`deletadoEm`) já saiu do total na hora em
    /// que o usuário o apagou: só some do banco.
    private func descartar(_ gasto: GastosDia, em contexto: ModelContext) {
        if gasto.deletadoEm == nil, let ciclo = gasto.dia?.ciclo {
            ciclo.gasto_total -= gasto.valor
        }
        contexto.delete(gasto)
    }

    /// Apaga o dia no aparelho (a cascata leva os gastos) e tira do
    /// `gasto_total` da viagem os gastos vivos dele. Os já apagados saíram do
    /// total quando foram apagados.
    private func descartar(_ dia: DiaSoftex, em contexto: ModelContext) {
        if let ciclo = dia.ciclo {
            let vivos = dia.gastos.filter { $0.deletadoEm == nil }
            ciclo.gasto_total -= vivos.reduce(Decimal(0)) { $0 + $1.valor }
        }
        contexto.delete(dia)
    }

    /// 404 no POST do dia: a viagem foi apagada em outro aparelho.
    private func descartarDia(_ uuid: UUID, etapa: String) {
        gravar(FetchDescriptor<DiaSoftex>(predicate: #Predicate { $0.id == uuid }), etapa: etapa) { dia, contexto in
            descartar(dia, em: contexto)
        }
    }

    /// 404 no POST/PUT do gasto: o dia (ou o próprio gasto) foi apagado em outro aparelho.
    private func descartarGasto(_ uuid: UUID, etapa: String) {
        gravar(FetchDescriptor<GastosDia>(predicate: #Predicate { $0.id == uuid }), etapa: etapa) { gasto, contexto in
            descartar(gasto, em: contexto)
        }
    }

    /// Versões anteriores guardavam o dia ou gasto com falha final por 404
    /// (`syncError == erroApagadoEmOutroAparelho`). Agora eles são descartados
    /// do mesmo jeito, sem nenhuma requisição. Os gastos saem (e são salvos)
    /// antes de os dias serem lidos, num contexto novo: assim um gasto antigo
    /// dentro de um dia antigo não é descontado duas vezes do total.
    private func descartarAntigosApagadosEmOutroAparelho(userId: String) {
        let erro: String? = SyncActor.erroApagadoEmOutroAparelho

        let contextoGastos = contextoNovo()
        let gastos = ((try? contextoGastos.fetch(FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.syncError == erro }
        ))) ?? []).filter { $0.dia?.ciclo?.userId == userId }
        if !gastos.isEmpty {
            for gasto in gastos { descartar(gasto, em: contextoGastos) }
            salvar(contextoGastos, etapa: "descartarAntigos-gastos")
        }

        let contextoDias = contextoNovo()
        let dias = ((try? contextoDias.fetch(FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.syncError == erro }
        ))) ?? []).filter { $0.ciclo?.userId == userId }
        if !dias.isEmpty {
            for dia in dias { descartar(dia, em: contextoDias) }
            salvar(contextoDias, etapa: "descartarAntigos-dias")
        }

        if !gastos.isEmpty || !dias.isEmpty {
            logger.info("Descartados \(gastos.count, privacy: .public) gasto(s) e \(dias.count, privacy: .public) dia(s) apagados em outro aparelho")
        }
    }

    func sync(agora: Date, userId: String, forcar: Bool = false) async -> Int {
        let maxPassadas = 5

        descartarAntigosApagadosEmOutroAparelho(userId: userId)
        aguardandoAssinaturaNesteSync = []
        limiteAtingidoNesteSync = false

        var pendentesDepois = 0
        for passada in 0..<maxPassadas {
            mudouDuranteEnvio = false
            let pendentesAntes = contarPendentes(agora: agora, userId: userId)
            logger.info("SyncActor: passada \(passada, privacy: .public), pendentesAntes=\(pendentesAntes, privacy: .public)")
            await syncCiclos(agora: agora, userId: userId, forcar: forcar)
            await syncDias(agora: agora, userId: userId, forcar: forcar)
            await syncGastos(agora: agora, userId: userId, forcar: forcar)
            await syncComprovantes(agora: agora, userId: userId, forcar: forcar)
            await syncDeletions(agora: agora, userId: userId, forcar: forcar)
            pendentesDepois = contarPendentes(agora: agora, userId: userId)
            logger.info("SyncActor: passada \(passada, privacy: .public), pendentesDepois=\(pendentesDepois, privacy: .public), mudouDuranteEnvio=\(self.mudouDuranteEnvio, privacy: .public)")
            if limiteAtingidoNesteSync {
                logger.info("SyncActor: limite por minuto (429) atingido, passadas restantes canceladas")
                break
            }
            if mudouDuranteEnvio { continue }
            if pendentesDepois == 0 || pendentesDepois >= pendentesAntes { break }
        }
        return pendentesDepois
    }

    /// Só a contagem dos pendentes, sem rodar nenhuma etapa nem chamar a API.
    /// O `SyncManager` usa para atualizar `pendentesRestantes` quando o sync
    /// não pode rodar (sem conexão) — a regra de contagem é a mesma do `sync`.
    func pendentes(userId: String) -> Int {
        contarPendentes(agora: .now, userId: userId)
    }

    private func contarPendentes(agora: Date, userId: String) -> Int {
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let cicloDesc = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil && $0.userId == userId }
        )
        var diaDesc = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        diaDesc.relationshipKeyPathsForPrefetching = [\.ciclo]
        var gastoDesc = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.syncStatusRaw != synced && $0.deletadoEm == nil }
        )
        gastoDesc.relationshipKeyPathsForPrefetching = [\.dia]
        let ciclos = (try? contexto.fetchCount(cicloDesc)) ?? 0
        let todosDias = (try? contexto.fetch(diaDesc)) ?? []
        let todosGastos = (try? contexto.fetch(gastoDesc)) ?? []
        // T8: filho de um pai já marcado como apagado não conta como pendente
        // nem é enviado — o DELETE do pai (syncDeletions) apaga tudo em
        // cascata no servidor. Filtro em memória: #Predicate não atravessa
        // relacionamentos opcionais.
        let dias = todosDias.filter {
            $0.ciclo?.userId == userId && $0.ciclo?.deletadoEm == nil
        }.count
        let gastos = todosGastos.filter {
            $0.dia?.ciclo?.userId == userId
                && $0.dia?.deletadoEm == nil
                && $0.dia?.ciclo?.deletadoEm == nil
        }.count
        return ciclos + dias + gastos
    }

    private func sincronizarEdicaoCiclo(
        _ ciclo: CicloSoftex,
        contexto: ModelContext,
        agora: Date,
        forcar: Bool = false
    ) async {
        guard let backendId = ciclo.backendId, deveTentar(ciclo, agora: agora, forcar: forcar) else {
            logger.info("sincronizarEdicaoCiclo: pulado backendId=\(String(describing: ciclo.backendId), privacy: .public)")
            return
        }

        logger.info("sincronizarEdicaoCiclo: iniciando backendId=\(backendId, privacy: .public) titulo=\(ciclo.titulo, privacy: .private)")

        let cicloUUID = ciclo.id
        let foto = FotoCiclo(ciclo)
        // Título cortado só no corpo (itens já gravados com mais de 100 no
        // aparelho): o model e a FotoCiclo ficam com o título original.
        let updateRequest = CicloUpdateRequest(
            titulo: LimiteTexto.titulo(ciclo.titulo),
            valor_total: ciclo.valor_total,
            diaria: ciclo.diaria,
            periodo: ciclo.periodo
        )

        do {
            // A edição do ciclo não envia mais a lista de dias: o PUT /dias/lote
            // apagava no servidor (com os gastos) os dias que este aparelho não
            // conhecia. Dia novo sobe pelo syncDias e dia removido pelo
            // syncDeletions. Ver T3 em docs/revisao-sync-offline-ios.md.
            let cicloEditado = try await api.putCiclo(cicloId: backendId, request: updateRequest)
            logger.info("sincronizarEdicaoCiclo: PUT ok backendId=\(backendId, privacy: .public)")

            gravarCiclo(cicloUUID, etapa: "sincronizarEdicaoCiclo") { atual, _ in
                if FotoCiclo(atual) == foto {
                    atual.titulo = cicloEditado.titulo
                    atual.valor_total = cicloEditado.valor_total
                    atual.periodo = cicloEditado.periodo
                    atual.diaria = cicloEditado.diaria
                    marcarSucesso(atual)
                } else {
                    // Editado durante o envio: os campos locais são os novos.
                    marcarMudancaDuranteEnvio(atual)
                }
                // Gasto/dia ainda não enviado (sobe nas etapas seguintes): o
                // total do servidor não o conta e o local fica.
                atual.receberGastoTotalDoServidor(cicloEditado.gasto_total)
            }
        } catch {
            if atingiuLimitePorMinuto(error) {
                gravarCiclo(cicloUUID, etapa: "sincronizarEdicaoCiclo-limite") { atual, _ in
                    marcarAguardandoLimite(atual, agora: agora)
                }
                logger.info("sincronizarEdicaoCiclo: PUT recusado, limite por minuto")
                return
            }
            let erro = error.localizedDescription
            gravarCiclo(cicloUUID, etapa: "sincronizarEdicaoCiclo-catch") { atual, _ in
                atual.syncError = erro
                marcarFalha(atual)
            }
        }
    }

    /// Todos os dias locais do ciclo (inclusive os apagados), por data.
    private func diasLocais(doCiclo cicloUUID: UUID, em contexto: ModelContext) -> [DiaSoftex] {
        var diasDesc = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { _ in true },
            sortBy: [SortDescriptor(\.data)]
        )
        diasDesc.relationshipKeyPathsForPrefetching = [\.ciclo]
        return ((try? contexto.fetch(diasDesc)) ?? []).filter { $0.ciclo?.id == cicloUUID }
    }

    /// Aplica a resposta do `dias/lote` aos dias locais, relidos depois do `await`.
    private func reconciliarDias(
        _ diasRemotos: [DiaSoftex],
        ciclo: CicloSoftex,
        idsEnviados: Set<UUID>,
        contexto: ModelContext,
        backendId: Int
    ) {
        let locais = diasLocais(doCiclo: ciclo.id, em: contexto)
        let idsRemotos = Set(diasRemotos.compactMap { $0.backendId })
        let clientIdsRemotos = Set(diasRemotos.compactMap { $0.clientId })

        for local in locais where local.deletadoEm == nil {
            let aindaExiste = (local.backendId != nil && idsRemotos.contains(local.backendId!))
                || clientIdsRemotos.contains(local.clientId)
            // Só marcamos como deletado se o dia já tinha backendId (já foi sincronizado
            // alguma vez). Dias criados offline ainda não enviados não devem ser apagados
            // só porque o servidor ainda não os conhece.
            if local.backendId != nil && !aindaExiste {
                local.deletadoEm = Date()
                local.syncStatus = .pending
            }
        }

        for diaRemoto in diasRemotos {
            if let local = locais.first(where: { $0.backendId == diaRemoto.backendId })
                ?? locais.first(where: { $0.clientId == diaRemoto.clientId }) {
                if local.deletadoEm != nil && idsEnviados.contains(local.id) {
                    // Apagado durante o envio: não reviver; o syncDeletions envia o delete.
                    local.backendId = local.backendId ?? diaRemoto.backendId
                    continue
                }
                local.data = diaRemoto.data
                local.saldo = diaRemoto.saldo
                local.backendId = diaRemoto.backendId
                local.clientId = diaRemoto.clientId ?? local.clientId
                local.deletadoEm = nil
                local.syncStatus = .synced
            } else if diaRemoto.backendId != nil {
                diaRemoto.ciclo = ciclo
                diaRemoto.syncStatus = .synced
                contexto.insert(diaRemoto)
                // Não faça append manual na relação inversa: ao setar diaRemoto.ciclo,
                // o SwiftData atualiza ciclo.dias automaticamente.
            } else {
                logger.warning("Dia remoto sem backendId ignorado no ciclo \(backendId, privacy: .public)")
            }
        }
    }

    private func deveTentar(_ item: any Syncavel, agora: Date, forcar: Bool = false) -> Bool {
        if forcar { return true }
        guard let proxima = item.proximaTentativaEm else { return true }
        return proxima <= agora
    }

    private func calcularBackoff(tentativas: Int) -> TimeInterval {
        let base: TimeInterval = 60
        let maximo: TimeInterval = 3600
        let multiplicador = min(pow(2.0, Double(tentativas)), maximo / base)
        return base * multiplicador
    }

    private func marcarFalha(_ item: any Syncavel) {
        item.tentativas += 1
        item.proximaTentativaEm = Date().addingTimeInterval(calcularBackoff(tentativas: item.tentativas))
        item.syncStatus = .failed
    }

    /// Versões anteriores marcavam com este `syncError` o dia ou gasto que
    /// recebia 404 (pai ou o próprio item apagado em outro aparelho) e o
    /// guardavam no aparelho. Hoje o item é descartado na hora; o texto só
    /// serve para achar e descartar os que ficaram de antes
    /// (`descartarAntigosApagadosEmOutroAparelho`, no começo do `sync`).
    nonisolated static let erroApagadoEmOutroAparelho = "O dia ou a viagem foi apagado em outro aparelho"

    /// `syncError` da viagem nova recusada com `403 subscription_required`
    /// (§3.4 de `docs/assinatura.md`). Não é falha: a viagem fica `.pending`
    /// e sobe sozinha depois da compra.
    nonisolated static let erroAssinaturaNecessaria = "Assinatura necessária para enviar esta viagem"

    /// `syncError` da nota guardada no aparelho que a chave atual não abre
    /// (`sincronizarComprovante`): falha comum, com backoff — os bytes ficam
    /// guardados (a nota pode voltar a abrir) e a tela mostra o motivo, com
    /// "Descartar nota" como saída no detalhe do gasto.
    nonisolated static let erroNotaNaoAbre = "Nota não abre com a chave atual"

    /// Viagem nova recusada por falta de assinatura: fica `.pending`, sem
    /// contar tentativa nem backoff (o `sync(forcar: true)` depois da compra a
    /// sobe) e **sem** `mudouDuranteEnvio` (outra passada só repetiria o 403).
    private func marcarAguardandoAssinatura(_ item: any Syncavel) {
        item.proximaTentativaEm = nil
        item.syncStatus = .pending
        item.syncError = SyncActor.erroAssinaturaNecessaria
    }

    /// 429 do limite por minuto: não é falha. O item fica `.pending`, sem
    /// contar tentativa e sem mensagem de erro na tela, e tenta de novo daqui
    /// a 60 s (o `deveTentar` respeita `proximaTentativaEm`; `forcar` ignora).
    private func marcarAguardandoLimite(_ item: any Syncavel, agora: Date) {
        item.proximaTentativaEm = agora.addingTimeInterval(60)
        item.syncStatus = .pending
        item.syncError = nil
    }

    /// Chave das notas indisponível agora (iPhone trancado — ela é
    /// `WhenUnlockedThisDeviceOnly`): não é falha. Como o 429 por minuto, fica
    /// `.pending`, sem contar tentativa e sem `syncError` — "nota não abre"
    /// aqui levaria a tela a oferecer "Descartar nota" numa nota que pode
    /// estar boa — e tenta de novo daqui a 60 s (o `forcar` ignora a espera).
    private func marcarAguardandoDesbloqueio(_ item: any Syncavel, agora: Date) {
        item.proximaTentativaEm = agora.addingTimeInterval(60)
        item.syncStatus = .pending
        item.syncError = nil
    }

    private func marcarSucesso(_ item: any Syncavel) {
        item.tentativas = 0
        item.proximaTentativaEm = nil
        item.syncStatus = .synced
        item.syncError = nil
    }

    /// O envio deu certo, mas o usuário mudou o item no meio: fica `.pending`
    /// para a próxima passada, sem contar tentativa nem backoff (não foi falha).
    private func marcarMudancaDuranteEnvio(_ item: any Syncavel) {
        item.tentativas = 0
        item.proximaTentativaEm = nil
        item.syncStatus = .pending
        item.syncError = nil
        mudouDuranteEnvio = true
    }

    private func syncCiclos(agora: Date, userId: String, forcar: Bool = false) async {
        guard !limiteAtingidoNesteSync else { return }
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil && item.userId == userId },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? contexto.fetch(descriptor)) ?? []
        let ciclos = todos.filter { deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncCiclos: \(ciclos.count, privacy: .public) ciclo(s) pendente(s) para userId \(userId, privacy: .private)")

        for ciclo in ciclos {
            if limiteAtingidoNesteSync { break }
            if ciclo.backendId != nil {
                await sincronizarEdicaoCiclo(ciclo, contexto: contexto, agora: agora, forcar: forcar)
                continue
            }
            if aguardandoAssinaturaNesteSync.contains(ciclo.id) { continue }

            logger.info("syncCiclos: POST ciclo clientId=\(ciclo.clientId, privacy: .private) titulo=\(ciclo.titulo, privacy: .private)")
            let cicloUUID = ciclo.id
            let foto = FotoCiclo(ciclo)
            let createRequest = CicloCreateRequest(
                client_id: ciclo.clientId,
                titulo: LimiteTexto.titulo(ciclo.titulo),
                valor_total: ciclo.valor_total,
                diaria: ciclo.diaria,
                periodo: ciclo.periodo
            )
            do {
                let response = try await api.postCiclo(request: createRequest)
                gravarCiclo(cicloUUID, etapa: "syncCiclos") { atual, _ in
                    atual.backendId = response.backendId
                    // O `gasto_total` local fica: a viagem acabou de nascer no
                    // servidor, que ainda não tem nenhum gasto dela (os gastos
                    // só sobem com este `backendId`). Copiar o 0 da resposta
                    // apagava do total os gastos feitos sem internet, e o
                    // descarte de um 404 nos dias depois o deixava negativo.
                    if FotoCiclo(atual) == foto {
                        marcarSucesso(atual)
                    } else {
                        marcarMudancaDuranteEnvio(atual)
                    }
                }
                logger.info("syncCiclos: POST ok, backendId=\(response.backendId.map(String.init) ?? "nil", privacy: .public)")
            } catch {
                if isAssinaturaNecessaria(error) {
                    // §3.4 de docs/assinatura.md: sem assinatura, a viagem nova
                    // espera na fila (sem backoff, sem descarte, sem logout).
                    // Os dias e gastos dela também esperam: só sobem com o
                    // backendId do ciclo.
                    aguardandoAssinaturaNesteSync.insert(cicloUUID)
                    gravarCiclo(cicloUUID, etapa: "syncCiclos-assinatura") { atual, _ in
                        marcarAguardandoAssinatura(atual)
                    }
                    logger.info("syncCiclos: POST recusado, assinatura necessária")
                    continue
                }
                if atingiuLimitePorMinuto(error) {
                    gravarCiclo(cicloUUID, etapa: "syncCiclos-limite") { atual, _ in
                        marcarAguardandoLimite(atual, agora: agora)
                    }
                    logger.info("syncCiclos: POST recusado, limite por minuto")
                    break
                }
                let erro = error.localizedDescription
                gravarCiclo(cicloUUID, etapa: "syncCiclos-catch") { atual, _ in
                    atual.syncError = erro
                    marcarFalha(atual)
                }
                logger.error("syncCiclos: POST falhou: \(erro, privacy: .public)")
            }
        }
    }

    /// Teto do `POST /dias/lote` por pedido: uma viagem de 30 dias criada sem
    /// internet subia em 30 pedidos seguidos — lento no 4G e perto do limite
    /// por minuto do servidor. Acima de 60 dias, em partes de 60.
    nonisolated static let maxDiasPorLote = 60

    private func syncDias(agora: Date, userId: String, forcar: Bool = false) async {
        guard !limiteAtingidoNesteSync else { return }
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? contexto.fetch(descriptor)) ?? []
        // T8: dia de ciclo apagado não sobe — o DELETE do ciclo o remove em cascata.
        let dias = todos.filter {
            $0.ciclo?.userId == userId && $0.ciclo?.deletadoEm == nil
                && deveTentar($0, agora: agora, forcar: forcar)
        }

        // Um pedido por viagem (em partes de `maxDiasPorLote`). Dia cujo ciclo
        // ainda não tem backendId espera a próxima passada.
        var porCiclo: [Int: [DiaSoftex]] = [:]
        var ordemCiclos: [Int] = []
        for dia in dias {
            guard let cicloId = dia.ciclo?.backendId else { continue }
            if porCiclo[cicloId] == nil { ordemCiclos.append(cicloId) }
            porCiclo[cicloId, default: []].append(dia)
        }
        logger.info("syncDias: \(dias.count, privacy: .public) dia(s) pendente(s) em \(ordemCiclos.count, privacy: .public) viagem(ns)")

        for cicloId in ordemCiclos {
            if limiteAtingidoNesteSync { break }
            let lote = porCiclo[cicloId] ?? []
            for inicio in stride(from: 0, to: lote.count, by: Self.maxDiasPorLote) {
                if limiteAtingidoNesteSync { break }
                let parte = Array(lote[inicio..<min(inicio + Self.maxDiasPorLote, lote.count)])
                await enviarDiasEmLote(parte, cicloId: cicloId, agora: agora)
            }
        }
    }

    /// Envia um pedaço de dias da mesma viagem (até `maxDiasPorLote`) num POST
    /// só. Cada dia da resposta casa pelo `client_id`, não pela posição: o que
    /// não voltou falha sozinho, sem derrubar os outros.
    private func enviarDiasEmLote(_ dias: [DiaSoftex], cicloId: Int, agora: Date) async {
        /// Foto do que foi enviado de cada dia, tirada antes do `await`.
        struct Envio {
            let uuid: UUID
            let clientId: String
            let foto: FotoDia
            let saldoEnviado: Decimal
        }
        let envios = dias.map {
            Envio(uuid: $0.id, clientId: $0.clientId, foto: FotoDia($0), saldoEnviado: $0.saldo)
        }
        let pedidos = dias.map { DiaLoteRequest(clientId: $0.clientId, data: $0.data) }
        do {
            let resposta = try await api.postDiasLote(cicloId: cicloId, dias: pedidos)
            var porClientId: [String: DiaSoftex] = [:]
            for remoto in resposta { porClientId[remoto.clientId] = remoto }
            for envio in envios {
                guard let remoto = porClientId[envio.clientId] else {
                    gravarDia(envio.uuid, etapa: "syncDias-ausente") { atual in
                        atual.syncError = "Falha ao sincronizar dia"
                        marcarFalha(atual)
                    }
                    continue
                }
                gravarDia(envio.uuid, etapa: "syncDias") { atual in
                    atual.backendId = remoto.backendId
                    // Reconcilia saldo com servidor (backend pode ajustar inicial), a
                    // menos que um gasto local tenha mexido no saldo durante o envio.
                    if atual.saldo == envio.saldoEnviado {
                        atual.saldo = remoto.saldo
                    }
                    // diaId dos gastos é derivado de dia?.backendId — não precisa atualizar manualmente
                    if FotoDia(atual) == envio.foto {
                        marcarSucesso(atual)
                    } else {
                        marcarMudancaDuranteEnvio(atual)
                    }
                }
            }
        } catch {
            if atingiuLimitePorMinuto(error) {
                for envio in envios {
                    gravarDia(envio.uuid, etapa: "syncDias-limite") { atual in
                        marcarAguardandoLimite(atual, agora: agora)
                    }
                }
                return
            }
            if isNotFoundError(error) {
                // T4: a viagem foi apagada em outro aparelho — os dias do lote
                // (com os gastos) são descartados no aparelho, sem requisição.
                for envio in envios {
                    descartarDia(envio.uuid, etapa: "syncDias-404")
                }
                return
            }
            let erro = error.localizedDescription
            for envio in envios {
                gravarDia(envio.uuid, etapa: "syncDias-catch") { atual in
                    atual.syncError = erro
                    marcarFalha(atual)
                }
            }
        }
    }

    /// Depois de um envio do gasto que deu certo: `.synced` só se nada mudou
    /// desde a foto e não há comprovante pendente (o `syncComprovantes` resolve).
    private func concluirGasto(_ atual: GastosDia, mudou: Bool) {
        if mudou {
            marcarMudancaDuranteEnvio(atual)
        } else if !temComprovantePendente(atual) {
            marcarSucesso(atual)
        }
    }

    /// Nota a enviar ou a apagar. Chave indisponível conta como pendente: a nota
    /// existe, só não abre agora (o `syncComprovantes` marca a falha). Bytes que
    /// não abrem com a chave atual não têm o que enviar e não seguram o gasto.
    private func temComprovantePendente(_ gasto: GastosDia) -> Bool {
        if gasto.comprovanteParaRemover { return true }
        do {
            return try gasto.lerComprovante(crypto: crypto) != nil
        } catch {
            return true
        }
    }

    private func syncGastos(agora: Date, userId: String, forcar: Bool = false) async {
        guard !limiteAtingidoNesteSync else { return }
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? contexto.fetch(descriptor)) ?? []
        // T8: gasto de dia ou ciclo apagado não sobe — o DELETE do pai o remove em cascata.
        let gastos = todos.filter {
            $0.dia?.ciclo?.userId == userId
                && $0.dia?.deletadoEm == nil
                && $0.dia?.ciclo?.deletadoEm == nil
                && deveTentar($0, agora: agora, forcar: forcar)
        }

        for gasto in gastos {
            if limiteAtingidoNesteSync { break }
            guard let diaIdReal = gasto.dia?.backendId else {
                continue
            }

            let gastoUUID = gasto.id
            let foto = FotoGasto(gasto)
            do {
                let response: GastosDia
                if let backendId = gasto.backendId {
                    let updateRequest = GastoUpdateRequest(
                        titulo: LimiteTexto.titulo(gasto.titulo),
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: diaIdReal
                    )
                    response = try await api.putGasto(gastoId: backendId, request: updateRequest)
                } else {
                    let createRequest = GastoCreateRequest(
                        client_id: gasto.clientId,
                        titulo: LimiteTexto.titulo(gasto.titulo),
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: diaIdReal
                    )
                    response = try await api.postGasto(request: createRequest)
                    guard response.backendId != nil else {
                        throw URLError(.cannotParseResponse)
                    }
                }
                gravarGasto(gastoUUID, etapa: "syncGastos") { atual in
                    // Sempre grava o backendId, mesmo se mudou: senão o POST se repetiria.
                    if let novoId = response.backendId { atual.backendId = novoId }
                    atual.comprovanteUrl = response.comprovanteUrl
                    atual.copiarOpenFinance(de: response)
                    concluirGasto(atual, mudou: FotoGasto(atual) != foto)
                }
            } catch {
                if atingiuLimitePorMinuto(error) {
                    gravarGasto(gastoUUID, etapa: "syncGastos-limite") { atual in
                        marcarAguardandoLimite(atual, agora: agora)
                    }
                    break
                }
                if isNotFoundError(error) {
                    // T4: o dia (POST) ou o gasto (PUT) foi apagado em outro
                    // aparelho — o gasto é descartado no aparelho, sem requisição.
                    descartarGasto(gastoUUID, etapa: "syncGastos-404")
                } else {
                    let erro = error.localizedDescription
                    gravarGasto(gastoUUID, etapa: "syncGastos-catch") { atual in
                        atual.syncError = erro
                        marcarFalha(atual)
                    }
                }
            }
        }
    }

    private func syncComprovantes(agora: Date, userId: String, forcar: Bool = false) async {
        guard !limiteAtingidoNesteSync else { return }
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in
                item.syncStatusRaw != synced &&
                (item.comprovanteDataCriptografado != nil || item.comprovanteParaRemover) &&
                item.deletadoEm == nil
            },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? contexto.fetch(descriptor)) ?? []
        // T8: comprovante de gasto de dia ou ciclo apagado não sobe — o DELETE
        // do pai remove tudo em cascata.
        let gastos = todos.filter {
            $0.dia?.ciclo?.userId == userId
                && $0.dia?.deletadoEm == nil
                && $0.dia?.ciclo?.deletadoEm == nil
                && $0.backendId != nil
                && deveTentar($0, agora: agora, forcar: forcar)
        }

        for gasto in gastos {
            if limiteAtingidoNesteSync { break }
            guard let backendId = gasto.backendId else { continue }
            let gastoUUID = gasto.id
            let foto = FotoGasto(gasto)
            do {
                try await sincronizarComprovante(gasto, backendId: backendId, foto: foto, agora: agora)
            } catch {
                if atingiuLimitePorMinuto(error) {
                    gravarGasto(gastoUUID, etapa: "syncComprovantes-limite") { atual in
                        marcarAguardandoLimite(atual, agora: agora)
                    }
                    break
                }
                let erro = error.localizedDescription
                gravarGasto(gastoUUID, etapa: "syncComprovantes-catch") { atual in
                    atual.syncError = erro
                    marcarFalha(atual)
                }
            }
        }
    }

    /// Envia (ou apaga) o comprovante e grava o resultado relendo o gasto.
    ///
    /// Só limpa o comprovante local se ele ainda é o que foi enviado: uma foto
    /// nova anexada durante o upload fica para a próxima passada.
    ///
    /// A ordem dos ramos importa:
    /// 1. nota que abre: upload;
    /// 2. remoção pendente: DELETE — não precisa dos bytes nem da chave, então
    ///    vem antes de qualquer ramo de "não abre";
    /// 3. chave indisponível (`keyNotAvailable`, iPhone trancado):
    ///    `marcarAguardandoDesbloqueio`, bytes intactos;
    /// 4. chave inválida (`invalidKeySize`): lança — o `syncComprovantes`
    ///    marca a falha com o motivo e backoff;
    /// 5. bytes que a chave atual não abre: `erroNotaNaoAbre` + backoff.
    private func sincronizarComprovante(_ gasto: GastosDia, backendId: Int, foto: FotoGasto, agora: Date) async throws {
        let gastoUUID = gasto.id

        // `lerComprovante` só lança erro de chave; bytes que não abrem viram `nil`.
        let dadosNota: Data?
        var erroDaChave: Error?
        do {
            dadosNota = try gasto.lerComprovante(crypto: crypto)
        } catch {
            dadosNota = nil
            erroDaChave = error
        }

        if let comprovanteData = dadosNota {
            let atualizado = try await api.uploadComprovante(
                gastoId: backendId,
                imageData: comprovanteData,
                mime: gasto.comprovanteMime
            )
            gravarGasto(gastoUUID, etapa: "syncComprovantes-upload") { atual in
                let mudou = FotoGasto(atual) != foto
                atual.comprovanteUrl = atualizado.comprovanteUrl
                if atual.comprovanteDataCriptografado == foto.comprovanteDataCriptografado {
                    // O arquivo enviado substituiu o anterior no servidor.
                    atual.comprovanteDataCriptografado = nil
                    atual.comprovanteParaRemover = false
                }
                concluirGasto(atual, mudou: mudou)
            }
        } else if gasto.comprovanteParaRemover {
            do {
                _ = try await api.deleteComprovante(gastoId: backendId)
            } catch {
                if !isNotFoundError(error) {
                    throw error
                }
            }
            gravarGasto(gastoUUID, etapa: "syncComprovantes-delete") { atual in
                let mudou = FotoGasto(atual) != foto
                // O servidor ficou sem comprovante. Um anexo novo feito durante o
                // delete continua em comprovanteDataCriptografado e sobe depois.
                atual.comprovanteUrl = nil
                atual.comprovanteParaRemover = false
                concluirGasto(atual, mudou: mudou)
            }
        } else if (erroDaChave as? ComprovanteCryptoError) == .keyNotAvailable {
            // A nota existe e pode estar boa; só não abre agora. Espera sem
            // falhar e sem mexer nos bytes.
            gravarGasto(gastoUUID, etapa: "syncComprovantes-chave-indisponivel") { atual in
                if FotoGasto(atual) != foto {
                    marcarMudancaDuranteEnvio(atual)
                } else {
                    marcarAguardandoDesbloqueio(atual, agora: agora)
                }
            }
        } else if let erroDaChave {
            throw erroDaChave
        } else {
            // Bytes guardados que a chave atual não abre: não há o que enviar
            // nem o que apagar. Falha com o motivo na tela e backoff, em vez
            // de concluir sem registro nem tentar a cada passada — os bytes
            // ficam (a nota pode voltar a abrir quando a chave estiver
            // acessível de novo) e a tela oferece "Descartar nota" como saída.
            gravarGasto(gastoUUID, etapa: "syncComprovantes") { atual in
                if FotoGasto(atual) != foto {
                    marcarMudancaDuranteEnvio(atual)
                } else {
                    atual.syncError = SyncActor.erroNotaNaoAbre
                    marcarFalha(atual)
                }
            }
        }
    }

    /// 404 **vindo da API**: os "não encontrado" dela saem pelo handler de
    /// `middlewares.py` (`build_error_response`), sempre com `request_id` no
    /// corpo — o `NetworkManager.execute` o traz no `serverError`. Um 404 sem
    /// `request_id` (`requestId == "-"`, como o de rota inexistente do FastAPI,
    /// que responde só `{"detail": "Not Found"}` — deploy quebrado, app novo
    /// contra servidor velho) não prova que o item sumiu: segue a falha comum
    /// (`marcarFalha`, backoff), sem descarte e sem apagar no `syncDeletions`.
    private func isNotFoundError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .serverError(_, let requestId, let statusCode) = apiError else {
            return false
        }
        return statusCode == 404 && requestId != "-"
    }

    /// `403 subscription_required` no erro tipado, antes de virar texto (§3.1).
    private func isAssinaturaNecessaria(_ error: Error) -> Bool {
        (error as? APIError)?.assinaturaNecessaria == true
    }

    /// `429` do limite por minuto (slowapi): esperar 60 s resolve, então não é
    /// falha. O outro 429 — `daily_ai_limit`, teto diário de leituras por IA —
    /// não entra aqui: só libera no dia seguinte e segue no caminho de falha.
    private func isLimitePorMinuto(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .serverError(_, _, let statusCode) = apiError else {
            return false
        }
        return statusCode == 429 && !apiError.limiteDiarioIA
    }

    /// `error` é o 429 do limite por minuto? Freia este `sync` — liga
    /// `limiteAtingidoNesteSync` (as etapas param de chamar a API e as
    /// passadas restantes não rodam) — e devolve `true` para o chamador
    /// agendar o item com `marcarAguardandoLimite` e interromper o laço
    /// (`break`/`continue`/`return`). Outros erros devolvem `false` sem
    /// mudar nada.
    private func atingiuLimitePorMinuto(_ error: Error) -> Bool {
        guard isLimitePorMinuto(error) else { return false }
        limiteAtingidoNesteSync = true
        return true
    }

    // MARK: - Apagar item sem backendId (T7)

    /// T7 de `docs/revisao-sync-offline-ios.md` (R7): resultado de procurar no
    /// servidor um item apagado no aparelho que ainda não tem `backendId`.
    private enum Recuperacao {
        /// O servidor tem o item (o POST idempotente devolveu o existente, ou
        /// criou agora): este é o id para o `DELETE`.
        case encontrado(Int)
        /// O item não pode estar no servidor: nunca foi enviado, ou o pai dele
        /// não existe lá (404). Basta apagar no aparelho.
        case naoExiste
        /// 429 do limite por minuto: não é falha — espera 60 s como os envios.
        case aguardandoLimite
        /// Não deu para saber agora: fica para a próxima, com backoff.
        case falhou(String)
    }

    /// 404 da API: o pai não existe no servidor. `403 subscription_required`: com o
    /// servidor corrigido (AS2, §3.3 de `docs/assinatura.md`), um `client_id`
    /// que já existe devolveria o item; o 403 garante que ele não está lá.
    private func classificar(_ error: Error) -> Recuperacao {
        if isNotFoundError(error) || isAssinaturaNecessaria(error) { return .naoExiste }
        if atingiuLimitePorMinuto(error) { return .aguardandoLimite }
        return .falhou(error.localizedDescription)
    }

    /// Repete o POST do gasto com o mesmo `client_id` só para descobrir o
    /// `backendId` (o servidor devolve o existente). Se o primeiro POST nunca
    /// chegou, este cria o gasto e o `DELETE` logo em seguida o remove.
    private func recuperarBackendId(_ gasto: GastosDia) async -> Recuperacao {
        // Sem dia no servidor o gasto nunca pôde subir (o syncGastos espera o dia).
        guard gasto.podeTerSidoCriadoNoServidor, let diaId = gasto.dia?.backendId else { return .naoExiste }
        let request = GastoCreateRequest(
            client_id: gasto.clientId,
            titulo: LimiteTexto.titulo(gasto.titulo),
            valor: gasto.valor,
            categoria: gasto.categoria,
            dia_id: diaId
        )
        do {
            let resposta = try await api.postGasto(request: request)
            guard let id = resposta.backendId else { return .falhou("Resposta do servidor sem id do gasto") }
            return .encontrado(id)
        } catch {
            return classificar(error)
        }
    }

    private func recuperarBackendId(_ dia: DiaSoftex) async -> Recuperacao {
        guard dia.podeTerSidoCriadoNoServidor, let cicloId = dia.ciclo?.backendId else { return .naoExiste }
        let request = DiaLoteRequest(clientId: dia.clientId, data: dia.data)
        do {
            // POST /dias/lote deduplica por client_id (o PUT, por data, não é usado aqui).
            let resposta = try await api.postDiasLote(cicloId: cicloId, dias: [request])
            guard let id = resposta.first?.backendId else { return .falhou("Resposta do servidor sem id do dia") }
            return .encontrado(id)
        } catch {
            return classificar(error)
        }
    }

    private func recuperarBackendId(_ ciclo: CicloSoftex) async -> Recuperacao {
        guard ciclo.podeTerSidoCriadoNoServidor else { return .naoExiste }
        let request = CicloCreateRequest(
            client_id: ciclo.clientId,
            titulo: LimiteTexto.titulo(ciclo.titulo),
            valor_total: ciclo.valor_total,
            diaria: ciclo.diaria,
            periodo: ciclo.periodo
        )
        do {
            let resposta = try await api.postCiclo(request: request)
            guard let id = resposta.backendId else { return .falhou("Resposta do servidor sem id da viagem") }
            return .encontrado(id)
        } catch {
            return classificar(error)
        }
    }

    private func syncDeletions(agora: Date, userId: String, forcar: Bool = false) async {
        guard !limiteAtingidoNesteSync else { return }
        let modelContext = contextoNovo()
        let synced = SyncStatus.synced.rawValue

        let gastoDescriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )

        let todosGastos = ((try? modelContext.fetch(gastoDescriptor)) ?? [])
        let gastos = todosGastos
            .filter { $0.dia?.ciclo?.userId == userId && deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncDeletions: \(gastos.count, privacy: .public) gasto(s) para deletar")

        for gasto in gastos {
            if limiteAtingidoNesteSync { break }
            let backendId: Int
            if let id = gasto.backendId {
                backendId = id
            } else {
                // T7: sem backendId, mas o POST pode ter sido processado com a
                // resposta perdida. Nunca enviado: só no aparelho, sem requisição.
                switch await recuperarBackendId(gasto) {
                case .encontrado(let id):
                    gasto.backendId = id
                    backendId = id
                case .naoExiste:
                    marcarSucesso(gasto)
                    continue
                case .aguardandoLimite:
                    marcarAguardandoLimite(gasto, agora: agora)
                    continue
                case .falhou(let erro):
                    marcarFalha(gasto)
                    gasto.syncError = erro
                    continue
                }
            }

            do {
                try await api.deleteGasto(gastoId: backendId)
            } catch {
                if atingiuLimitePorMinuto(error) {
                    marcarAguardandoLimite(gasto, agora: agora)
                    continue
                }
                if !isNotFoundError(error) {
                    marcarFalha(gasto)
                    gasto.syncError = error.localizedDescription
                    continue
                }
            }
            marcarSucesso(gasto)
        }

        let diaDescriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todosDias = ((try? modelContext.fetch(diaDescriptor)) ?? [])
        let dias = todosDias
            .filter { $0.ciclo?.userId == userId && deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncDeletions: \(dias.count, privacy: .public) dia(s) para deletar")

        for dia in dias {
            if limiteAtingidoNesteSync { break }
            let backendId: Int
            if let id = dia.backendId {
                backendId = id
            } else {
                // T7: ver o mesmo caso nos gastos acima.
                switch await recuperarBackendId(dia) {
                case .encontrado(let id):
                    dia.backendId = id
                    backendId = id
                case .naoExiste:
                    marcarSucesso(dia)
                    continue
                case .aguardandoLimite:
                    marcarAguardandoLimite(dia, agora: agora)
                    continue
                case .falhou(let erro):
                    marcarFalha(dia)
                    dia.syncError = erro
                    continue
                }
            }

            do {
                try await api.deleteDia(diaId: backendId)
            } catch {
                if atingiuLimitePorMinuto(error) {
                    marcarAguardandoLimite(dia, agora: agora)
                    continue
                }
                if !isNotFoundError(error) {
                    marcarFalha(dia)
                    dia.syncError = error.localizedDescription
                    continue
                }
            }
            marcarSucesso(dia)
        }

        let cicloDescriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm != nil && item.userId == userId },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let ciclos = ((try? modelContext.fetch(cicloDescriptor)) ?? [])
            .filter { deveTentar($0, agora: agora, forcar: forcar) }
        logger.info("syncDeletions: \(ciclos.count, privacy: .public) ciclo(s) para deletar")

        for ciclo in ciclos {
            if limiteAtingidoNesteSync { break }
            let backendId: Int
            if let id = ciclo.backendId {
                backendId = id
            } else {
                // T7: ver o mesmo caso nos gastos acima.
                switch await recuperarBackendId(ciclo) {
                case .encontrado(let id):
                    ciclo.backendId = id
                    backendId = id
                case .naoExiste:
                    marcarSucesso(ciclo)
                    continue
                case .aguardandoLimite:
                    marcarAguardandoLimite(ciclo, agora: agora)
                    continue
                case .falhou(let erro):
                    marcarFalha(ciclo)
                    ciclo.syncError = erro
                    continue
                }
            }

            do {
                try await api.deleteCiclo(cicloId: backendId)
            } catch {
                if atingiuLimitePorMinuto(error) {
                    marcarAguardandoLimite(ciclo, agora: agora)
                    continue
                }
                if !isNotFoundError(error) {
                    marcarFalha(ciclo)
                    ciclo.syncError = error.localizedDescription
                    continue
                }
            }
            marcarSucesso(ciclo)
        }

        salvar(modelContext, etapa: "syncDeletions")
    }
}

// MARK: - Foto dos campos enviados (T2)

/// O que o servidor recebeu de um ciclo. Comparada com a releitura depois do `await`.
nonisolated struct FotoCiclo: Equatable {
    let titulo: String
    let valorTotal: Decimal
    let diaria: Decimal
    let periodo: String
    let deletadoEm: Date?

    init(_ ciclo: CicloSoftex) {
        titulo = ciclo.titulo
        valorTotal = ciclo.valor_total
        diaria = ciclo.diaria
        periodo = ciclo.periodo
        deletadoEm = ciclo.deletadoEm
    }
}

/// O que o servidor recebeu de um dia.
nonisolated struct FotoDia: Equatable {
    let data: Date
    let cicloId: UUID?
    let deletadoEm: Date?

    init(_ dia: DiaSoftex) {
        data = dia.data
        cicloId = dia.ciclo?.id
        deletadoEm = dia.deletadoEm
    }
}

/// O que o servidor recebeu de um gasto, inclusive o comprovante (bytes cifrados:
/// um anexo novo, mesmo da mesma imagem, sai com outro nonce e conta como mudança).
nonisolated struct FotoGasto: Equatable {
    let titulo: String
    let valor: Decimal
    let categoria: Categoria
    let diaId: UUID?
    let deletadoEm: Date?
    let comprovanteDataCriptografado: Data?
    let comprovanteParaRemover: Bool

    init(_ gasto: GastosDia) {
        titulo = gasto.titulo
        valor = gasto.valor
        categoria = gasto.categoria
        diaId = gasto.dia?.id
        deletadoEm = gasto.deletadoEm
        comprovanteDataCriptografado = gasto.comprovanteDataCriptografado
        comprovanteParaRemover = gasto.comprovanteParaRemover
    }
}

nonisolated protocol Syncavel: AnyObject {
    var tentativas: Int { get set }
    var proximaTentativaEm: Date? { get set }
    var syncStatus: SyncStatus { get set }
    var syncError: String? { get set }
}

nonisolated extension Syncavel {
    /// T7: um item **sem `backendId`** pode já existir no servidor — o POST foi
    /// processado e a resposta se perdeu (timeout, app fechado). Sinal disso: já
    /// houve tentativa (`tentativas > 0`), falha ou erro registrado. Item que
    /// nunca foi enviado (`tentativas == 0` e sem `syncError`) não pode estar lá.
    ///
    /// A falha final por 404 do T4 (de versões anteriores, ainda não
    /// descartada) não conta: o pai não existe no servidor, e o item (se chegou
    /// a ser criado) foi apagado junto, em cascata.
    ///
    /// A viagem recusada por falta de assinatura (§3.3 de `docs/assinatura.md`)
    /// também não: o 403 só vem quando o `client_id` não existe no servidor,
    /// mesmo que uma tentativa anterior tenha contado em `tentativas`.
    var podeTerSidoCriadoNoServidor: Bool {
        if syncError == SyncActor.erroApagadoEmOutroAparelho { return false }
        if syncError == SyncActor.erroAssinaturaNecessaria { return false }
        return tentativas > 0 || syncStatus == .failed || syncError != nil
    }
}

nonisolated extension CicloSoftex: Syncavel {}
nonisolated extension DiaSoftex: Syncavel {}
nonisolated extension GastosDia: Syncavel {}

enum SyncError: Error, LocalizedError {
    case cicloNaoSincronizado
    case modelContextNaoConfigurado
    case sincronizacaoEmProgresso

    var errorDescription: String? {
        switch self {
        case .cicloNaoSincronizado:
            return "O ciclo ainda não foi sincronizado com o servidor"
        case .modelContextNaoConfigurado:
            return "Contexto do banco de dados não configurado"
        case .sincronizacaoEmProgresso:
            return "Uma sincronização já está em andamento"
        }
    }
}
