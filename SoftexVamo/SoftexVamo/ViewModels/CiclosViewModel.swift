//
//  CicloViewModel.swift
//  SoftSpend
//
//  Created by Joao Victor on 27/07/26.
//

import Foundation
import Combine
import SwiftUI
import SwiftData
import os

@MainActor
final class CiclosViewModel: ObservableObject {
    @Published var allCiclos: [CicloSoftex] = []
    @Published var atualCiclo: CicloSoftex = CicloSoftex.vazio
    @Published var gastosInfo: GastosDia = GastosDia.example
    @Published var availableInfo: GastosDia = GastosDia.example
    @Published var isLoading: Bool = true
    @Published var selectedTab: Int = 0
    @Published var hasMorePages: Bool = true
    @Published var isOffline: Bool = false
    
    var modelContext: ModelContext?
    weak var errorManager: ErrorManager?
    
    private var hasLoadedOnce = false
    var index: Int = 0
    private var skip = 0
    private let limit = 5
    
    private var diasSkip = 0
    private let diasLimit = 20
    private var hasMoreDias = true
    var isLoadingDias = false
    
    private var loadCiclosTask: Task<Void, Never>?
    private var loadMoreDiasTask: Task<Void, Never>?
    private var networkObservationTask: Task<Void, Never>?
    
    private var currentUser: UserModel? {
        AuthService.shared.currentUser
    }
    
    private let viewModelLogger = Logger(subsystem: "br.com.softspend", category: "CiclosViewModel")

    init() {
        observeNetwork()
    }

    deinit {
        networkObservationTask?.cancel()
        loadCiclosTask?.cancel()
        loadMoreDiasTask?.cancel()
    }

    private func observeNetwork() {
        networkObservationTask = Task {
            for await connected in NetworkMonitor.shared.$isConnected.values {
                self.isOffline = !connected
            }
        }
    }

    private func showError(_ error: Error) {
        viewModelLogger.error("CiclosViewModel error: \(error.localizedDescription, privacy: .public)")
        errorManager?.show(error: error)
    }

    private func salvarLocal() {
        do {
            try modelContext?.save()
        } catch {
            showError(APIError.serverError(
                message: "Erro ao salvar dados localmente: \(error.localizedDescription)",
                requestId: "-",
                statusCode: 500
            ))
        }
    }
    
    func reset() {
        loadCiclosTask?.cancel()
        loadMoreDiasTask?.cancel()
        loadCiclosTask = nil
        loadMoreDiasTask = nil
        
        self.allCiclos = []
        self.atualCiclo = CicloSoftex.vazio
        self.index = 0
        self.isLoading = true
        self.hasLoadedOnce = false
        self.hasMorePages = true
        self.skip = 0
        self.diasSkip = 0
        self.hasMoreDias = true
        self.leituraDeCiclos = nil
    }

    func limparDadosLocais() {
        guard let modelContext else { return }
        try? modelContext.delete(model: GastosDia.self)
        try? modelContext.delete(model: DiaSoftex.self)
        try? modelContext.delete(model: CicloSoftex.self)
        try? modelContext.delete(model: CartaoOpenFinance.self)
        try? modelContext.delete(model: FaturaCartao.self)
        try? modelContext.delete(model: TransacaoCartao.self)
        try? modelContext.delete(model: UserModel.self)
        try? modelContext.save()
    }

    func fetchCiclosResumo() {
        loadCiclos(append: false)
    }
    
    func loadMoreCiclos() {
        guard hasMorePages, !isLoading else { return }
        skip += limit
        loadCiclos(append: true)
    }
    
    private func loadCiclos(append: Bool) {
        guard currentUser != nil else {
            showError(APIError.serverError(message: "Usuario nao esta logado", requestId: "-", statusCode: 401))
            self.isLoading = false
            return
        }
        
        if append, !hasMorePages { return }
        if !append, hasLoadedOnce { return }
        
        loadCiclosTask?.cancel()
        loadMoreDiasTask?.cancel()
        loadCiclosTask = nil
        loadMoreDiasTask = nil
        
        loadCiclosTask = Task {
            isLoading = true
            let skipDaPagina = skip

            if !append {
                deduplicarCiclosLocais()
                iniciarLeituraDeCiclos()
            }
            
            let userId = currentUser?.id ?? ""
            var descriptor = FetchDescriptor<CicloSoftex>(
                predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId },
                sortBy: [SortDescriptor(\.criadoEm, order: .reverse)]
            )
            descriptor.relationshipKeyPathsForPrefetching = [\.dias]

            let ciclosLocais: [CicloSoftex]
            if let context = modelContext {
                ciclosLocais = (try? context.fetch(descriptor)) ?? []
            } else {
                ciclosLocais = []
            }
            
            if !ciclosLocais.isEmpty {
                if !append {
                    self.allCiclos = ciclosLocais
                    let inicio = cicloDoInicio(ciclosLocais, hoje: .now) ?? ciclosLocais[0]
                    self.atualCiclo = inicio
                    self.index = ciclosLocais.firstIndex(where: { $0.id == inicio.id }) ?? 0
                } else {
                    let idsExistentes = Set(self.allCiclos.map { $0.id })
                    let novos = ciclosLocais.filter { !idsExistentes.contains($0.id) }
                    self.allCiclos.append(contentsOf: novos)
                }
                self.isLoading = false
            }

            guard NetworkMonitor.shared.isConnected else {
                if !append, !ciclosLocais.isEmpty {
                    self.diasSkip = 0
                    self.hasMoreDias = false
                    carregarDiasLocais()
                }
                isLoading = false
                hasLoadedOnce = true
                return
            }

            do {
                let ciclos = try await NetworkManager.shared.fetchCicloResumo(skip: skipDaPagina, limit: limit)

                guard !Task.isCancelled else { return }

                hasMorePages = ciclos.count == limit

                // Lido antes: depois do delete, o `atualCiclo` pode ser um objeto apagado.
                let idAberto = self.atualCiclo.id
                let removidos = registrarPaginaDeCiclos(ciclos, skip: skipDaPagina, limit: limit)

                salvarLocal()
                
                let ciclosAtualizados: [CicloSoftex]
                if let context = modelContext {
                    ciclosAtualizados = (try? context.fetch(descriptor)) ?? []
                } else {
                    ciclosAtualizados = []
                }
                
                if !append {
                    self.allCiclos = ciclosAtualizados
                    self.index = 0
                    
                    if let inicio = self.cicloInicio ?? self.allCiclos.first {
                        self.atualCiclo = inicio
                        self.index = self.allCiclos.firstIndex(where: { $0.id == inicio.id }) ?? 0
                    } else {
                        self.atualCiclo = CicloSoftex.vazio
                    }
                } else {
                    self.allCiclos = ciclosAtualizados
                    // A viagem aberta foi apagada em outro aparelho (T5): abre a do início.
                    if removidos.contains(idAberto) {
                        if let inicio = self.cicloInicio ?? self.allCiclos.first {
                            abrirViagem(inicio)
                        } else {
                            self.atualCiclo = CicloSoftex.vazio
                            self.index = 0
                        }
                    }
                }

                if !append, self.allCiclos.indices.contains(self.index) {
                    let cicloParaSalvar = self.allCiclos[self.index]
                    
                    guard let cicloId = cicloParaSalvar.backendId else {
                        // Ciclo ainda não sincronizado (offline) — carrega os dias
                        // do SwiftData para que seja possível adicionar gastos.
                        carregarDiasLocais()
                        isLoading = false
                        hasLoadedOnce = true
                        return
                    }
                    
                    // Sem zerar `dias`: isso desligava os dias locais do ciclo
                    // (os pendentes ficavam órfãos). O upsert por `backendId`
                    // religa os do servidor e tira os que sumiram de lá.
                    self.atualCiclo = cicloParaSalvar
                    self.diasSkip = 0
                    self.hasMoreDias = true
                    loadMoreDiasTask?.cancel()
                    loadMoreDiasTask = nil
                    loadMoreDiasTask = Task {
                        await loadMoreDias(cicloId: cicloId)
                    }
                } else if !append {
                    self.atualCiclo = CicloSoftex.vazio
                }
                
                isLoading = false
                hasLoadedOnce = true
                
            } catch {
                guard !Task.isCancelled else { return }
                // Página perdida: a leitura não chega mais ao fim sem buraco.
                leituraDeCiclos = nil
                showError(error)

                if !append, self.allCiclos.isEmpty {
                    self.allCiclos = []
                    self.atualCiclo = CicloSoftex.vazio
                }
                
                isLoading = false
                hasLoadedOnce = true
            }
        }
    }
    
    // MARK: Ciclos apagados no servidor (T5)

    /// Leitura das páginas de `fetchCicloResumo` desde a primeira (`skip == 0`).
    /// Só com todas as páginas lidas em sequência, sem buraco, dá para saber o
    /// que sumiu do servidor.
    struct LeituraDeCiclos {
        /// Ciclos já sincronizados antes da primeira página: um ciclo que o
        /// `SyncActor` enviar durante a leitura não está aqui e não é apagado.
        let candidatos: Set<Int>
        var vistos: Set<Int> = []
        /// `skip` que a próxima página precisa ter para não deixar buraco.
        var proximoSkip = 0
    }
    private(set) var leituraDeCiclos: LeituraDeCiclos?

    /// Começa uma leitura nova (antes da primeira página). Interno para os testes.
    func iniciarLeituraDeCiclos() {
        let candidatos = ciclosLocaisDoUsuario()
            .filter { $0.syncStatus == .synced }
            .compactMap(\.backendId)
        leituraDeCiclos = LeituraDeCiclos(candidatos: Set(candidatos))
    }

    /// Grava uma página do servidor e, se foi a última de uma leitura sem buraco,
    /// apaga os ciclos que sumiram de lá. Devolve os `id`s locais apagados.
    /// Interno para os testes.
    @discardableResult
    func registrarPaginaDeCiclos(_ ciclos: [CicloSoftex], skip: Int, limit: Int) -> Set<UUID> {
        let ids = ciclos.compactMap(\.backendId)
        for ciclo in ciclos {
            salvarOuAtualizarCicloLocal(ciclo)
        }
        // Página fora de ordem (outra pulada por falha, cancelamento ou offline):
        // a leitura não serve mais para apagar nada até recomeçar do zero.
        guard var leitura = leituraDeCiclos, leitura.proximoSkip == skip else {
            leituraDeCiclos = nil
            return []
        }
        leitura.vistos.formUnion(ids)
        leitura.proximoSkip += ciclos.count
        guard ciclos.count < limit else {
            leituraDeCiclos = leitura
            return []
        }
        leituraDeCiclos = nil
        return removerCiclosSumidos(candidatos: leitura.candidatos, mantendo: leitura.vistos)
    }

    private func ciclosLocaisDoUsuario() -> [CicloSoftex] {
        let userId = currentUser?.id ?? ""
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId }
        )
        return (try? modelContext?.fetch(descriptor)) ?? []
    }

    /// Ciclo sincronizado antes da leitura e ausente da lista completa foi apagado
    /// no servidor: sai daqui (o delete em cascata leva dias e gastos). Fica se ele
    /// ou qualquer dia/gasto dele tiver alteração local ainda não enviada.
    private func removerCiclosSumidos(candidatos: Set<Int>, mantendo vistos: Set<Int>) -> Set<UUID> {
        let sumidos = ciclosLocaisDoUsuario().filter { ciclo in
            guard let id = ciclo.backendId, candidatos.contains(id), !vistos.contains(id),
                  !Self.temAlteracaoLocal(ciclo.syncStatus, deletadoEm: ciclo.deletadoEm) else { return false }
            return !Self.temAlteracaoNaViagem(ciclo)
        }
        guard !sumidos.isEmpty else { return [] }
        let removidos = Set(sumidos.map(\.id))
        for ciclo in sumidos { modelContext?.delete(ciclo) }
        salvarLocal()
        return removidos
    }

    private static func temAlteracaoNaViagem(_ ciclo: CicloSoftex) -> Bool {
        (ciclo.dias ?? []).contains { dia in
            temAlteracaoLocal(dia.syncStatus, deletadoEm: dia.deletadoEm)
                || dia.gastos.contains { temAlteracaoLocal($0.syncStatus, deletadoEm: $0.deletadoEm) }
        }
    }

    private func deduplicarCiclosLocais() {
        guard let context = modelContext else { return }
        let userId = currentUser?.id ?? ""
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.deletadoEm == nil && $0.userId == userId },
            sortBy: [SortDescriptor(\.criadoEm, order: .forward)]
        )
        let todos: [CicloSoftex]
        do {
            todos = try context.fetch(descriptor)
        } catch {
            showError(APIError.serverError(
                message: "Deduplicação: falha ao buscar ciclos: \(error.localizedDescription)",
                requestId: "-",
                statusCode: 500
            ))
            return
        }

        var originalPorBackendId: [Int: CicloSoftex] = [:]
        var originalPorClientId: [String: CicloSoftex] = [:]
        var duplicatas: [CicloSoftex] = []
        for ciclo in todos {
            var isDuplicata = false
            if let bid = ciclo.backendId {
                if originalPorBackendId[bid] != nil {
                    isDuplicata = true
                } else {
                    originalPorBackendId[bid] = ciclo
                }
            } else {
                let cid = ciclo.clientId
                if originalPorClientId[cid] != nil {
                    isDuplicata = true
                } else {
                    originalPorClientId[cid] = ciclo
                }
            }
            if isDuplicata {
                duplicatas.append(ciclo)
            }
        }

        guard !duplicatas.isEmpty else { return }

        for dup in duplicatas {
            let original: CicloSoftex?
            if let bid = dup.backendId {
                original = originalPorBackendId[bid]
            } else {
                original = originalPorClientId[dup.clientId]
            }
            guard let original, original !== dup else { continue }
            let diasParaMover = Array(dup.dias ?? [])
            for dia in diasParaMover {
                dia.ciclo = original
            }
            context.delete(dup)
        }

        salvarLocal()
    }
    
    /// Mostra os dias locais do `atualCiclo` e busca no servidor todas as
    /// páginas de dias (viagens com mais de `diasLimit` dias inclusive).
    func loadMoreDias(cicloId: Int) async {
        guard NetworkMonitor.shared.isConnected else {
            carregarDiasLocais()
            return
        }
        await carregarDiasDoServidor(cicloId: cicloId) { skip, limit in
            try await NetworkManager.shared.fetchDias(cicloId: cicloId, skip: skip, limit: limit)
        }
    }

    /// Busca página a página (até uma vir com menos de `diasLimit`), faz o
    /// upsert por `backendId` e tira os dias sincronizados que sumiram do
    /// servidor. `buscar` recebe `skip` e `limit`; injetável nos testes.
    func carregarDiasDoServidor(
        cicloId: Int,
        buscar: @escaping @MainActor (_ skip: Int, _ limit: Int) async throws -> [DiaSoftex]
    ) async {
        guard !Task.isCancelled else { return }
        carregarDiasLocais()

        loadMoreDiasTask?.cancel()
        let ciclo = atualCiclo
        // Só busca para a viagem que está aberta: se o `atualCiclo` já é
        // outro, os dias do servidor seriam gravados na viagem errada.
        guard ciclo.backendId == cicloId else { return }
        let limite = diasLimit
        // Candidatos à remoção: dias já sincronizados ANTES da busca. Um dia
        // que o SyncActor enviar durante a busca não está aqui e não é apagado.
        let sincronizadosAntes = idsDeDiasSincronizados(de: ciclo)
        let gastosSincronizadosAntes = idsDeGastosSincronizados(de: ciclo)
        let tarefa = Task {
            isLoadingDias = true
            defer { isLoadingDias = false }
            var skip = 0
            var idsServidor = Set<Int>()
            var idsGastosServidor = Set<Int>()
            var listaCompleta = false
            do {
                // Teto de páginas: protege contra um servidor que ignore o `skip`.
                for _ in 0..<100 {
                    let dias = try await buscar(skip, limite)
                    guard !Task.isCancelled, atualCiclo.id == ciclo.id else { return }
                    for dia in dias {
                        if let id = dia.backendId { idsServidor.insert(id) }
                        // `GET /dias` traz todos os gastos de cada dia (joinedload).
                        // Lidos antes do upsert, que move os objetos para o dia local.
                        idsGastosServidor.formUnion(dia.gastos.compactMap(\.backendId))
                        salvarOuAtualizarDiaLocal(dia, no: ciclo)
                    }
                    skip += dias.count
                    salvarLocal()
                    carregarDiasLocais()
                    if dias.count < limite {
                        listaCompleta = true
                        break
                    }
                }
                diasSkip = skip
                hasMoreDias = false
                // Sem a última página (teto atingido), a lista está incompleta:
                // não dá para saber o que sumiu do servidor.
                if listaCompleta {
                    removerSumidos(
                        de: ciclo,
                        dias: Candidatos(antes: sincronizadosAntes, noServidor: idsServidor),
                        gastos: Candidatos(antes: gastosSincronizadosAntes, noServidor: idsGastosServidor)
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Com dias locais na tela, a falha de rede em segundo plano
                // não interrompe o usuário (offline-first).
                if (ciclo.dias ?? []).isEmpty { showError(error) }
            }
        }
        loadMoreDiasTask = tarefa
        await tarefa.value
    }

    private func idsDeDiasSincronizados(de ciclo: CicloSoftex) -> Set<Int> {
        Set((ciclo.dias ?? []).compactMap { dia in
            dia.syncStatus == .synced ? dia.backendId : nil
        })
    }

    /// Gastos já sincronizados da viagem (por `backendId`), tirados antes da busca (T5).
    private func idsDeGastosSincronizados(de ciclo: CicloSoftex) -> Set<Int> {
        Set((ciclo.dias ?? []).flatMap(\.gastos).compactMap { gasto in
            gasto.syncStatus == .synced && gasto.deletadoEm == nil ? gasto.backendId : nil
        })
    }

    /// `backendId`s já sincronizados antes da busca e os que vieram na lista do servidor.
    struct Candidatos {
        let antes: Set<Int>
        let noServidor: Set<Int>

        /// Sincronizado antes da busca e ausente da lista completa: foi apagado no servidor.
        func sumiu(_ backendId: Int?, status: SyncStatus, deletadoEm: Date?) -> Bool {
            guard let backendId, antes.contains(backendId), !noServidor.contains(backendId) else { return false }
            return !CiclosViewModel.temAlteracaoLocal(status, deletadoEm: deletadoEm)
        }
    }

    /// Com a lista completa do servidor, o que já estava sincronizado antes da busca
    /// e não veio nela foi apagado lá (em outro aparelho): sai daqui também (T5).
    /// - Gasto: compara com os gastos de todos os dias da viagem, então um gasto
    ///   movido para outro dia não sai.
    /// - Dia: só sai se todos os gastos dele também sumiram (o delete em cascata
    ///   nunca leva um gasto que ainda existe ou que tem alteração local).
    /// Nada com alteração local (`pending`/`failed`/`deletadoEm`) é apagado.
    /// Tudo é decidido antes do primeiro delete e salvo uma vez só.
    private func removerSumidos(de ciclo: CicloSoftex, dias: Candidatos, gastos: Candidatos) {
        let todosOsDias = ciclo.dias ?? []
        let gastosSumidos = todosOsDias.flatMap(\.gastos).filter {
            gastos.sumiu($0.backendId, status: $0.syncStatus, deletadoEm: $0.deletadoEm)
        }
        let idsGastosSumidos = Set(gastosSumidos.map(\.id))
        let diasSumidos = todosOsDias.filter { dia in
            dias.sumiu(dia.backendId, status: dia.syncStatus, deletadoEm: dia.deletadoEm)
                && dia.gastos.allSatisfy { idsGastosSumidos.contains($0.id) }
        }
        guard !gastosSumidos.isEmpty || !diasSumidos.isEmpty else { return }
        let idsDiasSumidos = Set(diasSumidos.map(\.id))
        for gasto in gastosSumidos {
            // Os gastos de um dia que sai vão no delete em cascata dele.
            if let diaId = gasto.dia?.id, idsDiasSumidos.contains(diaId) { continue }
            modelContext?.delete(gasto)
        }
        for dia in diasSumidos { modelContext?.delete(dia) }
        salvarLocal()
        carregarDiasLocais()
    }

    /// Viagem mostrada no início: a que contém hoje, senão a próxima, senão a última encerrada.
    var cicloInicio: CicloSoftex? {
        cicloDoInicio(allCiclos, hoje: .now)
    }

    /// Carrega a viagem escolhida em Viagens sem mudar `cicloInicio`.
    func abrirViagem(_ ciclo: CicloSoftex) {
        loadMoreDiasTask?.cancel()
        loadMoreDiasTask = nil
        atualCiclo = ciclo
        index = allCiclos.firstIndex(where: { $0.id == ciclo.id }) ?? 0
        diasSkip = 0
        carregarDiasLocais()
        if let cicloId = ciclo.backendId, NetworkMonitor.shared.isConnected {
            hasMoreDias = true
            loadMoreDiasTask = Task { await loadMoreDias(cicloId: cicloId) }
        } else {
            hasMoreDias = false
        }
    }

    private func carregarDiasLocais() {
        let cicloLocalId = self.atualCiclo.id
        // Busca também os dias apagados: `atualCiclo.dias = ...` com só os vivos desligava do
        // ciclo (`dia.ciclo = nil`) o dia com exclusão pendente, e o `syncDeletions` (que filtra
        // por `dia.ciclo?.userId`) nunca o enviava (T1). As telas já filtram `deletadoEm == nil`.
        var descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.ciclo?.id == cicloLocalId },
            sortBy: [SortDescriptor(\.data)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.ciclo]
        var diasAtualizados: [DiaSoftex]
        if let context = modelContext {
            do {
                diasAtualizados = try context.fetch(descriptor)
            } catch {
                showError(APIError.serverError(
                    message: "Erro ao buscar dias locais: \(error.localizedDescription)",
                    requestId: "-",
                    statusCode: 500
                ))
                return
            }
        } else {
            diasAtualizados = []
        }

        // Recuperação defensiva: ciclos antigos/corrompidos podem ter perdido
        // seus dias. Se o ciclo tem um periodo valido, re-gera os dias localmente
        // para o usuario nao ficar bloqueado. Só para ciclo nunca sincronizado:
        // os dias de um ciclo com `backendId` vêm do servidor (`loadMoreDias`);
        // recriá-los aqui geraria clientIds novos que subiriam como duplicatas.
        if !diasAtualizados.contains(where: { $0.deletadoEm == nil }),
           atualCiclo.backendId == nil, !atualCiclo.periodo.isEmpty {
            diasAtualizados += reconstruirDiasParaCicloAtual()
        }

        self.atualCiclo.dias = diasAtualizados
        self.objectWillChange.send()
    }

    /// Gera `DiaSoftex` para o `atualCiclo` a partir do string `periodo`.
    /// Usado como fallback quando o array `dias` esta vazio/corrompido.
    @discardableResult
    private func reconstruirDiasParaCicloAtual() -> [DiaSoftex] {
        let periodo = atualCiclo.periodo
        let partes = periodo
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard partes.count == 2 else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        formatter.locale = Locale(identifier: "pt_BR")
        let anoAtual = Calendar.current.component(.year, from: Date())
        formatter.defaultDate = Calendar.current.date(from: DateComponents(year: anoAtual))

        guard let dataInicio = formatter.date(from: partes[0]),
              let dataFim = formatter.date(from: partes[1]) else {
            return []
        }

        let dayCount = Calendar.current.datesBetween(dataInicio, and: dataFim)
        let safeDayCount = max(dayCount, 1)
        var dias: [DiaSoftex] = []

        for i in 0..<safeDayCount {
            guard let data = Calendar.current.date(byAdding: .day, value: i, to: dataInicio) else { continue }
            let dia = DiaSoftex(clientId: UUID().uuidString, data: data, saldo: atualCiclo.diaria)
            dia.ciclo = atualCiclo
            modelContext?.insert(dia)
            dias.append(dia)
        }

        salvarLocal()
        return dias
    }
    
    private func salvarOuAtualizarDiaLocal(_ dia: DiaSoftex, no ciclo: CicloSoftex) {
        // Casa pelo backendId e, sem ele, pelo clientId: um dia criado no iPhone que ainda não tinha
        // recebido o backendId não era reconhecido e o do servidor entrava como outro dia (10/11:
        // cada data aparecia duas vezes ao escolher a data do gasto).
        if let existente = diaLocal(backendId: dia.backendId) ?? diaLocal(clientId: dia.clientId) {
            // T1: com alteração local ainda não enviada, o servidor traz a versão antiga.
            // Só completa o que falta para casar; campos e status ficam como o usuário deixou.
            if Self.temAlteracaoLocal(existente.syncStatus, deletadoEm: existente.deletadoEm) {
                if existente.backendId == nil { existente.backendId = dia.backendId }
                if existente.ciclo == nil { existente.ciclo = ciclo }
                // Dia com exclusão pendente: nada do servidor entra nele (não revive).
                guard existente.deletadoEm == nil else { return }
                for gasto in dia.gastos {
                    salvarOuAtualizarGastoLocal(gasto, no: existente)
                }
                absorverDuplicatas(de: existente)
                absorverDuplicatasDeGasto(no: existente)
                return
            }
            existente.backendId = dia.backendId ?? existente.backendId
            existente.data = dia.data
            existente.saldo = dia.saldo
            existente.ciclo = ciclo
            for gasto in dia.gastos {
                salvarOuAtualizarGastoLocal(gasto, no: existente)
            }
            existente.syncStatus = .synced
            existente.syncError = nil
            absorverDuplicatas(de: existente)
            absorverDuplicatasDeGasto(no: existente)
            return
        }
        dia.syncStatus = .synced
        dia.syncError = nil
        dia.ciclo = ciclo
        modelContext?.insert(dia)
        for gasto in dia.gastos {
            salvarOuAtualizarGastoLocal(gasto, no: dia)
        }
    }

    private func diaLocal(backendId: Int?) -> DiaSoftex? {
        guard let backendId else { return nil }
        let descriptor = FetchDescriptor<DiaSoftex>(predicate: #Predicate { $0.backendId == backendId })
        return try? modelContext?.fetch(descriptor).first
    }

    /// Prefere o dia vivo; sem ele, devolve o que tem exclusão pendente. Sem isso, um dia apagado
    /// no aparelho antes de receber o `backendId` voltava como dia novo no próximo refresh (T1).
    private func diaLocal(clientId: String) -> DiaSoftex? {
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.clientId == clientId }
        )
        let dias = (try? modelContext?.fetch(descriptor)) ?? []
        return dias.first(where: { $0.deletadoEm == nil }) ?? dias.first
    }

    /// Registro com edição ou exclusão ainda não enviada ao servidor: o refresh não pode
    /// sobrescrever os campos nem marcar `.synced` (o `SyncActor` sobe a versão local depois).
    static func temAlteracaoLocal(_ status: SyncStatus, deletadoEm: Date?) -> Bool {
        status != .synced || deletadoEm != nil
    }

    /// Duplicatas que já ficaram no aparelho (mesmo clientId, outro registro): os gastos delas
    /// passam para o dia que ficou e elas saem. Roda a cada carga dos dias do servidor.
    private func absorverDuplicatas(de dia: DiaSoftex) {
        let clientId = dia.clientId
        let id = dia.id
        let descriptor = FetchDescriptor<DiaSoftex>(
            predicate: #Predicate { $0.clientId == clientId && $0.id != id }
        )
        guard let outros = try? modelContext?.fetch(descriptor), !outros.isEmpty else { return }
        for outro in outros {
            for gasto in Array(outro.gastos) { gasto.dia = dia }
            modelContext?.delete(outro)
        }
    }

    /// Duplicatas de gasto que já ficaram no aparelho (mesmo `backendId` em registros
    /// diferentes): fica o que tem comprovante local ainda não enviado, senão o mais
    /// antigo; os outros saem do SwiftData. Roda a cada carga dos dias do servidor,
    /// junto com a dedup de dia (T6).
    private func absorverDuplicatasDeGasto(no dia: DiaSoftex) {
        for backendId in Set(dia.gastos.compactMap(\.backendId)) {
            let descriptor = FetchDescriptor<GastosDia>(
                predicate: #Predicate { $0.backendId == backendId }
            )
            guard let iguais = try? modelContext?.fetch(descriptor), iguais.count > 1 else { continue }
            guard let fica = iguais.first(where: { $0.comprovanteDataCriptografado != nil })
                ?? iguais.min(by: { $0.criadoEm < $1.criadoEm }) else { continue }
            for outro in iguais where outro.id != fica.id {
                modelContext?.delete(outro)
            }
        }
    }

    private func salvarOuAtualizarGastoLocal(_ gasto: GastosDia, no dia: DiaSoftex) {
        // Casa pelo backendId e, sem ele, pelo clientId dentro do mesmo dia: um gasto criado
        // no iPhone cujo POST o servidor já processou mas que ainda não tinha o backendId
        // gravado (resposta perdida ou refresh com o POST em voo) entrava como segundo
        // gasto, duplicando o lançamento na lista (T6).
        if let existente = gastoLocal(backendId: gasto.backendId)
            ?? gastoLocal(clientId: gasto.clientId, no: dia) {
            // T1: edição ou exclusão pendente vence a versão do servidor; só completa
            // o `backendId` para o próximo sync fazer PUT/DELETE em vez de POST.
            if Self.temAlteracaoLocal(existente.syncStatus, deletadoEm: existente.deletadoEm) {
                if existente.backendId == nil { existente.backendId = gasto.backendId }
                return
            }
            existente.backendId = gasto.backendId ?? existente.backendId
            existente.titulo = gasto.titulo
            existente.valor = gasto.valor
            existente.categoria = gasto.categoria
            existente.comprovanteUrl = gasto.comprovanteUrl
            existente.openFinanceStatusRaw = gasto.openFinanceStatusRaw
            existente.openFinanceMatchBackendId = gasto.openFinanceMatchBackendId
            existente.openFinanceTransactionBackendId = gasto.openFinanceTransactionBackendId
            existente.openFinanceProviderTransactionId = gasto.openFinanceProviderTransactionId
            existente.openFinanceTransactionDescription = gasto.openFinanceTransactionDescription
            existente.openFinanceTransactionAmount = gasto.openFinanceTransactionAmount
            existente.openFinanceTransactionDate = gasto.openFinanceTransactionDate
            existente.openFinanceMatchScore = gasto.openFinanceMatchScore
            existente.openFinanceMatchConfirmed = gasto.openFinanceMatchConfirmed
            existente.dia = dia
            existente.syncStatus = .synced
            existente.syncError = nil
            return
        }
        gasto.syncStatus = .synced
        gasto.syncError = nil
        gasto.dia = dia
        modelContext?.insert(gasto)
    }

    private func gastoLocal(backendId: Int?) -> GastosDia? {
        guard let backendId else { return nil }
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.backendId == backendId }
        )
        return try? modelContext?.fetch(descriptor).first
    }

    /// Prefere o gasto vivo; sem ele, devolve o que tem exclusão pendente (como `diaLocal(clientId:)`).
    private func gastoLocal(clientId: String, no dia: DiaSoftex) -> GastosDia? {
        let diaId = dia.id
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.clientId == clientId && $0.dia?.id == diaId }
        )
        let gastos = (try? modelContext?.fetch(descriptor)) ?? []
        return gastos.first(where: { $0.deletadoEm == nil }) ?? gastos.first
    }
    
    /// Upsert de um ciclo vindo do servidor: casa pelo `backendId` e, sem ele, pelo `clientId`.
    /// Interno (não `private`) para os testes.
    @discardableResult
    func salvarOuAtualizarCicloLocal(_ ciclo: CicloSoftex) -> CicloSoftex? {
        let userId = currentUser?.id ?? ""
        ciclo.userId = userId

        if let existente = buscarCicloLocal(backendId: ciclo.backendId, userId: userId)
            ?? buscarCicloLocal(clientId: ciclo.clientId, userId: userId) {
            // T1: edição ou exclusão pendente vence a versão (antiga) do servidor; só
            // completa o `backendId` para o próximo sync fazer PUT/DELETE em vez de POST.
            if Self.temAlteracaoLocal(existente.syncStatus, deletadoEm: existente.deletadoEm) {
                if existente.backendId == nil { existente.backendId = ciclo.backendId }
                return existente
            }
            existente.titulo = ciclo.titulo
            existente.valor_total = ciclo.valor_total
            existente.gasto_total = ciclo.gasto_total
            existente.periodo = ciclo.periodo
            existente.diaria = ciclo.diaria
            existente.backendId = ciclo.backendId ?? existente.backendId
            existente.userId = userId
            existente.syncStatus = .synced
            existente.syncError = nil
            return existente
        }

        ciclo.syncStatus = .synced
        ciclo.syncError = nil
        modelContext?.insert(ciclo)
        return ciclo
    }

    /// Inclui ciclos com exclusão pendente: casar com eles impede que o refresh os reviva.
    private func buscarCicloLocal(backendId: Int?, userId: String) -> CicloSoftex? {
        guard let backendId else { return nil }
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.backendId == backendId && $0.userId == userId }
        )
        return try? modelContext?.fetch(descriptor).first
    }

    private func buscarCicloLocal(clientId: String, userId: String) -> CicloSoftex? {
        let descriptor = FetchDescriptor<CicloSoftex>(
            predicate: #Predicate { $0.clientId == clientId && $0.userId == userId }
        )
        return try? modelContext?.fetch(descriptor).first
    }
    
    func createNewCiclo(startDate: Date, endDate: Date, totalValue: Decimal, titulo: String) async throws {
        let dayCount = Calendar.current.datesBetween(startDate, and: endDate)
        let safeDayCount = max(dayCount, 1)

        let saldo = totalValue / Decimal(safeDayCount)
        let periodo = createPeriodoString(from: startDate, to: endDate)

        let newCiclo = CicloSoftex(userId: currentUser?.id ?? "", valor_total: totalValue, gasto_total: Decimal(0), periodo: periodo, diaria: saldo, titulo: titulo, dias: nil)
        let dias: [DiaLoteRequest] = createAllDiasLoteRequest(dayCount: dayCount, startDate: startDate)
        
        try await postToNetwork(newCiclo: newCiclo, dias: dias)
    }
    
    func editCiclo(cicloId: Int, ciclo: CicloSoftex, dias: [DiaLoteRequest]? = nil) async {
        guard let cicloLocal = self.allCiclos.first(where: { $0.backendId == cicloId }) else {
            viewModelLogger.warning("editCiclo: ciclo nao encontrado allCiclos backendId=\(cicloId, privacy: .public)")
            return
        }

        viewModelLogger.info("editCiclo: atualizando cicloLocal backendId=\(cicloId, privacy: .public) titulo=\(ciclo.titulo, privacy: .private)")
        cicloLocal.titulo = ciclo.titulo
        cicloLocal.valor_total = ciclo.valor_total
        cicloLocal.diaria = ciclo.diaria
        cicloLocal.periodo = ciclo.periodo
        cicloLocal.syncStatus = .pending
        cicloLocal.syncError = nil

        if let novasDatas = dias, !novasDatas.isEmpty {
            let cal = Calendar.current
            let datasNovas = novasDatas.map { $0.data }

            if let diasExistentes = cicloLocal.dias {
                for dia in diasExistentes where dia.deletadoEm == nil {
                    if !datasNovas.contains(where: { cal.isDate($0, inSameDayAs: dia.data) }) {
                        dia.deletadoEm = Date()
                        dia.syncStatus = .pending
                        for gasto in dia.gastos where gasto.deletadoEm == nil {
                            gasto.deletadoEm = Date()
                            gasto.syncStatus = .pending
                            cicloLocal.gasto_total -= gasto.valor
                        }
                    }
                }
            }

            let diasVivos = cicloLocal.dias?.filter { $0.deletadoEm == nil } ?? []
            for novo in novasDatas {
                if !diasVivos.contains(where: { cal.isDate($0.data, inSameDayAs: novo.data) }) {
                    let dia = DiaSoftex(
                        clientId: novo.clientId ?? UUID().uuidString,
                        data: novo.data,
                        saldo: cicloLocal.diaria,
                        gastos: []
                    )
                    dia.ciclo = cicloLocal
                    modelContext?.insert(dia)
                    // Não faça append manual em relação inversa: definir dia.ciclo basta.
                }
            }
        }

        if let index = self.allCiclos.firstIndex(where: { $0.backendId == cicloId }) {
            self.allCiclos[index] = cicloLocal
        }

        if self.atualCiclo.backendId == cicloId {
            self.atualCiclo = cicloLocal
        }

        salvarLocal()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func deleteCiclo(ciclo: CicloSoftex) async throws {
        let cicloId = ciclo.id

        if let index = self.allCiclos.firstIndex(where: { $0.id == cicloId }) {
            self.allCiclos.remove(at: index)
        }

        if self.atualCiclo.id == cicloId {
            if let primeiroCiclo = self.cicloInicio ?? self.allCiclos.first {
                self.atualCiclo = primeiroCiclo
                if let firstIndex = self.allCiclos.firstIndex(of: primeiroCiclo) {
                    self.index = firstIndex
                } else {
                    self.index = 0
                }
            } else {
                self.atualCiclo = CicloSoftex.vazio
                self.index = 0
            }
        }

        if let _ = ciclo.backendId {
            ciclo.deletadoEm = Date()
            ciclo.syncStatus = .pending
            salvarLocal()

            Task {
                await SyncManager.shared.sync(forcar: true)
            }
        } else {
            modelContext?.delete(ciclo)
            salvarLocal()
        }
    }

    @available(*, deprecated, message: "Use deleteCiclo(ciclo:) com o objeto CicloSoftex")
    func deleteCiclo(cicloId: Int) async throws {
        guard let ciclo = self.allCiclos.first(where: { $0.backendId == cicloId }) else { return }
        try await deleteCiclo(ciclo: ciclo)
    }
    
    private func salvarCicloLocal(_ ciclo: CicloSoftex) {
        salvarOuAtualizarCicloLocal(ciclo)
        salvarLocal()
    }
    
    func createAllDiasLoteRequest(dayCount: Int, startDate: Date) -> [DiaLoteRequest] {
        var dias: [DiaLoteRequest] = []
        let calendar = Calendar.current
        let count = max(dayCount, 1)

        for i in 0..<count {
            if let date = calendar.date(byAdding: .day, value: i, to: startDate) {
                dias.append(DiaLoteRequest(clientId: UUID().uuidString, data: date))
            }
        }
        return dias
    }
    
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        return formatter
    }()

    private func createPeriodoString(from: Date, to: Date) -> String {
        let start = Self.shortDateFormatter.string(from: from)
        let end = Self.shortDateFormatter.string(from: to)
        return "\(start) - \(end)"
    }
    
    private func salvarNovoCicloLocal(_ ciclo: CicloSoftex, comDias diasRequests: [DiaLoteRequest]) {
        viewModelLogger.info("salvarNovoCicloLocal: inserindo ciclo id=\(ciclo.id, privacy: .public) clientId=\(ciclo.clientId, privacy: .private) userId=\(ciclo.userId, privacy: .private)")
        ciclo.syncStatus = .pending
        modelContext?.insert(ciclo)

        let dias: [DiaSoftex] = diasRequests.compactMap { req in
            let dia = DiaSoftex(clientId: req.clientId ?? UUID().uuidString, data: req.data, saldo: ciclo.diaria)
            dia.ciclo = ciclo
            dia.syncStatus = .pending
            modelContext?.insert(dia)
            return dia
        }
        ciclo.dias = dias
        salvarLocal()
        viewModelLogger.info("salvarNovoCicloLocal: save concluido, syncStatus=\(ciclo.syncStatus.rawValue, privacy: .public)")
    }
    
    private func postToNetwork(newCiclo: CicloSoftex, dias: [DiaLoteRequest]) async throws {
        salvarNovoCicloLocal(newCiclo, comDias: dias)

        self.allCiclos.insert(newCiclo, at: 0)
        self.atualCiclo = newCiclo
        self.index = 0

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func createNewGasto(title: String, value: Decimal, dia: DiaSoftex, categoria: Categoria, comprovante: Data? = nil, comprovanteMime: String = "image/jpeg") async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }

        guard self.atualCiclo.dias?.contains(where: { $0.id == dia.id }) == true else {
            throw APIError.serverError(message: "Dia selecionado não encontrado no ciclo atual", requestId: "-", statusCode: 404)
        }

        let novoGasto = GastosDia(
            valor: value,
            titulo: title,
            categoria: categoria,
            dia: dia,
            backendId: nil,
            comprovanteUrl: nil,
            comprovanteData: comprovante,
            comprovanteMime: comprovanteMime
        )

        modelContext.insert(novoGasto)

        self.atualCiclo.gasto_total += novoGasto.valor
        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }

        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }

    func anexarComprovante(gastoId: UUID, imageData: Data, mime: String = "image/jpeg") async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let gasto = encontrarGasto(id: gastoId) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        gasto.comprovanteData = imageData
        gasto.comprovanteMime = mime
        gasto.comprovanteParaRemover = false
        gasto.syncStatus = .pending
        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func removerComprovante(gastoId: UUID) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let gasto = encontrarGasto(id: gastoId) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        gasto.comprovanteData = nil
        gasto.comprovanteParaRemover = true
        gasto.syncStatus = .pending
        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    private func encontrarGasto(id: UUID) -> GastosDia? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<GastosDia>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor).first)
    }
    
    func deleteGasto(gastoID: UUID) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let dias = atualCiclo.dias else {
            throw APIError.serverError(message: "Ciclo atual não possui dias", requestId: "-", statusCode: 404)
        }
        
        var gastoParaDeletar: GastosDia?

        for dia in dias {
            if let gasto = dia.gastos.first(where: { $0.id == gastoID }) {
                gastoParaDeletar = gasto
                break
            }
        }

        guard let gasto = gastoParaDeletar else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }

        self.atualCiclo.gasto_total -= gasto.valor

        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }

        gasto.deletadoEm = Date()
        gasto.syncStatus = .pending
        try modelContext.save()

        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }
    
    func editGasto(gastoId: UUID, novoDia: DiaSoftex, titulo: String, value: Decimal, categoria: Categoria) async throws {
        guard let modelContext else {
            throw APIError.serverError(message: "Contexto do banco de dados não configurado", requestId: "-", statusCode: 500)
        }
        guard let dias = self.atualCiclo.dias else {
            throw APIError.serverError(message: "Ciclo atual não possui dias", requestId: "-", statusCode: 404)
        }
        guard let oldDiaIndex = dias.firstIndex(where: { $0.gastos.contains(where: { $0.id == gastoId }) }) else {
            throw APIError.serverError(message: "Dia do gasto não encontrado", requestId: "-", statusCode: 404)
        }
        guard let oldGastoIndex = dias[oldDiaIndex].gastos.firstIndex(where: { $0.id == gastoId }) else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }
        guard let newDiaIndex = dias.firstIndex(where: { $0.id == novoDia.id }) else {
            throw APIError.serverError(message: "Dia de destino não encontrado", requestId: "-", statusCode: 404)
        }
        guard let gastoLocal = self.atualCiclo.dias?[oldDiaIndex].gastos[oldGastoIndex] else {
            throw APIError.serverError(message: "Gasto não encontrado", requestId: "-", statusCode: 404)
        }

        let gastoAntigoValor = gastoLocal.valor
        let diferenca = value - gastoAntigoValor

        // Editar um gasto pode passar da diária: o saldo do dia fica negativo
        // e a interface mostra quanto passou.

        gastoLocal.titulo = titulo
        gastoLocal.valor = value
        gastoLocal.categoria = categoria
        gastoLocal.syncStatus = .pending
        gastoLocal.syncError = nil

        self.atualCiclo.gasto_total += diferenca

        if oldDiaIndex == newDiaIndex {
            self.atualCiclo.dias?[oldDiaIndex].saldo -= diferenca
        } else {
            self.atualCiclo.dias?[oldDiaIndex].saldo += gastoAntigoValor
            self.atualCiclo.dias?[newDiaIndex].saldo -= value
            // Apenas alteramos o relacionamento; não manipulamos o array
            // `gastos` manualmente, para evitar duplicatas no SwiftData.
            gastoLocal.dia = self.atualCiclo.dias?[newDiaIndex]
        }

        if self.index < self.allCiclos.count {
            self.allCiclos[self.index] = self.atualCiclo
        }
        
        try modelContext.save()
        
        Task {
            await SyncManager.shared.sync(forcar: true)
        }
    }

    func exportarCiclo(formato: ExportFormato, comprovantes: ExportComprovantes = .imagem) async throws -> URL {
        guard let cicloId = atualCiclo.backendId else {
            throw APIError.serverError(message: "Ciclo ainda não sincronizado com o servidor", requestId: "-", statusCode: 400)
        }

        let data = try await NetworkManager.shared.exportarCiclo(
            cicloId: cicloId,
            formato: formato,
            comprovantes: comprovantes
        )

        let nome = "relatorio_\(atualCiclo.titulo.filter { !$0.isWhitespace }).\(formato.extensao)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(nome)
        try data.write(to: url, options: .atomic)
        return url
    }
}
