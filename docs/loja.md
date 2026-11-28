# Ficha da loja (App Store Connect) — SoftSpend

Estado: 15/11/2026. Textos prontos para colar no App Store Connect. Só documento: nada aqui muda o app. Origem dos fatos: `docs/publicacao.md` §2, `docs/assinatura.md`, `PrivacyInfo.xcprivacy`, `Debug/DemoInicio.swift`.

Passo a passo até o envio: `docs/roteiro-envio.md`.

Pendente do usuário antes de enviar: a conta Apple paga, as URLs publicadas no ar, as caixas `suporte@` e `privacidade@` criadas e, nas notas da revisão (§8), o e-mail e a senha da conta de demonstração (a senha nunca vai para o repositório).

## 1. Dados do app

| Campo | Valor | Limite |
|---|---|---|
| Nome | SoftSpend: gastos de viagem | 30 caracteres (tem 27) |
| Subtítulo | Controle a diária da viagem | 30 (tem 27) |
| Bundle ID | `br.com.softspend.app` | não muda depois de criado |
| Categoria principal | Finanças | |
| Categoria secundária | Produtividade (opcional) | |
| Idioma principal | Português (Brasil) | |
| Disponibilidade | só Brasil (v1) | |
| iOS mínimo | 17.0 (como no projeto) | |
| Dispositivos | iPhone e iPad (`TARGETED_DEVICE_FAMILY = 1,2`); decisão do usuário em 15/11: **com iPad na v1** | exige capturas de iPad 13" e a Apple testa no iPad |
| Preço do app | Grátis, com assinatura dentro do app | |
| URL de suporte | https://softspend.com.br/suporte | obrigatória |
| URL de privacidade | https://softspend.com.br/privacidade | obrigatória |
| URL de marketing | (vazio) | opcional |
| Direitos autorais | `© 2026 PURPTECH INOVA SIMPLES (I.S.)` | titular da conta Apple (CNPJ 69.904.033/0001-62) |

Se o nome estiver ocupado na loja, o plano B é "SoftSpend: diária de viagem".

## 2. Descrição

Texto para o campo "Descrição" (limite 4.000 caracteres; este tem cerca de 1.400):

> Viajou a trabalho e precisa controlar quanto gastou da diária? O SoftSpend mostra, dia a dia, quanto você ainda pode gastar.
>
> Crie uma viagem com as datas e o valor da diária. O app divide o orçamento pelos dias e avisa quando você chega perto do limite do dia ou passa dele. O que sobra de um dia entra no saldo do seguinte.
>
> LANCE O GASTO DO JEITO MAIS RÁPIDO
> • Fotografe o comprovante: a leitura por IA preenche valor, local, data e categoria. Você confere antes de salvar.
> • Lance à mão, em poucos toques.
> • Registre compras do Apple Pay pelo atalho "Registrar gasto" do app Atalhos.
> • Importe a fatura do cartão (PDF, OFX ou CSV) e veja quais compras já estão lançadas e quais faltam.
>
> TUDO ORGANIZADO PARA A PRESTAÇÃO DE CONTAS
> • Gastos por dia, por categoria e com a foto da nota guardada.
> • Exporte a viagem para enviar ao financeiro.
> • Funciona sem internet: você lança no aviãozinho e o app sincroniza quando a conexão volta.
>
> SEUS DADOS, SOB SEU CONTROLE
> • A leitura por IA só acontece se você autorizar, e você pode recusar e lançar à mão.
> • Sem anúncios e sem rastreamento.
> • Exclua a conta quando quiser, no próprio app (Perfil > Excluir conta).
>
> ASSINATURA
> Teste grátis por 14 dias. Depois, R$ 14,90 por mês ou R$ 144,90 por ano, cobrados na sua conta Apple. Sem assinatura ativa você continua vendo e editando seus gastos; criar nova viagem, ler comprovante com IA, importar fatura e exportar pedem assinatura.
>
> Termos de Uso: https://softspend.com.br/termos
> Política de Privacidade: https://softspend.com.br/privacidade

Texto promocional (170 caracteres, pode mudar sem nova versão):

> Fotografe a nota, veja quanto ainda pode gastar hoje e leve a prestação de contas pronta. 14 dias grátis.

"O que há de novo" da versão 1.0:

> Primeira versão do SoftSpend.

## 3. Palavras-chave

Limite de 100 caracteres, separadas por vírgula, sem espaço depois da vírgula (96 no total). Não repetir o nome nem a categoria.

```
viagem,diária,gastos,despesas,reembolso,comprovante,nota fiscal,fatura,cartão,orçamento,controle
```

## 4. Classificação etária

Questionário da Apple: responder **nenhum/não** em todos os itens de conteúdo (violência, sexo, apostas, álcool, terror, etc.), sem acesso irrestrito à web e sem conteúdo gerado por usuário visível a outras pessoas. Resultado esperado: **4+** (ou a faixa mínima do novo sistema). O app lida com dinheiro, mas não é de apostas nem de compras; a assinatura é compra dentro do app, já informada.

Os Termos pedem 18 anos ou maioridade para a conta: é regra de contrato, não muda a classificação da loja.

## 5. Assinatura (campos do App Store Connect)

Grupo "SoftSpend", os dois produtos no mesmo grupo (detalhes em `docs/assinatura.md` §5):

| Produto | ID | Preço | Teste |
|---|---|---|---|
| Mensal | `br.com.softspend.app.assinatura.mensal` | R$ 14,90 | 14 dias grátis |
| Anual | `br.com.softspend.app.assinatura.anual` | R$ 144,90 | 14 dias grátis |

Nome e descrição de cada produto (pt-BR):
- Mensal: "SoftSpend mensal" — "Viagens, leitura de comprovante e fatura com IA e exportação, renovada todo mês."
- Anual: "SoftSpend anual" — "O mesmo acesso, renovado todo ano. Sai por cerca de R$ 12,08 por mês."

Texto de renovação (aparece na tela de planos e deve estar também na descrição; a tela de planos já mostra preço e duração vindos da App Store):

> A assinatura começa com 14 dias grátis. Depois do teste, o valor do plano escolhido (R$ 14,90 por mês ou R$ 144,90 por ano) é cobrado na sua conta Apple. A assinatura renova sozinha, no mesmo período, a menos que você cancele pelo menos 24 horas antes do fim do período atual. Você gerencia e cancela em Ajustes > seu nome > Assinaturas. O teste grátis vale uma vez por conta Apple; ao assinar durante o teste, o restante dele se perde. Termos de Uso: https://softspend.com.br/termos · Privacidade: https://softspend.com.br/privacidade

Captura exigida pela Apple para cada produto: a tela de planos (`PlanosAssinaturaView`), pelo simulador com o arquivo `SoftSpend.storekit` ou pelo TestFlight.

## 6. Rótulo de privacidade ("Privacidade do app")

Igual ao `SoftexVamo/SoftexVamo/PrivacyInfo.xcprivacy`. Rastreamento: **não** (`NSPrivacyTracking = false`, sem domínios). Para cada tipo abaixo: **vinculado à identidade do usuário = sim**, **usado para rastreamento = não**, finalidade **só "Funcionalidade do app"**.

| Tipo no App Store Connect | Chave do manifesto | Para que o app usa |
|---|---|---|
| Informações de contato > Endereço de e-mail | `EmailAddress` | Conta e login |
| Informações de contato > Nome | `Name` | Conta e identificação |
| Identificadores > ID do usuário | `UserID` | Identificar a conta no servidor |
| Conteúdo do usuário > Outro conteúdo do usuário | `OtherUserContent` | Gastos, viagens e notas anexadas |
| Conteúdo do usuário > Fotos ou vídeos | `PhotosorVideos` | Foto do comprovante enviada ao servidor e à leitura por IA (Google Gemini) |
| Dados financeiros > Outras informações financeiras | `OtherFinancialInfo` | Valores dos gastos e compras da fatura importada e do Apple Pay |
| Compras > Histórico de compras | `PurchaseHistory` | Saber se a assinatura está ativa |

Não declarados (o app não coleta): localização, contatos, dados de saúde, navegação, diagnóstico, publicidade e número de cartão de pagamento. API de motivo obrigatório: `UserDefaults` com o motivo `CA92.1`.

Decidido (o rótulo acima segue o manifesto, como combinado):
- A foto do comprovante vai ao servidor e ao Google (Gemini) e é declarada como "Fotos ou vídeos" — a alternativa "Outro conteúdo do usuário" sozinha ficou para trás, porque `docs/cartao-sem-open-finance.md` §2.8 pede "dados financeiros: compras" e a foto é o item que mais chama atenção na revisão.
- O valor, o estabelecimento e o nome do cartão do Apple Pay, e as compras da fatura importada, são "Outras informações financeiras"; o lançamento em si (descrição, categoria, data) continua em "Outro conteúdo do usuário".
- Qualquer mudança no manifesto exige mudar este quadro no mesmo PR.

## 7. Capturas de tela (modo `-demo`)

O modo existe só no Debug (`#if DEBUG` em `Debug/DemoInicio.swift`), roda sem login e sem rede, com a viagem de exemplo (Cuiabá, "hoje" = 23/07). Comando, com o simulador já aberto:

```bash
xcrun simctl launch <udid> br.com.softspend.app -demo <estado>
xcrun simctl io <udid> screenshot <arquivo>.png
```

Tamanhos exigidos: iPhone 6,9" (1320×2868) e iPad 13" (2064×2752), de 3 a 10 imagens cada. Modo claro; uma ou duas em escuro, se quiser.

Como a v1 vai com iPad (decisão de 15/11), as duas séries são obrigatórias, e a Apple abre o app no iPad na revisão: confira antes, no simulador iPad 13", que nenhuma tela dessa lista sai cortada ou esticada (roteiro em `docs/roteiro-envio.md`, passos 11 e 20). Tela ruim no iPad é correção de código, não de ficha. Para o iPad, abra o simulador "iPad Pro 13-inch" e use os mesmos comandos.

Sequência sugerida (a mesma para iPhone e iPad):

| # | Estado `-demo` | Mostra | Legenda sugerida |
|---|---|---|---|
| 1 | `durante` | Início com quanto ainda pode gastar hoje | Veja quanto ainda pode gastar hoje |
| 2 | `camera` | Câmera para o comprovante | Fotografe a nota fiscal |
| 3 | `confirmar` | Gasto preenchido pela IA (Spoleto, R$ 43,10) | A IA preenche, você confere |
| 4 | `todos` | Lista de todos os gastos | Todos os gastos num só lugar |
| 5 | `novaviagem` | Nova viagem com diária de R$ 450 | Crie a viagem e a diária |
| 6 | `viagens` | Lista de viagens | Suas viagens organizadas |
| 7 | `aviso` | Aviso de 80% e de diária ultrapassada | Alerta antes de estourar a diária |
| 8 | `fechar` | Fechar a viagem (30/07) | Feche e leve a prestação de contas |

Outros estados disponíveis, para reserva: `antes`, `encerrada`, `vazio`, `menu`, `consentimento`, `detalhe`, `semfoto`, `perfil`, `entrar`, `criarconta`.

Fora do modo `-demo` (feitas à mão): a tela de planos para a revisão da assinatura, e, se quiser, a importação de fatura (não tem estado `-demo`; usar a conta de demonstração no TestFlight).

Cuidados: sem dados pessoais reais (o demo usa "João Victor Farhat" e `joao@empresa.com`, inventados; trocar se não quiser esse nome na loja) e sem a barra de status de desenvolvimento.

## 8. Notas para a revisão

Colar no campo "Notas":

> SoftSpend ajuda quem viaja a trabalho a controlar a diária. O servidor fica no ar durante a revisão.
>
> CONTA DE DEMONSTRAÇÃO
> E-mail: [E-MAIL DA CONTA DEMO]
> Senha: [SENHA DA CONTA DEMO]
> A conta já tem uma viagem de 7 dias com gastos. Ela tem acesso liberado às funções da assinatura, então dá para testar tudo sem comprar.
>
> COMO TESTAR
> 1. Entre com a conta acima. A tela inicial mostra a viagem e quanto resta da diária do dia.
> 2. Toque em "+" para lançar um gasto. "Fotografar comprovante" abre a câmera; a leitura por IA pede consentimento na primeira vez (Google Gemini) e pode ser recusada. Em simulador ou sem foto à mão, o lançamento manual faz o mesmo sem IA.
> 3. Em Viagens, "Nova viagem" cria outra viagem; no menu da viagem há "Exportar" e "Importar fatura do cartão" (PDF, OFX ou CSV).
> 4. Assinatura: Perfil > Assinatura abre os planos (mensal e anual, com 14 dias grátis) e "Restaurar compras".
> 5. Excluir conta: Perfil > Excluir conta (o fluxo pede confirmação).
>
> OBSERVAÇÕES
> • O atalho "Registrar gasto" (Apple Pay) funciona pelo app Atalhos e só vale em aparelho real; não afeta o uso normal.
> • Permissões: câmera e fotos, só para ler comprovantes; notificações, para os avisos de diária.
> • Funciona offline: gastos lançados sem rede sobem quando a conexão volta.
> • O app não faz pagamentos, não move dinheiro e não acessa o banco do usuário.
> • Termos e Privacidade: links no cadastro e em Perfil > Sobre. (Conferir que a tarefa dos links no app já entrou na versão enviada.)
> Contato: suporte@softspend.com.br

Antes de enviar (checar, nesta ordem):
1. A conta de demonstração existe na **produção** (`Python/scripts/criar_conta_demo.py`) e o id está em `ACESSO_LIBERADO_USUARIOS`.
2. `GEMINI_API_KEY` no servidor de produção, com faturamento (tarefa G1).
3. As três páginas (`/termos`, `/privacidade`, `/suporte`) abrem sem login.
4. Compra de teste feita no TestFlight (Sandbox) com os dois produtos, no iPhone e conferido o app no iPad.
5. Se o servidor aceitar Sandbox (`APPLE_ACEITA_SANDBOX`), a revisão da Apple compra em Sandbox: deixar `true` até a aprovação.

## 9. Respostas prontas para perguntas comuns da revisão

- **Criptografia:** `ITSAppUsesNonExemptEncryption = NO`; o app só usa a criptografia do próprio iPhone (HTTPS, Keychain, CryptoKit).
- **Login de terceiros:** não existe; só conta própria (e-mail e senha), então "Entrar com a Apple" não é exigido.
- **Exclusão de conta:** dentro do app, em Perfil > Excluir conta; avisa que a assinatura da App Store não é cancelada e leva ao "Gerenciar assinatura".
- **IA:** consentimento explícito antes da primeira leitura; o texto diz que a foto vai ao Google Gemini.
- **Compra dentro do app:** só assinatura auto-renovável, pelo StoreKit; nada de pagamento por fora.
