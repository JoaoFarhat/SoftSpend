# Data do dia sem depender do fuso

Especificação escrita em 25/11/2026. **Nenhum código foi alterado nesta etapa.**

## 1. O problema, com precisão

O app grava o `DiaSoftex.data` como **meia-noite local** (`Calendar.current`) e
manda ao servidor como instante UTC (`dateEncodingStrategy = .iso8601`, ex.:
`"2026-07-20T22:00:00Z"` para o dia 21/07 em Paris, UTC+2).

O servidor guarda esse instante em `dias.data` (`DateTime(timezone=True)`) e
tira o dia de calendário com `.date()` / `.strftime("%d/%m/%Y")` — ou seja, **em
UTC**:

| Fuso do aparelho | Meia-noite local em UTC | Dia que o servidor lê |
| --- | --- | --- |
| UTC−3 (Brasil) | 03:00Z do mesmo dia | certo |
| UTC+0 | 00:00Z | certo |
| UTC+1 … +14 (Europa, Ásia, Oceania) | 10:00Z–23:00Z do dia **anterior** | **um dia a menos** |

Onde isso aparece hoje (todos leem `dia.data` em UTC):

- `export_service._data` (relatório PDF/CSV) — data do dia, no título e na tabela;
  ordenação por `d.data` continua certa (é instante), só o texto erra.
- `fatura_service.marcar_previa` — `_data_da_coluna(dia.data)`: `dentro_da_viagem`,
  `dia_id` e a pontuação do match saem deslocados.
- `open_finance_reconciliation_service._data_gasto` — janela de data do match.

O app em si está certo: ele decodifica o mesmo instante e mostra no próprio
fuso. O erro é só nas contas **do servidor** sobre o "dia".

Dois problemas escondidos no mesmo ponto:

1. **Dois aparelhos em fusos diferentes** (ou a mesma pessoa viajando): o dia
   "21/07" vira instantes diferentes, e `isDate(_:inSameDayAs:)` no segundo
   aparelho pode cair no dia 20 ou 22.
2. **O instante não diz qual era o fuso.** Não dá para recuperar o dia certo
   só com o servidor, exceto pela heurística da seção 4.

## 2. Decisão: o dia passa a ser uma data de calendário (`YYYY-MM-DD`)

O dia da viagem é "o dia 21/07", não um instante. Passa a trafegar e a ser
guardado **como data de calendário**, sem hora nem fuso.

- **Fio (JSON):** novo campo `data_local` (string `"2026-07-21"`) em
  `DiaRequest` (`POST /ciclos/{id}/dias` e `/dias/lote`) e em `DiaResponse`.
  O campo `data` (instante) **continua existindo**, igual a hoje — apps antigos
  seguem funcionando sem mudar nada.
- **Banco:** nova coluna `dias.data_dia` (`Date`, anulável durante a migração).
- **Servidor:** toda conta de "dia" (relatório, prévia da fatura, conciliação)
  passa a ler `data_dia`, nunca `data`. `data` fica só como ordenação de
  compatibilidade e para o app antigo.
- **App:** manda `data_local` tirado dos componentes `ano/mês/dia` no
  `Calendar.current` do aparelho **no momento em que cria o dia** (nunca de
  `Date` convertido pelo servidor). Ao receber, se `data_local` vem na
  resposta, reconstrói `DiaSoftex.data` como o **início desse dia no fuso do
  aparelho** — assim dois aparelhos em fusos diferentes concordam sobre qual
  é o dia. Sem `data_local` (servidor antigo), usa `data` como hoje.

Por que não trocar `data` direto para só-data: quebraria os apps já instalados
(`DiaSoftexResponse.data: Date` não decodifica `"2026-07-21"` — a
`FaturaDTO` precisou de Codable próprio por isso). Campo novo e aditivo evita
isso e dispensa "versão mínima do app".

**Sem mudança de schema SwiftData** (o `Date` do `DiaSoftex` continua; só muda
de onde ele é calculado ao receber). Portanto **não precisa de V2** do
`SoftSpendSchemaV1`.

## 3. Regras do servidor

### 3.1 Entrada (`DiaRequest`)

- `data_local: date | None`. Validação de intervalo (±5 anos) passa a valer
  também para ele.
- Se vier `data_local`, ele manda: `data_dia = data_local`. O `data` recebido
  continua sendo gravado em `dias.data` como está (não é reescrito).
- Se **não** vier (app antigo), `data_dia = dia_de_calendario(data)` pela
  regra da seção 4 (a mesma do backfill).
- `client_id` e as unique constraints não mudam; reenvio devolve o existente
  como hoje (não recalcula `data_dia`).

### 3.2 Saída (`DiaResponse`)

- Devolve `data_local` = `data_dia` (`"YYYY-MM-DD"`). Para linha com
  `data_dia` nulo (não deveria sobrar depois do backfill), calcula pela regra
  da seção 4.

### 3.3 Uso interno

Um só helper, `services/dia_calendario.py`:

```python
def dia_de_calendario(instante: datetime) -> date: ...   # regra da seção 4
def data_do_dia(dia: models.Dia) -> date | None:         # data_dia ou fallback
```

`export_service._data`, `fatura_service._data_da_coluna(dia.data)` e
`open_finance_reconciliation_service._data_gasto` passam a usar
`data_do_dia`. A formatação do relatório vira `data.strftime("%d/%m/%Y")` sobre
`date` (sem `datetime`). Ordenação do relatório: por `data_dia`, desempate por
`id`.

Fora do escopo: `CreditCardBill.closing_date`/`due_date` e a `date` das
transações da fatura (`_meia_noite` em UTC) — já são datas guardadas e lidas
sempre em UTC, consistentes entre si; não dependem do fuso do aparelho.

## 4. Os dias já gravados (backfill) e o app antigo

Só existe o instante em UTC, que era "meia-noite local do aparelho". A hora
UTC revela o deslocamento (a hora é sempre inteira ou meia hora; o app não
grava dia fora de meia-noite local):

- hora UTC **≥ 11** → o aparelho estava a **leste** de Greenwich: o dia
  certo é o **dia UTC + 1**;
- hora UTC **< 11** (inclui 00:00Z e Brasil, 03:00Z) → mesmo dia UTC.

O corte em 11h é a única ambiguidade real: 10:00Z–12:00Z pode ser UTC−10…−12
(Havaí, Samoa) ou UTC+14…+12 (Nova Zelândia, Tonga, Kiribati). A regra escolhe
a leste a partir de 11h (Nova Zelândia/Tonga pesam mais que Samoa/Niue); 10h
(Havaí, UTC−10) fica como mesmo dia. Aceitável: nenhum usuário atual tem
esse fuso, e o app novo manda `data_local` e não depende da heurística.

Migration nova (Alembic, `down_revision` = o head atual; **aplicar nos dois
bancos**, regra do AGENTS.md):

1. `ADD COLUMN dias.data_dia DATE NULL`.
2. Backfill em lote por SQL/Python com a regra acima (não uma linha por
   `UPDATE` no app): `UPDATE dias SET data_dia = IF(HOUR(data) >= 11,
   DATE(data) + INTERVAL 1 DAY, DATE(data))`. Cuidado: `DATE(data)` e `HOUR()`
   operam no valor guardado — a coluna é gravada em UTC sem fuso pelo
   SQLAlchemy/MySQL; conferir em uma amostra do banco real antes de rodar.
3. Índice composto `(ciclo_id, data_dia)` (as leituras agrupam por viagem).
4. A coluna **continua anulável** (linha nova sempre preenche; o fallback
   cobre o resto). Sem `NOT NULL`, para não travar deploy.
5. Downgrade: `DROP COLUMN` (nada se perde: `data` segue intacta).

O app antigo continua mandando só `data`; o servidor aplica a mesma regra.
Ou seja, **a heurística também conserta quem não atualizar o app**, só que
sem a exatidão de `data_local`.

## 5. O app (iOS)

- `DiaSoftexResponse`/`DiaLoteRequest`: novo `dataLocal: String?`
  (`"yyyy-MM-dd"`, `CodingKeys` `data_local`). `DiaSoftexResponse.dataLocal` é
  opcional (servidor antigo).
- Helper puro `DiaDoCalendario` (nonisolated, testável): `texto(de:Date,
  calendario:)` → `"yyyy-MM-dd"` pelos componentes do calendário passado, e
  `inicioDoDia(de:String, calendario:)` → `Date?`. **Calendário e fuso
  entram por parâmetro** (padrão `.current`) — é isso que torna os testes
  independentes do fuso do CI.
- Envio: `postDiasLote`/`postDia` mandam `data_local = texto(de: dia.data)`.
- Recebimento: ao criar/atualizar `DiaSoftex` a partir da resposta, se
  `dataLocal` vem e o `inicioDoDia` difere do `dia.data` local, **atualiza
  `dia.data`** (início do dia no fuso do aparelho) — sem mexer em
  `syncStatus` de um dia que o usuário mexeu no meio (regra de
  `temAlteracaoLocal`).
- O resto do app (`isDate(_:inSameDayAs:)`, `EncurtarViagem`, `RegistroApplePay`)
  já compara em fuso local: não muda.

## 6. Testes (TDD, nomes sugeridos)

Servidor (`Python/tests/test_data_do_dia.py`):

- `dia_de_calendario`: tabela de horas UTC — `00:00Z`, `03:00Z` (Brasil),
  `10:00Z` (mesmo dia), `11:00Z`, `22:00Z` (Paris), `18:30Z` (Índia) → dia
  seguinte.
- `POST /dias` com `data_local` e `data` em desacordo: grava `data_dia =
  data_local`; resposta devolve `data_local`.
- `POST /dias` sem `data_local` (app antigo), `data = 2026-07-20T22:00:00Z`:
  `data_dia = 2026-07-21`.
- Lote misto (com e sem `data_local`).
- Relatório CSV/PDF de viagem em UTC+2: primeiro dia sai "21/07/2026"
  (hoje sai 20/07).
- `marcar_previa`: compra de 21/07 cai em `dentro_da_viagem` e `dia_id` do dia
  21/07 (hoje, em UTC+2, a compra de 21/07 cairia fora no primeiro dia).
- `_data_gasto` usa `data_do_dia`.
- Migration: backfill nas linhas de teste (`00:00Z`, `03:00Z`, `22:00Z`) e
  `downgrade` não perde dado.

App (`SoftSpendTests/DiaDoCalendarioTests.swift`, com `Calendar` de fuso
fixo montado no teste — Paris, São Paulo, Auckland):

- `texto(de:)` devolve o mesmo `"2026-07-21"` nos três fusos para a "meia-noite
  local de 21/07" de cada um.
- `inicioDoDia(de:)` volta à meia-noite local do calendário passado.
- Resposta com `data_local` num fuso e aparelho em outro: `dia.data` vira o
  início do dia no fuso do aparelho.
- Resposta sem `data_local`: nada muda (compat).
- `FakeSyncAPI` grava o `data_local` enviado para os testes de `DiasEmLote`
  conferirem.

## 7. Tarefas para o Devin (duas, na ordem)

**D1 — Servidor (uma PR).** Migration `dias.data_dia` + backfill + índice;
`services/dia_calendario.py`; `DiaRequest`/`DiaResponse` com `data_local`;
`dia_service.criar_dia`/`criar_dias_lote` preenchem `data_dia`; trocar os 3
usos de `dia.data` da seção 3.3; testes da seção 6 (servidor);
atualizar o `AGENTS.md` (migration nova na cadeia, seção "data do dia").
Rodar `pytest -q` com as chaves e aplicar a migration nos dois bancos.

**D2 — App iOS (PR separada, depois de D1 na `main` e no servidor).**
`DiaDoCalendario`, DTOs, envio e recebimento (seção 5), testes (seção 6),
nota no `AGENTS.md`. Sem `@Model` alterado → sem V2.

Ordem importa: o app novo contra servidor velho só manda um campo a mais
(ignorado), então D2 nunca quebra; o servidor novo contra app velho usa a
heurística. Pode subir D1 sozinho e já corrigir relatório/fatura no
fuso leste.

## 8. Perguntas para o usuário

Nenhuma bloqueante. Uma informação útil, não necessária: se há usuários
reais fora do Brasil — define só a urgência de D2, não o desenho.
