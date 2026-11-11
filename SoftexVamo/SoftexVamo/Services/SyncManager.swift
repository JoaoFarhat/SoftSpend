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

    init() {
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
        if NetworkMonitor.shared.isConnected {
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
        guard NetworkMonitor.shared.isConnected else {
            logger.warning("SyncManager: sem conexão, sync ignorado")
            return
        }
        let userId = AuthService.shared.currentUser?.id ?? ""
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

    /// Algum item mudou durante o envio nesta passada: vale rodar outra.
    private var mudouDuranteEnvio = false

    init(modelContainer: ModelContainer, api: any SyncAPI = NetworkManager.shared) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
        self.api = api
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

    func sync(agora: Date, userId: String, forcar: Bool = false) async -> Int {
        let maxPassadas = 5

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
            if mudouDuranteEnvio { continue }
            if pendentesDepois == 0 || pendentesDepois >= pendentesAntes { break }
        }
        return pendentesDepois
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
        // T4: item com falha final por 404 (texto fixo no syncError) também
        // não conta — ele não é mais enviado.
        let dias = todosDias.filter {
            $0.ciclo?.userId == userId && $0.ciclo?.deletadoEm == nil && !falhouDefinitivo($0)
        }.count
        let gastos = todosGastos.filter {
            $0.dia?.ciclo?.userId == userId
                && $0.dia?.deletadoEm == nil
                && $0.dia?.ciclo?.deletadoEm == nil
                && !falhouDefinitivo($0)
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
        let updateRequest = CicloUpdateRequest(
            titulo: ciclo.titulo,
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
                atual.gasto_total = cicloEditado.gasto_total
            }
        } catch {
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

    /// T4: `syncError` com este texto marca a falha final por 404 — o pai (dia
    /// ou ciclo/"viagem") ou o próprio item foi apagado em outro aparelho. O
    /// item fica no aparelho, não volta para a fila e não conta em
    /// `contarPendentes`. O texto fixo é o identificador: um campo novo no
    /// `@Model` exigiria um schema V2.
    nonisolated static let erroApagadoEmOutroAparelho = "O dia ou a viagem foi apagado em outro aparelho"

    /// 404 ao enviar dia ou gasto: falha final. Só muda `syncStatus` e
    /// `syncError` — `tentativas` e `proximaTentativaEm` ficam como estão
    /// (não é falha transitória, retry não resolve).
    private func marcarFalhaFinal(_ item: any Syncavel) {
        item.syncStatus = .failed
        item.syncError = SyncActor.erroApagadoEmOutroAparelho
    }

    /// Falha final por 404, reconhecida pelo texto fixo do `syncError`.
    /// `syncDias`, `syncGastos`, `syncComprovantes` e `contarPendentes`
    /// ignoram esses itens — o `syncDeletions` não, porque o DELETE de um
    /// item que o usuário apagou continua saindo (404 lá é sucesso).
    private func falhouDefinitivo(_ item: any Syncavel) -> Bool {
        item.syncError == SyncActor.erroApagadoEmOutroAparelho
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
            if ciclo.backendId != nil {
                await sincronizarEdicaoCiclo(ciclo, contexto: contexto, agora: agora, forcar: forcar)
                continue
            }

            logger.info("syncCiclos: POST ciclo clientId=\(ciclo.clientId, privacy: .private) titulo=\(ciclo.titulo, privacy: .private)")
            let cicloUUID = ciclo.id
            let foto = FotoCiclo(ciclo)
            let createRequest = CicloCreateRequest(
                client_id: ciclo.clientId,
                titulo: ciclo.titulo,
                valor_total: ciclo.valor_total,
                diaria: ciclo.diaria,
                periodo: ciclo.periodo
            )
            do {
                let response = try await api.postCiclo(request: createRequest)
                gravarCiclo(cicloUUID, etapa: "syncCiclos") { atual, _ in
                    atual.backendId = response.backendId
                    atual.gasto_total = response.gasto_total
                    if FotoCiclo(atual) == foto {
                        marcarSucesso(atual)
                    } else {
                        marcarMudancaDuranteEnvio(atual)
                    }
                }
                logger.info("syncCiclos: POST ok, backendId=\(response.backendId.map(String.init) ?? "nil", privacy: .public)")
            } catch {
                let erro = error.localizedDescription
                gravarCiclo(cicloUUID, etapa: "syncCiclos-catch") { atual, _ in
                    atual.syncError = erro
                    marcarFalha(atual)
                }
                logger.error("syncCiclos: POST falhou: \(erro, privacy: .public)")
            }
        }
    }

    private func syncDias(agora: Date, userId: String, forcar: Bool = false) async {
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? contexto.fetch(descriptor)) ?? []
        // T8: dia de ciclo apagado não sobe — o DELETE do ciclo o remove em cascata.
        // T4: dia com falha final por 404 também não sobe.
        let dias = todos.filter {
            $0.ciclo?.userId == userId && $0.ciclo?.deletadoEm == nil
                && !falhouDefinitivo($0) && deveTentar($0, agora: agora, forcar: forcar)
        }

        for dia in dias {
            guard let cicloId = dia.ciclo?.backendId else {
                // Ciclo pai ainda não sincronizado: deixar como pending para próxima passada
                continue
            }

            let diaUUID = dia.id
            let foto = FotoDia(dia)
            let saldoEnviado = dia.saldo
            let request = DiaLoteRequest(clientId: dia.clientId, data: dia.data)
            do {
                let response = try await api.postDiasLote(cicloId: cicloId, dias: [request])
                gravarDia(diaUUID, etapa: "syncDias") { atual in
                    guard let primeiro = response.first else {
                        atual.syncError = "Falha ao sincronizar dia"
                        marcarFalha(atual)
                        return
                    }
                    atual.backendId = primeiro.backendId
                    // Reconcilia saldo com servidor (backend pode ajustar inicial), a
                    // menos que um gasto local tenha mexido no saldo durante o envio.
                    if atual.saldo == saldoEnviado {
                        atual.saldo = primeiro.saldo
                    }
                    // diaId dos gastos é derivado de dia?.backendId — não precisa atualizar manualmente
                    if FotoDia(atual) == foto {
                        marcarSucesso(atual)
                    } else {
                        marcarMudancaDuranteEnvio(atual)
                    }
                }
            } catch {
                if isNotFoundError(error) {
                    // T4: o ciclo foi apagado em outro aparelho — falha final,
                    // o dia fica no aparelho mas sai da fila.
                    gravarDia(diaUUID, etapa: "syncDias-404") { atual in
                        marcarFalhaFinal(atual)
                    }
                } else {
                    let erro = error.localizedDescription
                    gravarDia(diaUUID, etapa: "syncDias-catch") { atual in
                        atual.syncError = erro
                        marcarFalha(atual)
                    }
                }
            }
        }
    }

    /// Depois de um envio do gasto que deu certo: `.synced` só se nada mudou
    /// desde a foto e não há comprovante pendente (o `syncComprovantes` resolve).
    private func concluirGasto(_ atual: GastosDia, mudou: Bool) {
        if mudou {
            marcarMudancaDuranteEnvio(atual)
        } else if atual.comprovanteData == nil && !atual.comprovanteParaRemover {
            marcarSucesso(atual)
        }
    }

    private func syncGastos(agora: Date, userId: String, forcar: Bool = false) async {
        let contexto = contextoNovo()
        let synced = SyncStatus.synced.rawValue
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { item in item.syncStatusRaw != synced && item.deletadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm)]
        )
        let todos = (try? contexto.fetch(descriptor)) ?? []
        // T8: gasto de dia ou ciclo apagado não sobe — o DELETE do pai o remove em cascata.
        // T4: gasto com falha final por 404 também não sobe.
        let gastos = todos.filter {
            $0.dia?.ciclo?.userId == userId
                && $0.dia?.deletadoEm == nil
                && $0.dia?.ciclo?.deletadoEm == nil
                && !falhouDefinitivo($0)
                && deveTentar($0, agora: agora, forcar: forcar)
        }

        for gasto in gastos {
            guard let diaIdReal = gasto.dia?.backendId else {
                continue
            }

            let gastoUUID = gasto.id
            let foto = FotoGasto(gasto)
            do {
                let response: GastosDia
                if let backendId = gasto.backendId {
                    let updateRequest = GastoUpdateRequest(
                        titulo: gasto.titulo,
                        valor: gasto.valor,
                        categoria: gasto.categoria,
                        dia_id: diaIdReal
                    )
                    response = try await api.putGasto(gastoId: backendId, request: updateRequest)
                } else {
                    let createRequest = GastoCreateRequest(
                        client_id: gasto.clientId,
                        titulo: gasto.titulo,
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
                if isNotFoundError(error) {
                    // T4: o dia (POST) ou o gasto (PUT) foi apagado em outro
                    // aparelho — falha final, o gasto fica no aparelho mas sai
                    // da fila.
                    gravarGasto(gastoUUID, etapa: "syncGastos-404") { atual in
                        marcarFalhaFinal(atual)
                    }
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
        // T4: comprovante de gasto com falha final por 404 também não sobe.
        let gastos = todos.filter {
            $0.dia?.ciclo?.userId == userId
                && $0.dia?.deletadoEm == nil
                && $0.dia?.ciclo?.deletadoEm == nil
                && $0.backendId != nil
                && !falhouDefinitivo($0)
                && deveTentar($0, agora: agora, forcar: forcar)
        }

        for gasto in gastos {
            guard let backendId = gasto.backendId else { continue }
            let gastoUUID = gasto.id
            let foto = FotoGasto(gasto)
            do {
                try await sincronizarComprovante(gasto, backendId: backendId, foto: foto)
            } catch {
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
    private func sincronizarComprovante(_ gasto: GastosDia, backendId: Int, foto: FotoGasto) async throws {
        let gastoUUID = gasto.id

        if let comprovanteData = gasto.comprovanteData {
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
        } else {
            // Bytes que não descriptografam: nada a enviar.
            gravarGasto(gastoUUID, etapa: "syncComprovantes") { atual in
                concluirGasto(atual, mudou: FotoGasto(atual) != foto)
            }
        }
    }

    private func isNotFoundError(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            if case .serverError(_, _, let statusCode) = apiError {
                return statusCode == 404
            }
        }
        let nsError = error as NSError
        if let statusCode = nsError.userInfo["statusCode"] as? Int {
            return statusCode == 404
        }
        return false
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
        /// Não deu para saber agora: fica para a próxima, com backoff.
        case falhou(String)
    }

    private func classificar(_ error: Error) -> Recuperacao {
        isNotFoundError(error) ? .naoExiste : .falhou(error.localizedDescription)
    }

    /// Repete o POST do gasto com o mesmo `client_id` só para descobrir o
    /// `backendId` (o servidor devolve o existente). Se o primeiro POST nunca
    /// chegou, este cria o gasto e o `DELETE` logo em seguida o remove.
    private func recuperarBackendId(_ gasto: GastosDia) async -> Recuperacao {
        // Sem dia no servidor o gasto nunca pôde subir (o syncGastos espera o dia).
        guard gasto.podeTerSidoCriadoNoServidor, let diaId = gasto.dia?.backendId else { return .naoExiste }
        let request = GastoCreateRequest(
            client_id: gasto.clientId,
            titulo: gasto.titulo,
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
            titulo: ciclo.titulo,
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
                case .falhou(let erro):
                    marcarFalha(gasto)
                    gasto.syncError = erro
                    continue
                }
            }

            do {
                try await api.deleteGasto(gastoId: backendId)
            } catch {
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
                case .falhou(let erro):
                    marcarFalha(dia)
                    dia.syncError = erro
                    continue
                }
            }

            do {
                try await api.deleteDia(diaId: backendId)
            } catch {
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
                case .falhou(let erro):
                    marcarFalha(ciclo)
                    ciclo.syncError = erro
                    continue
                }
            }

            do {
                try await api.deleteCiclo(cicloId: backendId)
            } catch {
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
    /// A falha final por 404 do T4 não conta: o pai não existe no servidor, e o
    /// item (se chegou a ser criado) foi apagado junto, em cascata.
    var podeTerSidoCriadoNoServidor: Bool {
        if syncError == SyncActor.erroApagadoEmOutroAparelho { return false }
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
