# SoftSpend

Os gastos da viagem a trabalho, no controle. O SoftSpend é um app de iPhone para quem viaja a trabalho com diária: ele responde, sem conta de cabeça, quanto ainda dá para gastar hoje, mostra dia a dia se a diária estourou e não deixa comprovante se perder até a prestação de contas.

Este sistema vale para o app iOS (SwiftUI). Ele saiu do redesenho aprovado em 09/11/2026 (`docs/superpowers/specs/2026-11-09-redesenho-visual-design.md` no repositório `JoaoFarhat/SoftSpend`, branch `redesenho-visual`).

## Princípios

1. **Responder antes de enfeitar.** Toda tela de viagem responde quatro perguntas: quanto dá para gastar hoje, como estou indo dia a dia, estourei algum dia, falta algum comprovante.
2. **Um número por tela.** Só um valor usa `valor-destaque`; o resto é `valor-lista` ou `apoio`.
3. **Roxo é assinatura, não superfície.** `marca` aparece em poucos pontos: o "soft" do logo, o avião da rota, a barra do dia de hoje, links. O botão principal usa `marca-botao`. Cartões ficam em `superficie` com `borda` de 1px.
4. **Cor que significa algo, só para isso.** `estouro` (vermelho-tijolo) = passou da diária ou ação destrutiva. `alerta-*` (laranja) = falta comprovante ou 80% da diária. `ok` = comprovante anexado ou sobra do dia.
5. **Claro e escuro com o mesmo cuidado.** O app segue o tema do iPhone. Todo texto passa 4,5:1 nos dois temas.

## Voz

Português do Brasil, frases curtas, sem jargão financeiro. Fala do que a pessoa pode fazer agora.

- Sim: "Ainda dá para gastar hoje", "Passou R$ 38,00 da diária", "2 gastos sem comprovante".
- Não: "Saldo disponível do período", "Orçamento restante", "Preencha automaticamente com IA ✨".
- Datas como no Brasil (`23/07`, `20/07 → 25/07`); dinheiro sempre `R$ 1.183,00`, com algarismos alinhados (`mono`), qualquer que seja o idioma do aparelho.
- Acentos sempre certos ("Não tem conta?", "usuário").

## Fundamentos visuais

- **Fundo e superfície:** telas em `fundo`; cartões, listas e campos em `superficie` com `borda` e `raio-cartao` (listas) ou `raio-campo` (campos). Sem sombra, salvo o menu flutuante do avatar.
- **A passagem:** o cartão principal imita uma passagem: códigos DE/PARA em `codigo-rota`, linha tracejada com avião em `marca`, um picote (linha pontilhada em `borda` com dois semicírculos na cor `fundo` nas laterais) separando a rota dos números.
- **Barras por dia:** uma barra por dia do ciclo, altura = gasto do dia ÷ diária; `barra-dia` normal, `estouro` quando passou, `marca` para hoje, contorno tracejado em `barra-dia` para dias que ainda não chegaram; rótulo com o dia do mês embaixo, o de hoje em `marca-texto` e negrito.
- **Espaço:** margem lateral `espaco-3`; padding da passagem `espaco-4`; blocos separados por `espaco-6`.
- **Tipografia:** San Francisco (`sans`) para texto e SF Mono (`mono`) para todo número de dinheiro e códigos de rota.

## Iconografia

SF Symbols, nunca emoji. Categorias: Alimentação `fork.knife`, Transporte `car.fill`, Lazer `gamecontroller.fill`, Compras `bag.fill`, Outros `ellipsis.circle.fill`, cada uma num quadrado `raio-campo` na sua cor `cat-*` com glifo branco (`sobre-cor`). Ícones de interface (avião, câmera, menu) em traço, cor `texto` ou `marca`.

## O que não fazer

- Degradê roxo, brilho, estrelinhas de "IA", ilustração 3D, emoji como ícone.
- Grade de cartõezinhos iguais com ícone em quadradinho colorido para estatísticas.
- Cartão inteiro em roxo (`marca` como superfície).
- Selo que quebra em duas linhas.

## Componentes

`CartaoPassagem`, `BarrasPorDia`, `LinhaGasto`, `Selo`, `AlertaPendencia` e `Botoes`. Cada um tem guia e prévia nos dois temas.
