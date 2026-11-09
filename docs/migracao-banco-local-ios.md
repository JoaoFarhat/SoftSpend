# Banco local do app iOS: schema V1 e plano de migração

Especificação para trocar o "fallback destrutivo" de `createModelContainer()`
(`SoftexVamo/SoftexVamo/SoftexVamoApp.swift`) por `VersionedSchema` +
`SchemaMigrationPlan` do SwiftData. Escrita em 09/11/2026 a partir da `main`
(commit `d809c94`). **Nenhum código Swift foi alterado nesta etapa.**

## 1. O problema, com precisão

Hoje o app abre o store `softspend_v1.sqlite` sem versão. Se o `ModelContainer`
lança erro, o `catch` **apaga o arquivo** e recria o banco vazio. O que se perde:
tudo que ainda não subiu para o backend (ciclo, dia e gasto com `syncStatus` ≠
`synced`, comprovantes pendentes). O que já foi sincronizado volta do backend.

Pontos que valem corrigir juntos:

- **Não é "qualquer mudança".** Sem plano, o SwiftData já faz migração leve
  automática para mudanças aditivas (campo novo opcional ou com default; foi
  assim com `comprovanteMime`). O fallback dispara quando a migração não pode ser
  inferida: troca de tipo, renomear campo, campo novo não opcional sem default,
  `.unique` novo, trocar `deleteRule`. Foi o que aconteceu com `UserModel.id`
  (Int → String) e com `userId` em `CicloSoftex`.
- **Bug extra:** o fallback remove só o `.sqlite` e deixa `-wal` e `-shm`
  órfãos ao lado, que podem corromper o banco recriado.
- O erro é logado só com `localizedDescription`, sem `userInfo`, e some.

## 2. Schema V1 (= o da `main` hoje)

V1 **tem que ser exatamente o schema atual**: o store existente foi criado sem
versão e só é reconhecido como V1 se o checksum bater. Por isso nenhum `@Model`
muda na tarefa. Só propriedades persistidas estão listadas (as `@Transient` ficam
de fora: `syncStatus`, `diaId`, `comprovanteData`, `comprovanteEhPdf`,
`openFinanceStatus`, `temComprovante`, `matchStatus`).

Enums persistidos: `Categoria` e `SyncStatus` (`String`, `Codable`). Mudar um
`rawValue` ou remover um caso exige migração.

### CicloSoftex
| Propriedade | Tipo | Observação |
| --- | --- | --- |
| `id` | `UUID` | `@Attribute(.unique)` |
| `clientId` | `String` | |
| `backendId` | `Int?` | |
| `userId` | `String` | |
| `valor_total`, `gasto_total`, `diaria` | `Decimal` | |
| `periodo`, `titulo` | `String` | |
| `dias` | `[DiaSoftex]?` | **opcional**; `.cascade`, inverso `DiaSoftex.ciclo` |
| `syncStatusRaw` | `String` | default `"pending"` |
| `syncError` | `String?` | |
| `tentativas` | `Int` | default `0` |
| `proximaTentativaEm` | `Date?` | |
| `criadoEm`, `atualizadoEm` | `Date` | default `Date.now` |
| `deletadoEm` | `Date?` | soft delete |

### DiaSoftex
| Propriedade | Tipo | Observação |
| --- | --- | --- |
| `id` | `UUID` | `.unique` |
| `clientId` | `String` | |
| `backendId` | `Int?` | |
| `ciclo` | `CicloSoftex?` | lado inverso |
| `gastos` | `[GastosDia]` | **não opcional**; `.cascade`, inverso `GastosDia.dia` |
| `data` | `Date` | |
| `saldo` | `Decimal` | |
| `syncStatusRaw`, `syncError`, `tentativas`, `proximaTentativaEm`, `criadoEm`, `atualizadoEm`, `deletadoEm` | como em `CicloSoftex` | |

### GastosDia
| Propriedade | Tipo | Observação |
| --- | --- | --- |
| `id` | `UUID` | `.unique` |
| `clientId` | `String` | |
| `backendId` | `Int?` | |
| `dia` | `DiaSoftex?` | lado inverso |
| `valor` | `Decimal` | |
| `titulo` | `String` | |
| `categoria` | `Categoria` | enum `Codable` persistido direto |
| `comprovanteUrl` | `String?` | |
| `comprovanteDataCriptografado` | `Data?` | AES-GCM; chave no Keychain |
| `comprovanteParaRemover` | `Bool` | default `false` |
| `comprovanteMime` | `String` | default `"image/jpeg"` |
| `syncStatusRaw`, `syncError`, `tentativas`, `proximaTentativaEm`, `criadoEm`, `atualizadoEm`, `deletadoEm` | como acima | |
| `openFinanceStatusRaw` | `String` | default `"PENDENTE"` |
| `openFinanceMatchBackendId`, `openFinanceTransactionBackendId`, `openFinanceMatchScore` | `Int?` | |
| `openFinanceProviderTransactionId`, `openFinanceTransactionDescription` | `String?` | |
| `openFinanceTransactionAmount` | `Decimal?` | |
| `openFinanceTransactionDate` | `Date?` | |
| `openFinanceMatchConfirmed` | `Bool` | default `false` |

### UserModel
| Propriedade | Tipo | Observação |
| --- | --- | --- |
| `id` | `String` | **sem `.unique`** |
| `nome`, `username`, `email` | `String` | |
| `syncStatus` | `SyncStatus` | **enum guardado direto** (os outros usam `syncStatusRaw`) |
| `criadoEm`, `atualizadoEm` | `Date` | default `Date.now` |

Também **não é `nonisolated`**, ao contrário dos outros.

### CartaoOpenFinance (somente leitura, cache)
`backendId: Int` (`.unique`), `userId`, `conexaoBackendId: Int`, `accountId: String`,
`institutionName`, `name`, `marketingName`, `numberLast4`, `currencyCode`, `brand`,
`level`, `status` (todos `String?`), `balance`, `creditLimit`, `availableCreditLimit`,
`minimumPayment` (`Decimal?`), `balanceCloseDate`, `balanceDueDate` (`Date?`),
`atualizadoEm` (default `Date.now`).
Relações: `faturas` `[FaturaCartao]` (`.cascade`, inverso `FaturaCartao.cartao`);
`transacoes` `[TransacaoCartao]` (`.cascade`, inverso `TransacaoCartao.cartao`).

### FaturaCartao (somente leitura, cache)
`backendId: Int` (`.unique`), `userId`, `billId: String`, `dueDate`, `closingDate` (`Date?`),
`totalAmount`, `minimumPaymentAmount` (`Decimal?`), `currencyCode: String?`,
`allowsInstallments: Bool?`, `cartao: CartaoOpenFinance?`, `atualizadoEm`.
Relação: `transacoes` `[TransacaoCartao]` com **`.nullify`**, inverso `TransacaoCartao.fatura`.

### TransacaoCartao (somente leitura, cache)
`backendId: Int` (`.unique`), `userId`, `transactionId: String`; `descricao`,
`descricaoRaw`, `merchantName`, `currencyCode`, `category`, `status`, `type`,
`providerCode`, `providerId`, `matchStatusRaw`, `matchMethod` (`String?`);
`amount`, `amountInAccountCurrency` (`Decimal?`); `date` (`Date?`);
`matchBackendId`, `matchGastoBackendId`, `matchScore` (`Int?`);
`matchConfirmedByUser: Bool` (default `false`); `cartao`, `fatura` (opcionais);
`atualizadoEm`.

### Irregularidades congeladas (não corrigir nesta tarefa)
Fazem parte do V1. Corrigir qualquer uma é **mudança de schema = V2** (seção 5):

- `UserModel.syncStatus` guarda o enum, `UserModel.id` sem `.unique`, `UserModel` sem `nonisolated`.
- `CicloSoftex.dias` opcional vs `DiaSoftex.gastos` não opcional.
- `FaturaCartao.transacoes` com `.nullify` (os outros usam `.cascade`).
- `GastosDia.categoria` como enum `Codable` persistido.

## 3. Plano de migração

**Decisão (técnica, minha):** menor diff. V1 aponta para as 7 classes vivas;
nenhuma cópia aninhada agora. Isso não toca os 6 arquivos de modelo e evita
conflito com o redesenho. Contrapartida: a primeira mudança de modelo exige
**congelar o V1 antes** (seção 5).

Arquivo novo `SoftexVamo/SoftexVamo/Models/SoftSpendSchema.swift`
(o projeto usa pasta sincronizada: arquivo novo entra sem editar o `.pbxproj`):

```swift
import SwiftData

nonisolated enum SoftSpendSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [CicloSoftex.self, DiaSoftex.self, GastosDia.self, UserModel.self,
         CartaoOpenFinance.self, FaturaCartao.self, TransacaoCartao.self]
    }
}

nonisolated enum SoftSpendMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SoftSpendSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
```

O `nonisolated` é necessário por causa de `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
(mesma regra do `AGENTS.md`). Se o compilador reclamar de isolamento, ajustar só
aqui.

Em `createModelContainer()`:

- `let schema = Schema(versionedSchema: SoftSpendSchemaV1.self)` e
  `ModelContainer(for: schema, migrationPlan: SoftSpendMigrationPlan.self, configurations: [config])`.
- **Manter** o nome `"softspend"` e o arquivo `softspend_v1.sqlite`. Renomear
  deixaria os dados atuais órfãos; o "v1" do nome é coincidência.
- **Trocar o fallback destrutivo por quarentena.** Se o container falhar:
  1. logar o erro completo (`String(describing: error)` e `(error as NSError).userInfo`);
  2. mover `softspend_v1.sqlite`, `-wal` e `-shm` para
     `Application Support/softspend-backup-<yyyyMMdd-HHmmss>/` (nunca `removeItem`);
  3. criar o banco novo; se ainda falhar, `fatalError` como hoje;
  4. logar o caminho do backup.
- Bancos criados por builds **anteriores** ao V1 (formas antigas do modelo) não
  batem com nenhuma versão do plano: caem na quarentena. Não vale reconstruir
  formas antigas. O que estava sincronizado volta do backend.
- Apagar o `TODO` e reescrever o comentário do método.

Comportamento esperado:

| Situação | Resultado |
| --- | --- |
| Store da `main` atual, abre com V1 | abre, dados intactos |
| Instalação nova | cria banco V1 |
| Store de build antiga, incompatível | quarentena + banco novo (dados recuperáveis no backup) |
| Erro inesperado | idem; nunca apaga |

## 4. Tarefa para o Devin

Está na nota do projeto, em "Tarefas do fluxo". Resumo do escopo:

- Só mexe em `SoftexVamoApp.swift` e no arquivo novo `Models/SoftSpendSchema.swift`.
  Nenhum `@Model` muda; não criar target de testes nem editar o `.pbxproj`.
- Não conflita com o redesenho: a branch `redesenho-visual` (hoje só docs) declara
  que a camada de dados não muda.
- Atualizar o `AGENTS.md`: nova seção curta com o `SoftSpendSchemaV1`, o plano e a
  quarentena no lugar do fallback.
- Pronto quando: (a) o `xcodebuild` do `AGENTS.md` compila; (b) **teste de upgrade
  no simulador (Mac):** instalar a build da `main`, criar offline 1 ciclo, 1 dia e
  1 gasto pendente com comprovante; instalar a build nova **por cima**, sem
  desinstalar; os dados continuam lá, o gasto sincroniza e o log não mostra
  "backup" nem "quarentena". (c) PR descreve o resultado do teste (b).

## 5. Regras para o V2 (a primeira mudança de modelo)

Fazer em PR separado, nesta ordem:

1. **Congelar o V1:** copiar só as propriedades armazenadas dos 7 modelos para
   dentro de `SoftSpendSchemaV1` como classes aninhadas (cópia fiel, sem
   `@Transient`, sem `init(from:)`). `SoftSpendSchemaV1.models` passa a apontar
   para as cópias.
2. Criar `SoftSpendSchemaV2` apontando para as classes vivas; `schemas = [V1, V2]`.
3. Conferir que o **nome da entidade** das cópias aninhadas continua igual ao do
   banco (`CicloSoftex`, não `SoftSpendSchemaV1.CicloSoftex`).
4. Escolher o stage: `.lightweight` para mudança aditiva; `.custom` quando mudar
   tipo, renomear ou converter dados (usar `@Attribute(originalName:)` para renome).
5. Duas versões com checksum igual dão erro; a mudança precisa ser real.
6. Mudar `rawValue` ou casos de `Categoria`/`SyncStatus` conta como mudança de dados.
7. Testar o upgrade V1 → V2 com a mesma receita da seção 4(b).

## 6. Pergunta em aberto (não bloqueia)

O app já foi distribuído (TestFlight ou outro) para alguém além dos aparelhos de
desenvolvimento? Não muda o plano, porque a quarentena protege qualquer banco
antigo, mas muda a urgência de mergear.
