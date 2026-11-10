# Redesenho visual do app iOS (SoftSpend) — design

Data: 09/11/2026. Decidido com o João (dono do produto) numa conversa de brainstorming com esboços no navegador.

## Por que

O app funciona, mas tem "cara de app feito por IA": roxo em degradê em todo lugar, mala 3D, "Preencha automaticamente com IA" com brilhos, grade de cartõezinhos iguais com ícone em quadradinho, tudo com o mesmo arredondado. E a tela de início responde a pergunta errada: dá destaque ao total da viagem, enquanto quem está viajando quer saber **quanto ainda pode gastar hoje**.

## Para quem

Quem faz viagem a trabalho e recebe **diária** da empresa (ex.: R$ 450/dia). Antes da viagem cria um ciclo (cidade, datas, diária → teto = diária × dias); durante, lança cada gasto tirando foto do comprovante, quase sempre com pressa (no caixa, no táxi); no fim pode gerar um PDF.

Dores, nas palavras do usuário: perder comprovantes e montar a prestação de contas; estourar a diária também.

Com diária, a empresa do usuário **não exigia** prestação de contas. A prestação (conciliação) existia para quem usa **cartão corporativo**: no site da empresa, para cada gasto do cartão era preciso anexar o comprovante e conferir se **valor e data** batiam; se não batesse, refazia. Esse modo fica para depois (ver Não-objetivos).

## Objetivos

1. A tela de início responde, sem precisar interpretar, quatro perguntas:
   quanto ainda posso gastar hoje; como estou indo dia a dia; estourei algum dia; tenho pendência (gasto sem comprovante).
2. Lançar um gasto pela foto do comprovante em no máximo 2 toques a partir do início.
3. Identidade própria do SoftSpend, moderna, sem os sinais de "cara de IA" listados acima.
4. Funciona igualmente bem nos temas claro e escuro (o app segue o tema do iPhone).
5. Nada do que já funciona se perde: login, cadastro, sincronização offline-first, leitura do comprovante pela IA, exportação PDF/CSV, histórico.

## Não-objetivos

- **Conciliação do cartão corporativo** (cruzar gastos do cartão com comprovantes por valor e data): a tela é **desenhada** neste projeto, mas **não programada**. Entra quando existir uma fonte dos gastos do cartão (Open Finance está desligado pelo custo; importar a fatura em CSV/OFX é a alternativa, decisão futura do usuário).
- Mudanças no backend (`Python/`).
- Mudar a lógica de dados (SwiftData, `SyncActor`, `NetworkManager`, DTOs). Só a camada visual muda; se uma tela precisar de um dado novo calculado, ele é derivado no ViewModel a partir do que já existe.
- App Android ou web.

## Anti-objetivos (se acontecer, falhou mesmo funcionando)

- Degradês roxos, brilhos/estrelinhas de "IA", ilustração 3D, emoji como ícone, grade de cartões iguais com ícone em quadradinho colorido.
- O usuário ter que somar ou comparar números de cabeça para saber se pode gastar.
- Tema claro tratado como segunda classe (contraste ruim, cores do escuro reaproveitadas).
- Alguma função que funciona hoje parar de funcionar.

## Restrições

- SwiftUI, projeto `SoftexVamo/SoftSpend.xcodeproj`, scheme `SoftSpend`. Swift 6 com `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (ver `AGENTS.md`).
- Só compila no Mac. Verificação visual de cada tela: build + simulador + captura (`xcrun simctl io booted screenshot`), comparada com o esboço aprovado, nos dois temas.
- Cores como Color Sets do `Assets.xcassets` com variante clara e escura (o app já usa cores por nome: `textPrimary`, `textSecondary`, `cardBackground`, `surfaceBackground` etc.).
- Ícones: SF Symbols (os emojis dos esboços eram só esboço).
- Acessibilidade: Dynamic Type nos textos, contraste AA nos dois temas, VoiceOver lendo o valor de "dá para gastar hoje" e o estado de cada dia.

## Abordagens consideradas

1. **Base primeiro, tela por tela, no app atual (escolhida).** Tokens (cores claro/escuro, tipografia, espaçamentos, raios) e componentes reaproveitáveis primeiro; depois cada tela refeita com eles, uma por vez, com o app funcionando o tempo todo. Antes de programar cada grupo de telas, um esboço rápido é mostrado ao usuário para aprovação.
2. **Desenhar as 13 telas antes de programar** (Claude Design). Mais coerente desde o início, porém mais lento até ver algo no aparelho, e algumas decisões só aparecem no iPhone.
3. **Reescrever a interface num projeto novo.** Descartada: joga fora login, sync offline e exportação que funcionam; risco alto.

Escolhida a 1 pelo usuário: entrega mais rápido, não arrisca o que funciona, e o ajuste de "esboço antes de cada grupo" mantém o controle do visual.

**Ajuste do usuário (09/11):** em vez de esboço por grupo, ele quis ver **todas as telas antes do código**. As 18 telas foram desenhadas e **aprovadas**: [`telas/2026-11-09-todas-as-telas.html`](telas/2026-11-09-todas-as-telas.html) (abrir no navegador; o botão troca claro/escuro). Elas são a referência visual do construtor; o código segue a ordem de entrega abaixo, sem novas paradas para esboço. O trabalho acontece na branch `redesenho-visual`, para manter a versão antiga na `main`.

## Decisões de visual (tomadas pelo usuário)

- **Estrutura do início:** a do esboço "cartão de embarque" (ver abaixo).
- **Identidade:** a do SoftSpend, com **roxo como marca** (opção 1): roxo só em poucos pontos — logo, ícone de avião da rota, barra do dia de hoje, botão principal. Superfícies neutras (cinza/grafite no escuro, branco/cinza-claro no claro). O roxo como superfície do cartão (opção 2) foi rejeitado.
- **Ícones de categoria coloridos** continuam (ex.: Alimentação laranja, Transporte azul), em SF Symbols.
- **Temas claro e escuro** desde o início.

### Revisão frontend-design (09/11, aprovada pelo usuário)

As 18 telas foram revistas com o plugin frontend-design para tirar os sinais de "interface gerada". A estrutura não mudou; mudou o acabamento:

- **Uma assinatura só: a passagem.** É o único objeto marcado (raio 20, recortes laterais, picote tracejado). Os códigos da rota (SAO, CGB) e o valor de destaque usam **SF Pro Expanded** (`.fontWidth(.expanded)`), como na sinalização de aeroporto. O resto é iOS nativo: listas agrupadas sem borda, títulos em caixa normal e botões em pílula.
- **Logo:** um nome só, "SoftSpend", com um símbolo de bilhete roxo; sai o "**soft**spend" de duas cores.
- **Texto:** sem rótulos em CAIXA ALTA espaçada (exceto os códigos da passagem), sem pontinhos (·) ligando dados, sem setas no texto, sempre escrevendo a frase ("Você gastou R$ 147,70 dos R$ 450 de hoje", "20 a 25 de julho", "4º de 6 dias", "2 gastos sem foto", "Falta a foto", "Adicionar", "Todos os gastos").
- **Números:** SF Pro com algarismos tabulares (`.monospacedDigit()`); **não** usar fonte mono.
- **Cores:** as do iOS (fundo #F2F2F7 / #000, superfície #FFF / #1C1C1E); cartões sem borda; selo de categoria neutro; ícones de categoria mais escuros para o glifo branco ter contraste.

### Paleta (valores completos e regras de uso: `design-system/tokens.json`)

| Papel | Claro | Escuro |
|---|---|---|
| Fundo | #F2F2F7 | #000000 |
| Superfície (passagem, listas, campos) | #FFFFFF | #1C1C1E |
| Superfície 2 (chips, selos) | #E9E8EE | #2C2C2E |
| Divisória de lista | #E3E1E8 | #2C2C2E |
| Texto | #1C1B1F | #F5F4F7 |
| Texto fraco | #6B6870 | #9A98A1 |
| Barra de dia normal | #D9D6DF | #3A3A3E |
| Roxo da marca (logo, avião, barra de hoje) | #6D28D9 | #8B5CF6 |
| Botão principal | #6D28D9 | #6D28D9 |
| Link | #6D28D9 | #C4B2FF |
| Dia estourado (vermelho-tijolo) | #B93A0C | #EF6A45 |
| Pendência texto / fundo | #A14800 / #FFF3E2 | #F3A957 / #2B1F12 |
| Confirmado texto / fundo | #15803D / #E7F6EC | #4ADE80 / #12261A |

Referência viva: Design System "SoftSpend" (https://claude.ai/artifact/Ata2yxRut3wkQGMvv2Epad) e canvas com as 18 telas (https://claude.ai/artifact/7NmBpiyCPVAfEPYqSPFoWd), privados do João; a cópia no repositório é `design-system/` e `telas/`.

## Telas

### Início (aprovada em esboço)

De cima para baixo:

1. Barra: logo (símbolo de bilhete roxo + "SoftSpend") à esquerda; avatar com iniciais à direita (abre o menu/perfil).
2. **Cartão da passagem** (superfície, sem borda, cantos 20pt, recortes laterais):
   - nome da cidade pequeno sobre o código de 3 letras (SF Pro Expanded), origem à esquerda, destino à direita, avião roxo entre os dois. Os códigos vêm da cidade do ciclo (ver "Deixado ao construtor");
   - "20 a 25 de julho" à esquerda, "4º de 6 dias" à direita;
   - picote: linha tracejada com dois recortes circulares nas laterais (cor do fundo);
   - "Ainda dá para gastar hoje" + **valor grande** em SF Pro Expanded (= diária − gasto do dia; negativo aparece como "Passou R$ X hoje" em vermelho-tijolo);
   - "Você gastou R$ 147,70 dos R$ 450 de hoje";
   - **barras por dia**: uma por dia do ciclo; altura = gasto do dia / diária (com teto visual); dia acima da diária em vermelho-tijolo; hoje em roxo; dias futuros tracejados; rótulo do dia do mês embaixo.
3. **Alerta de pendência** (só se houver): "N gastos sem foto" + "Adicionar" (abre a lista filtrada pelos sem foto).
4. "Hoje" (título de seção) + "Todos os gastos" à direita + lista agrupada dos gastos do dia: ícone da categoria (quadrado arredondado colorido com SF Symbol), nome, linha de apoio "Categoria, hora" **ou** "Falta a foto" (laranja), valor à direita. Nada quebra linha (corrige o "Aguardan do fatura" de hoje).
5. Rodapé fixo: botão principal em pílula roxa "Fotografar comprovante" (abre a câmera direto) + botão secundário redondo "＋" (lançar sem foto).

Some do início: a grade de "Orçamento diário / Gasto hoje / Restam hoje", "Média diária" (que mostrava o mesmo valor do orçamento diário — bug), a mala 3D, a lista longa de todos os gastos (vai para "Todos os gastos").

Sem ciclo ativo: estado vazio com uma frase e o botão "Nova viagem".

### Demais telas (do mapa aprovado; cada grupo ganha esboço antes de ser programado)

- **Entrar / Criar conta:** só os campos e o botão, sem enfeite; acentos corrigidos ("Não tem conta?", "começar", "usuário"); botão com contraste correto.
- **Nova viagem:** cidade, datas e os campos ligados total ↔ diária (ver "Decisões do usuário" abaixo). Opção "uso cartão corporativo" aparece desabilitada com "em breve" (ou oculta enquanto `GET /api/features` disser `open_finance: false`, como o menu já faz). **(10/11, decisão do usuário: nada de "em breve" no app; a App Store recusa recurso anunciado que não existe. A opção do cartão sai da Nova viagem e só volta quando o recurso funcionar.)**
- **Câmera:** abre direto do botão principal; ao tirar a foto, a leitura do comprovante (a mesma de hoje) preenche valor, local, data e categoria.
- **Confirmar gasto:** mostra o que foi lido para corrigir e salvar; também serve para lançar sem foto e anexar depois. Sem "com IA" e sem brilhos: a leitura é um detalhe, não um anúncio.
- **Detalhe do gasto:** foto do comprovante grande, editar, apagar.
- **Todos os gastos:** lista por dia, busca e filtro por categoria e por "sem comprovante".
- **Aviso de diária:** notificação local ao passar de 80% da diária do dia e ao estourar (uma de cada por dia).
- **Fim da viagem / PDF:** checklist do que falta (gastos sem foto) e geração do PDF/CSV com a exportação que já existe, com o visual novo. Para diária é um extra, não uma etapa obrigatória.
- **Viagens:** as anteriores, com total e acesso ao PDF.
- **Perfil e ajustes:** nome, e-mail; **sem** o seletor "Ambiente API Local/Produção" para o usuário comum (fica só em build de desenvolvimento).
- **Conciliação do cartão (só desenho):** lista de transações do cartão, cada uma com estado ✓ confere / ⚠ valor diferente / ⚠ data diferente / sem comprovante, e o envio só liberado com tudo ✓. Não programar.

## Componentes base

`CartaoPassagem`, `BarrasPorDia`, `LinhaGasto`, `SeloCategoria`/`SeloPendencia`, `AlertaPendencia`, `BotaoPrincipal`/`BotaoSecundario`, `IconeCategoria`, `ValorMonetario` (formatação BRL monoespaçada), mais os tokens de cor/tipografia/espaçamento. Todos com preview SwiftUI nos dois temas.

## Ordem de entrega

1. Tokens + componentes base (com previews claro/escuro).
2. Início.
3. Lançar gasto: câmera → confirmar → detalhe.
4. Todos os gastos + aviso de diária.
5. Nova viagem + Viagens.
6. Fim da viagem/PDF + Perfil/ajustes + Entrar/Criar conta.
7. Esboço (não código) da conciliação do cartão.

Cada passo: código seguindo a tela aprovada → build → captura no simulador nos dois temas, comparada com a tela → commit.

## Deixado ao construtor

- Valores exatos de espaçamento, raios e tamanhos de fonte (seguir os esboços e o padrão do iOS).
- De onde vêm os códigos de 3 letras da cidade (DE/PARA): sugestão — código IATA do aeroporto mais próximo quando conhecido, senão as 3 primeiras letras sem acento em maiúsculas; a origem pode ser omitida se o ciclo não tiver origem cadastrada.
- Animações sutis (ex.: barra de hoje crescendo ao lançar um gasto), desde que não atrasem o lançamento.
- Nomes dos arquivos/Views novos, seguindo a organização atual (`Scenes/`, `SubViews/`).

## Respostas à revisão do construtor (09/11)

Decisões tomadas pelo Claude (arquiteto) como padrão razoável; o usuário pode corrigir:

- **Open Finance existente** (`OpenFinanceView`, `FaturaDetalheView`, selo "Aguardando fatura"): o código fica, escondido. O menu esconde "Cartão corporativo" pelo `GET /api/features` dos PRs #1 (backend) e #3 (app), ainda **não mergeados** em 09/11; o PR #3 já trata "sem resposta" como desligado, então o redesenho não depende do merge. O selo "Aguardando fatura" só aparece com `open_finance: true`; com ele desligado, a linha de gasto mostra só categoria ou "sem comprovante". As telas do Open Finance não entram no redesenho agora (entram junto com a conciliação).
- **Navegação (revista em 10/11, decisão do usuário: só pelo avatar as telas ficavam escondidas):** barra de abas embaixo com **Início, Viagens e Gastos**, desenhada à mão como a do Safeel (ícone, nome em negrito na aba ativa e traço embaixo; tocar de novo na aba volta para a raiz), cada aba com a própria pilha; o avatar fica só com Perfil e ajustes e Sair (e o ambiente da API no DEBUG); "Fechar viagem e PDF" fica no início e em Viagens. **Títulos (10/11):** grandes só na raiz das abas (Viagens, Gastos), que encolhem ao rolar; telas abertas por cima com título pequeno no centro; Gastos com título curto e a viagem no subtítulo ("Florianópolis · 10 a 17 de novembro"); Nova/Editar viagem com barra fixa no topo ("Cancelar" e o título pequeno). *Texto original:* a barra de abas (Início / Histórico) sai. O início tem: avatar → menu (Viagens, Todos os gastos, Fim da viagem/PDF, Perfil e ajustes, Sair); "Ver todos" ao lado de "HOJE" → Todos os gastos; o rodapé "Fotografar comprovante" + "＋". "Nova viagem" fica em Viagens e no estado vazio do início. A exportação sai do `Menu` de `CiclosListView` e vai para Fim da viagem/PDF (também acessível em cada viagem de Viagens).
- **Ciclo ativo:** passa a ser o que **contém a data de hoje** (sobreposição: o de início mais recente). Sem ciclo hoje: se há um ciclo futuro, o cartão da passagem mostra "começa em N dias" e o teto, sem barras de hoje; se o último ciclo terminou, o cartão mostra "viagem encerrada" com o botão "Fechar viagem" (Fim da viagem/PDF); senão, o estado vazio "Nova viagem". Abrir um ciclo pelo Viagens não troca o ciclo ativo do início: abre o detalhe daquela viagem. (Isso é ajuste no ViewModel de seleção, não na persistência.)
- **Contagem de dias:** inclui o primeiro e o último (decisão do usuário de 08/11: 01/09 a 07/09 = 7 dias), como o `datesBetween` atual.
- **Consentimento da leitura por IA:** obrigatório (regra do `AGENTS.md`, LGPD). Uma vez, no primeiro uso da câmera: tela curta explicando que a foto vai para leitura automática, com "Permitir" e "Agora não" (sem permitir, lança manual com a foto anexada). Depois disso a meta de 2 toques vale.
- **Esboços:** substituídos pelas 18 telas aprovadas (ver Abordagens).

Decisões do usuário (09/11):

- **Passar da diária é permitido** no modo diária, ao criar **e** ao editar um gasto: o app só avisa (barra vermelha, "Passou R$ X hoje", notificação). Motivo: o viajante recebe o valor cheio; o gasto aconteceu e precisa ser registrado. Sai o bloqueio "Saldo do dia insuficiente" do `editGasto` (única mudança de regra permitida neste projeto). No modo **cartão corporativo** (futuro), o limite por dia valia de verdade: o que passasse virava **reembolso** que o viajante devolvia à empresa; a tela de conciliação desenhada deve mostrar esse valor a reembolsar.
- **Nova viagem com dois campos ligados: total da viagem ↔ diária** (preencher um calcula o outro, dias × diária = total). Motivo: "tudo depende". No modo diária, o campo principal é o **total** (o valor que o viajante recebe já vem descontado do hotel, que a empresa paga); no modo cartão, o principal seria a **diária**. Edição de viagens antigas continua pelo total. O backend segue recebendo o total, como hoje.

## Fora deste repositório

- O visual do PDF gerado (tela 15) fica para uma tarefa de backend: o PDF e o CSV são montados pelo servidor (`GET /ciclos/{id}/export`, em `Python/`), e o app só baixa e compartilha o arquivo.
- A tarefa do fluxo da Vixyt para SoftSpend que mexer em telas deve ficar pausada enquanto o redesenho estiver em andamento, para não conflitar.
