# SoftSpend

Os gastos da viagem a trabalho, no controle. O SoftSpend é um app de iPhone para quem viaja a trabalho com diária. Sem conta de cabeça, ele mostra quanto ainda dá para gastar hoje, mostra dia a dia se a diária estourou e não deixa comprovante se perder até a prestação de contas.

Este sistema vale para o app iOS (SwiftUI). Ele saiu do redesenho aprovado em 09/11/2026 e revisado no mesmo dia com o plugin frontend-design. A especificação está em `docs/superpowers/specs/2026-11-09-redesenho-visual-design.md`, no repositório `JoaoFarhat/SoftSpend`, branch `redesenho-visual`.

## A ideia

Um app de iPhone bem-feito, com **uma** assinatura: **a passagem**. Ela é o único objeto marcado da tela. Tem recortes nas laterais, picote tracejado e os códigos da rota e o valor de hoje na largura Expanded da SF Pro, como na sinalização de aeroporto. Todo o resto é iOS calmo: listas agrupadas, títulos em caixa normal, botões em pílula e o roxo em pouquíssimos pontos.

## Princípios

1. **Responder antes de enfeitar.** Toda tela de viagem responde quatro perguntas: quanto dá para gastar hoje, como estou indo dia a dia, estourei algum dia, falta alguma foto.
2. **Ousadia num lugar só.** Só a passagem usa `raio-passagem`, recortes e a família `larga`. Nada mais compete com ela.
3. **Roxo é assinatura, não superfície.** `marca` só no símbolo do logo, no avião da rota e na barra de hoje; `marca-botao` só no botão principal; `marca-texto` nos links.
4. **Cor que significa algo, só para isso.** `estouro` = passou da diária ou ação destrutiva; `alerta-*` = falta foto ou 80% da diária; `ok` = anexado ou sobra do dia.
5. **Nativo nos dois temas.** O fundo é o cinza agrupado do iOS no claro e o preto puro no escuro. Separação por contraste de superfície, não por borda.

## Voz

Português do Brasil, frases curtas, com o vocabulário de quem viaja e sem jargão financeiro.

- Sim: "Ainda dá para gastar hoje", "Você gastou R$ 147,70 dos R$ 450 de hoje", "2 gastos sem foto", "Falta a foto", "Adicionar", "20 a 25 de julho".
- Não: "Saldo disponível", "diária R$ 450 · gasto hoje R$ 147,70", "20/07 → 25/07", "Resolver", "Preencha automaticamente com IA ✨".
- Sem pontinhos (·) ligando dados e sem setas no texto: escreva a frase.
- Títulos e rótulos em caixa normal ("Hoje", "Antes de gerar"). A caixa alta só aparece nos códigos da passagem (SAO, CGB), como num bilhete de verdade.
- O mesmo nome do começo ao fim: o botão "Fotografar comprovante" leva a "Salvar gasto", e o aviso diz "Gasto salvo".
- Dinheiro sempre `R$ 1.183,00`, com algarismos tabulares, em qualquer idioma do aparelho. Acentos sempre certos.

## Fundamentos visuais

- **Fundo e superfície:** telas em `fundo`; listas, campos e a passagem em `superficie`, sem borda. As divisórias de lista são `borda` a 0,5 pt.
- **A passagem:** `raio-passagem`. Cidade em `apoio` sobre o código em `codigo-rota`, com um avião em `marca` entre os dois. Embaixo, o período por extenso ("20 a 25 de julho") e "4º de 6 dias". Depois vêm o picote tracejado em `borda` com recortes circulares na cor `fundo` nas laterais, o valor em `valor-destaque` e a frase de apoio.
- **Barras por dia:** uma por dia, com altura igual a gasto ÷ diária. `barra-dia` para dia normal, `estouro` para dia que passou, `marca` para hoje e tracejado para os dias que ainda vêm. O dia do mês fica embaixo.
- **Listas:** inset grouped do iOS, `raio-lista`; cabeçalho em `titulo-secao` ("Hoje"), link à direita em `marca-texto` ("Todos os gastos").
- **Botões:** `raio-pilula`. O principal em `marca-botao`, um por tela; o secundário em `superficie`.

## Tipografia

- **SF Pro** (`sans`) em toda a interface, nos tamanhos do iOS e com Dynamic Type.
- **SF Pro Expanded** (`larga`) só na passagem e no valor de destaque. Em SwiftUI: `.font(.system(size: 30, weight: .heavy)).fontWidth(.expanded)`. Na web e nos esboços, Archivo a 125% de largura faz as vezes dela.
- Números de dinheiro em SF Pro com `.monospacedDigit()`. Nunca fonte mono.

## Iconografia

SF Symbols, nunca emoji. Categorias: Alimentação `fork.knife`, Transporte `car.fill`, Lazer `gamecontroller.fill`, Compras `bag.fill`, Outros `ellipsis.circle.fill`. Cada uma num quadrado de 8–10 px de raio, na sua cor `cat-*`, com glifo branco. O símbolo do logo é um bilhete roxo com dois recortes.

## O que não fazer

- Degradê, brilho, estrelinhas de "IA", ilustração 3D, emoji como ícone.
- Uma palavra colorida no meio do nome ou do título.
- Caixa alta espaçada em rótulos, pontinhos ligando dados, setas no texto.
- Grade de cartõezinhos iguais, todos com a mesma borda e o mesmo arredondado.
- Fonte mono para números.
- Cartão inteiro em roxo.

## Componentes

`CartaoPassagem`, `BarrasPorDia`, `LinhaGasto`, `Selo`, `AlertaPendencia` e `Botoes`. Cada um tem guia e prévia nos dois temas.
