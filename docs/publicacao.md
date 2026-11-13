# Plano de publicação e cobrança do SoftSpend

Estado: 12/11/2026. Decisão do usuário (12/11): o SoftSpend vai para a **App Store** e vai ser **cobrado**. Este documento é só plano, sem código. Foi escrito lendo o código desta `main` e os documentos do Safeel (`Safeel.App.Backend/docs/assinatura.md`, `Safeel.App.Front.IOS/docs/publicacao.md`, `Safeel.App.Backend/docs/producao.md`), que já resolveram vários dos mesmos problemas.

> **Números a confirmar.** Preços do Gemini, câmbio (usei **R$ 5,50 por US$ 1**, só para as contas), taxas da Apple e os custos da AWS são estimativas. Os da AWS eu **não consigo ver** daqui: o usuário confere na fatura (pergunta U3). Os pontos de preço do Brasil na App Store Connect só aparecem com a conta criada.

## 1. Como cobrar

### 1.1 Custos por usuário

| Item | Conta | Resultado |
|---|---|---|
| **Taxa da Apple** | 15% no Small Business Program (vale para quem fatura até US$ 1 milhão por ano; é preciso se inscrever). Sem o programa, 30% | Sobre R$ 9,90 sobram ≈ R$ 8,40 antes de impostos |
| **Gemini, por leitura de comprovante** | Modelo `gemini-3.5-flash-lite`: US$ 0,30 por milhão de tokens de entrada e US$ 2,50 por milhão de saída (fontes públicas de out/2026). Uma foto reduzida a 1280 px custa ≈ 1.800 tokens de entrada; a saída é limitada a 256 tokens (`MAX_OUTPUT_TOKENS`, `ocr_service.py`) | ≈ US$ 0,0012 no pior caso, **menos de 1 centavo de real por leitura**. 50 leituras por mês custam ≈ R$ 0,35 |
| **S3 (notas arquivadas)** | A nota guarda a resolução original (2 a 5 MB). 150 notas por ano ≈ 0,5 GB; S3 ≈ US$ 0,023 por GB por mês | Centavos por usuário por ano |
| **AWS fixa (EC2 + RDS + banda)** | Não dá para ver daqui. Estimativa de partida: uma EC2 pequena + um RDS MySQL pequeno ≈ US$ 30 a 45 por mês (≈ R$ 165 a 250) | É o custo que importa: **não cresce por usuário**, só por degraus |
| **Conta de desenvolvedor** | US$ 99 por ano (≈ R$ 45 por mês) | Custo fixo |

**Conclusão das contas:** o custo que "cresce com o uso" (IA e armazenamento) é desprezível, menos de R$ 1 por usuário ativo por mês. Quase tudo é custo fixo (servidor e conta Apple, ≈ R$ 210 a 300 por mês). Com preço de R$ 9,90 por mês, o ponto de equilíbrio fica em **≈ 25 a 35 assinantes**. Por isso um limite de leituras de IA **não protege o bolso**; só serviria como motivo para o usuário assinar.

### 1.2 As quatro opções

| | **A. Assinatura mensal e anual (StoreKit)** | **B. Compra única** | **C. Grátis com limite** |
|---|---|---|---|
| Como é | "SoftSpend Pro" renovável; mensal e anual; teste grátis | Um preço, uma vez (ex.: R$ 39,90) | Grátis com 1 ciclo ativo e/ou N leituras de IA por mês; o resto pede assinatura ou compra |
| **Prós** | Receita que paga servidor e conta todo mês; o anual combina com quem viaja várias vezes por ano; o servidor e o app do Safeel já têm o desenho pronto | Fácil de explicar; sem renovação | Mais gente instala e testa; o usuário vê valor antes de pagar |
| **Contras** | Quem viaja uma vez por ano acha caro assinar; cancelamentos entre viagens; exige servidor que valida a Apple | **Receita acaba, custo do servidor continua** (cada novo usuário pesa mais por anos); compra única exige o mesmo trabalho de servidor para validar; sem desconto de teste | Precisa de contagem e limite no app **e** no servidor; o limite de IA não economiza nada (§1.1); quem não paga ainda pesa na AWS; é a opção com mais código |
| **App** | Tela de planos, compra, restaurar, gerenciar, faixa de aviso; bloqueio de "novo ciclo" e "ler com IA" | Mesma tela, mais simples; sem renovação | Tela de planos **mais** contador de uso e mensagens de limite |
| **Servidor** | Tabelas de assinatura, verificação do comprovante da Apple, webhook, conciliação diária, interruptor | Verificação do comprovante e um "tem direito" por conta; sem webhook de renovação (mas com reembolso) | O da A (ou B) **mais** contagem por usuário/mês |
| **Esforço** | Médio | Médio-baixo | Alto |

### 1.3 Recomendação: **A, assinatura mensal e anual, com 7 dias grátis**

- **Preço sugerido:** **R$ 9,90 por mês** e **R$ 79,90 por ano** (≈ R$ 6,66 por mês, 33% a menos). O anual é o destaque. Valores de lista: se a loja não tiver o ponto exato, usar o mais próximo (como no Safeel).
- Preço de referência: um app de gastos concorre com planilha grátis e apps de banco. R$ 9,90 é o tipo de preço que o brasileiro aceita por mês; o anual faz a conta fechar para quem viaja. **A decisão do preço é do usuário (U1).**
- **O que o teste grátis cobre:** tudo. Sem plano grátis permanente: o teste de 7 dias já mostra o valor e evita construir contagem de uso (opção C).
- **O que fica bloqueado sem assinatura** (proposta, para o usuário aprovar em U2): **criar ciclo novo** e **ler comprovante com IA**. O usuário **sempre** pode: ver o que já tem, exportar PDF/CSV, lançar gasto à mão nos ciclos que já existem, sincronizar o que já criou, sair e **excluir a conta**. Dado do usuário nunca vira refém, e o app offline não perde gasto por causa da cobrança.
- **Quando mudar a recomendação:** se o usuário preferir **mais instalações** do que receita no início, a opção C (grátis com **1 ciclo ativo**; o resto assinando) é a alternativa. Eu **não** limitaria por leituras de IA, pelo motivo da §1.1.

### 1.4 O que muda no servidor (reaproveitando o contrato do Safeel)

O `Safeel.App.Backend/docs/assinatura.md` é o modelo; o princípio é o mesmo: **o servidor é a única autoridade sobre o acesso**, o app só compra e repassa o comprovante assinado pela Apple (JWS).

- Tabelas novas (migration nova, número depois de `e8a2b5c7d9f1`): `assinaturas` (uma linha por usuário: `app_account_token` UUID, `original_transaction_id`, produto, ambiente, status, vencimento, carência, renovação automática) e `apple_notificacoes` (id da notificação, tipo, transação, data).
- Rotas: `GET /api/assinatura` (estado e `appAccountToken`), `POST /api/assinatura/transacoes` (recebe o JWS e reconcilia), `POST /api/webhooks/apple` (notificações da App Store v2; a única autenticação é a assinatura do JWS).
- Verificação: biblioteca oficial da Apple para Python (`app-store-server-library-python`; o Devin confere se está mantida antes de usar) e consulta à App Store Server API (`Get All Subscription Statuses`). **Um único caminho de cálculo do estado ("reconciliar")**, função pura com teste de tabela.
- Estados: `none`, `trial`, `active`, `grace`, `billing_retry`, `expired`, `revoked`. Conciliação diária em segundo plano. O servidor aceita comprovantes do **Sandbox** em produção (a revisão da Apple compra no Sandbox).
- Bloqueio no servidor: `POST /api/ciclos` (ciclo novo) e `POST /api/gastos/extrair` (IA) respondem `403 subscription_required` sem acesso. Os outros caminhos não bloqueiam (§1.3).
- **Interruptor** `BILLING_ENFORCEMENT` (`off` por padrão): com `off`, todo mundo tem acesso. Sem isso, o teste e a revisão travam antes da conta paga existir.
- **Exclusão de conta:** a linha da assinatura guarda só ids da Apple e datas; o que reter por obrigação fiscal vai para a pergunta U9 (não decidir no código).
- Segredos novos no `.env` da EC2 (nunca no repositório): `APPLE_BUNDLE_ID`, `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`.

### 1.5 O que muda no app

- `Services/LojaAssinatura.swift` (o **único** arquivo que importa StoreKit; hoje nenhum importa): carregar produtos, comprar com o `appAccountToken`, **restaurar compras** (`AppStore.sync()` e reenviar `Transaction.currentEntitlements`), ouvir `Transaction.updates` desde a abertura do app.
- Tela de planos própria no design system, com o que a Apple exige (regra 3.1.2): nome, duração, **preço vindo de `displayPrice`** (nunca escrito no código), "7 dias grátis" só se elegível, texto de renovação, links de Termos e Privacidade, botões Restaurar e Gerenciar assinatura, e a descrição do que o assinante recebe.
- Entradas: ao tocar em "Novo ciclo" ou em "Ler com IA" sem acesso; cartão "Assinatura" em Perfil e ajustes; faixa de aviso quando o pagamento falha.
- **Cuidado com o sync offline (`SyncActor`):** o `403 subscription_required` **não** pode virar falha com backoff nem descarte (como o 404 do T4). Só os envios de ciclo novo e de IA são bloqueados; um ciclo criado offline por quem tinha acesso e enviado depois do vencimento fica `.pending` com a mensagem "assinatura necessária", sem perder nada. Testar com o `FakeSyncAPI`.
- Aviso na exclusão de conta: "excluir a conta não cancela a assinatura da App Store" + botão "Gerenciar assinatura".
- Teste real de compra só no Mac (arquivo `.storekit` no esquema de Debug) e no TestFlight (Sandbox), com a conta paga.

### 1.6 Depois: empresas (não é para agora)

**Só o caminho.** Nada aqui entra na v1 nem muda o plano das seções anteriores. Serve para o usuário decidir, mais adiante, se vale o esforço.

**Por que faz sentido.** O que o app faz melhor (viagem com diária por dia, comprovante lido pela IA, relatório do ciclo em PDF) é, na prática, **prestação de contas de viagem a trabalho**: a empresa dá uma diária ou adiantamento, o funcionário gasta, junta as notas e presta contas. É a dor que o HackaTruck já tem, e vender para empresa paga mais por usuário do que o consumidor final.

**Modelo de cobrança (hipótese).** Por **funcionário ativo por mês**, na faixa de **R$ 19 a R$ 29** (proposta recalculada em 13/11, ver a conta abaixo), com mínimo de assentos e plano anual. A faixa é um palpite: **a conferir** com os preços públicos de concorrentes de reembolso de despesas (por exemplo, Expensify, Pleo e os nacionais, como o Onfly; nomes só como ponto de partida da pesquisa) antes de qualquer proposta. Não cobrar pelo StoreKit: é venda entre empresas, e a Apple permite cobrança fora da loja para contas corporativas se o app não vender o plano dentro dele (conferir a regra vigente das diretrizes antes de desenhar, tema da pergunta E4).

**Conta da faixa (13/11, com o preço decidido do consumidor).** Preço de lista: R$ 14,90 por mês e R$ 144,90 por ano (U1). Os números abaixo são arredondados e antes de impostos.

| | Preço de lista | Comissão da Apple (15%) | Sobra para o SoftSpend |
|---|---|---|---|
| Consumidor, mensal | R$ 14,90 por mês | R$ 2,24 | **R$ 12,67 por mês** |
| Consumidor, anual | R$ 144,90 por ano (R$ 12,08 por mês) | R$ 21,74 | **R$ 123,17 por ano (R$ 10,26 por mês)** |
| Empresa, fora da Apple | A definir | 0% (venda direta; só imposto e a taxa do meio de pagamento) | O preço cobrado, menos imposto e taxa |

- **A faixa antiga (R$ 15 a R$ 25) ficou apertada.** O piso de R$ 15 é praticamente o preço do consumidor mensal (R$ 14,90) e fica **acima** do anual (R$ 12,08 por mês), mas a empresa recebe painel, aprovação, exportação e suporte, então não pode custar quase o mesmo que a pessoa física.
- **Faixa proposta: R$ 19 a R$ 29 por funcionário por mês**, com ponto de partida em **R$ 19,90** (≈ 33% acima do consumidor mensal, ≈ 65% acima do anual). Para a empresa, 100% do valor entra (sem a Apple), então R$ 19,90 deixa mais que os R$ 12,67 do consumidor mensal, mesmo depois de imposto e taxa do pagamento.
- **Plano anual para empresa:** desconto parecido com o do consumidor (≈ 17%), ou seja, R$ 19,90 por mês viram ≈ R$ 199 por funcionário por ano.
- **Piso de negociação:** não vender abaixo de **R$ 15 por funcionário por mês**, nem no piloto, para não sair mais barato que o app individual.
- **Ainda não conferido:** concorrentes (Expensify, Pleo, Onfly) e o imposto real sobre a venda para empresa (depende do CNPJ e do regime do usuário; falar com o contador). A faixa continua sendo hipótese até lá.

**O que falta no app e no servidor.**

| Item | Hoje | O que falta |
|---|---|---|
| **Conta da empresa** | Só existe usuário individual (`User`, isolamento por `userId`) | Entidade "organização", com gestor(es) e funcionários, convite por e-mail e remoção de quem sai da empresa (os dados do funcionário não podem ficar presos na empresa nem vazar para ela além do que ele enviou) |
| **Painel do gestor** | Não existe | Tela web (não precisa ser no app) com viagens, gastos e comprovantes de todos; filtros por pessoa, período e categoria |
| **Aprovação** | Não existe | Fluxo "enviar prestação de contas" → gestor aprova ou devolve com comentário; estados do ciclo (rascunho, enviado, aprovado, reprovado); o `SyncActor` precisa respeitar ciclo travado após o envio |
| **Políticas** | Não existe | Teto por categoria e por dia, diária diferente por cargo ou destino, regra de "comprovante obrigatório" |
| **Exportação para a contabilidade** | Só PDF e CSV de um ciclo | CSV/planilha consolidada por empresa e período, com centro de custo e categoria contábil; depois, integração (a combinar com o contador do cliente) |
| **Cobrança fora da App Store** | Não existe | Fatura ou boleto por empresa (Pix, boleto ou cartão por provedor de pagamento), nota fiscal de serviço, contrato e termos para empresas, e o acesso do funcionário liberado pela organização, sem passar pelo `BILLING_ENFORCEMENT` por assinatura individual |
| **LGPD** | Política para o consumidor | A empresa é a controladora dos dados dos funcionários; precisa de contrato de tratamento (DPA) e retenção definida pela empresa |

**Primeiro cliente natural: o [[HackaTruck MakerSpace]].** O app nasceu das viagens dele, e as pessoas que viajam já usam o ciclo por cidade. Serve de piloto gratuito ou com desconto, para aprender o que o gestor realmente pede antes de construir o painel. Oferecer o app a ele como serviço é decisão e conversa do usuário (E2).

**Ordem sugerida, quando chegar a hora.**

1. Lançar e estabilizar o app individual (§4); só depois olhar para empresas.
2. Piloto com o HackaTruck usando o app como está, com exportação manual: ver o que falta.
3. Se o piloto mostrar demanda: organização + painel do gestor + exportação consolidada (o menor conjunto que o gestor consegue usar). Aprovação e políticas vêm depois.
4. Só então preço, contrato e cobrança por fatura.

**Perguntas ao usuário** (viram tarefas [Você] na nota):

- **E1:** vale tentar empresas depois da loja, ou o foco é só o consumidor?
- **E2:** o HackaTruck (ou quem decide nele) toparia ser piloto? Quem conversa com ele?
- **E3:** a faixa de **R$ 19 a R$ 29** por funcionário por mês (ponto de partida R$ 19,90), recalculada com o preço de R$ 14,90 e a comissão de 15% da Apple, parece razoável para você? (O Claude confere concorrentes quando for a hora.)
- **E4:** a conta de desenvolvedor Apple (U4) será de pessoa física ou CNPJ? Para vender a empresas, um CNPJ ajuda na nota fiscal e no contrato.

## 2. O que a Apple exige e o app ainda não tem

Conferido no código em 12/11.

| Item | Estado hoje | O que falta |
|---|---|---|
| **Conta de desenvolvedor** (US$ 99 por ano) | Não existe. O projeto usa dois times de teste: `Q6B7N567Z6` (projeto) e `DHFGW8SG9X` (app) | Criar a conta (U4), conferir que o time do app é o da conta paga e unificar |
| **Exclusão de conta pelo app** | **Existe.** `PerfilView` tem "Excluir conta" com confirmação, chama `DELETE /auth/conta` (`auth_controller.py`), que apaga o usuário em cascata; as notas no bucket saem pelos listeners de `comprovante_cleanup.py` | (a) Conferir no Mac que os dados **locais** do usuário também são apagados no aparelho: hoje `deleteAccount()` só chama `logout`, e o app guarda dados por `userId` sem apagar no logout (decisão de design). Após excluir a conta, o aparelho não deve manter ciclos e comprovantes dela. (b) Aviso da assinatura (§1.5). (c) Teste automatizado do fluxo |
| **Política de Privacidade e Termos publicados** | **Não existem**: nenhuma tela ou link no app (busca por "Privacidade" e "Termos" não achou nada). O consentimento do Gemini **existe** (`ConsentimentoLeituraView`, `Consentimento.leituraAutomatica`, testado) | Escrever os dois textos (rascunho do Claude, revisão do usuário/advogado, U8), publicar em `https://softspend.com.br/privacidade` e `/termos` (HTTPS, público, sem login, em português), linkar no cadastro, no Perfil e na tela de planos. A Política precisa dizer: leitura por IA (Gemini, Google, envio ao exterior), notas guardadas no S3, **prazo de retenção e exclusão** (já recomendado no `AGENTS.md`), o histórico de compra e que o app grava como gasto a compra que o Apple Pay informa ao Atalhos (`docs/cartao-sem-open-finance.md` §1.7) |
| **Restaurar compras** | Não existe (sem StoreKit) | Entra com a assinatura (§1.5); é exigência da Apple em app com compra |
| **Conta de demonstração para a revisão** | Não existe. `DemoInicio.swift` é só `#if DEBUG` e não vai para a loja | Criar uma conta na **produção** com ciclos e gastos de exemplo (script de seed), com assinatura liberada (`BILLING_ENFORCEMENT=off` ou concessão manual) e senha só nas "Notas para a revisão". O servidor precisa estar no ar e com a chave do Gemini durante a revisão |
| **Ícone** | `AppIcon.appiconset` tem 1024×1024 claro e escuro; o "tinted" está vazio (opcional) | Conferir no Mac que não tem transparência (a Apple recusa) e a aparência no Archive |
| **Manifesto de privacidade** (`PrivacyInfo.xcprivacy`) | **Não existe** | Criar: sem rastreamento; dados coletados (e-mail, nome, ID de usuário, conteúdo do usuário: gastos e notas, histórico de compra); `UserDefaults` com motivo `CA92.1` (o app usa `UserDefaults`). Rótulo da loja igual ao manifesto |
| **Criptografia de exportação** | Chave `ITSAppUsesNonExemptEncryption` ausente (o app usa HTTPS e CryptoKit AES-GCM, algoritmos padrão) | Mesma decisão já tomada no Safeel (12/11): `YES` e responder no envio que só usa algoritmos padrão, isentos. A classificação é responsabilidade do dono do produto (U7) |
| **Versão mínima do iOS** | `IPHONEOS_DEPLOYMENT_TARGET = 26.0` | **Só roda no iOS 26.** Se o objetivo é alcançar mais gente, avaliar baixar (exige conferir o visual e os testes). **Decisão do usuário (U6)** |
| **Identificador do app** | `com.joao.softspend` (nome pessoal) | **Não muda depois de criado na loja.** Decidir o definitivo (ex.: `br.com.softspend.app`) **antes** de criar o app na App Store Connect (U5) |
| **Configuração só de desenvolvimento em produção** | `Info.plist` tem `NSBonjourServices` e `NSAllowsLocalNetworking`, e o app pede "servidor local em desenvolvimento" | Tirar do build de Release para não gerar pergunta de rede local e questionamento da revisão |
| **Sign in with Apple** | Não é exigido: o login é próprio (e-mail e senha), sem Google/Facebook | Nada |
| **Ficha da loja** | Não existe | Nome, subtítulo, descrição, palavras-chave, categoria (Finanças), classificação etária, URL de suporte (obrigatória) e de privacidade, e-mail de contato, capturas de iPhone e de iPad 13" (o app declara iPad, `TARGETED_DEVICE_FAMILY = 1,2`), texto de renovação da assinatura, notas para a revisão. As capturas saem do modo demonstração (`-demo`) no simulador |
| **Disponibilidade** | — | Só Brasil na v1 (Termos e LGPD em português). Decisão U6 |

### 2.1 Gemini no plano pago (comprovantes de clientes)

**O risco.** A `GEMINI_API_KEY` do servidor (`Python/services/ocr_service.py`) é uma chave comum da API do Gemini. Se o projeto do Google dessa chave **não tem faturamento ligado**, ela está no **plano gratuito**, e nele os termos do Google permitem usar o que é enviado (as fotos das notas e o texto lido) para **melhorar os modelos** e permitem revisão humana. Isso é aceitável para teste, **não** para um app pago com comprovantes de clientes. Do **lado de fora** não dá para saber qual é o plano da chave; o código só lê a variável.

**O que fazer.**

- **Conferir (você):** em https://aistudio.google.com/apikey, ver o projeto da chave em uso na EC2 e se ele aparece como **plano pago** ou com **faturamento** ligado.
- **Ligar o faturamento (você):** vincular uma conta de faturamento do Google Cloud ao projeto da chave (cartão de crédito). Não precisa trocar de modelo nem mexer no código.
- **Configuração:** nada muda no código nem nas variáveis (`GEMINI_API_KEY`, `GEMINI_MODEL_NAME`). Só garantir que a chave em produção é a do **projeto com faturamento**; se for preciso criar outra, gerar a chave nesse projeto e trocá-la no `.env` da EC2 (`systemctl restart softspend`). A chave de teste e a de produção devem ser de projetos diferentes.
- **Custo:** o §1.1 já usa o **preço do plano pago** (US$ 0,30 por milhão de tokens de entrada e US$ 2,50 por milhão de saída), ou seja, menos de 1 centavo de real por leitura; o plano gratuito não cobra, então o número não muda. Em vez disso, **o faturamento passa a ser real**: definir um orçamento e alerta de gasto no Google Cloud (por exemplo, R$ 50 por mês) para não ser surpreendido por abuso.
- **Limite do plano gratuito:** além do uso dos dados, ele tem cota baixa de requisições por dia e por minuto; com usuários reais a leitura falharia. O plano pago também resolve isso.

**A Política de Privacidade precisa citar isso?** Sim, com o que for verdade nos termos vigentes do Google (o Claude confere no momento de escrever o rascunho): a imagem e o texto da nota são enviados à API do Gemini (Google), **no plano pago, sem uso para treinar os modelos do Google**, com a retenção que os termos do Google descreverem (por exemplo, para detecção de abuso), com envio ao exterior. Não prometer mais do que os termos do Google dizem. O texto da tela de consentimento (`ConsentimentoLeituraView`) deve dizer o mesmo.

**Tarefa:** **[Você]** G1, abaixo e na nota. Antes da loja (fase 0).

## 3. Servidor em produção: a AWS de hoje serve?

**Serve para começar, com ajustes antes da loja.** O que existe: uma EC2 com o uvicorn atrás do nginx (HTTPS com certbot, HSTS, redirecionamento), RDS MySQL, S3 para as notas, logs com rotação, `GET /health`. O que **falta** para cobrar de gente real:

| Tema | Hoje | Risco | O que fazer |
|---|---|---|---|
| **Deploy** | Todo merge na `main` roda testes e **publica direto na EC2** (`git reset --hard`, `pip install`, `alembic upgrade head`, restart) | Um merge ruim derruba o app dos usuários pagantes; a migration roda sem backup; o restart corta requisições em andamento; `apt-get update` a cada deploy | Produção **só por aprovação manual**: GitHub Environment `producao` com revisor obrigatório (como no plano do Safeel); a `main` continua publicando só em teste. Mexer em publicação é decisão do usuário (merge dele) |
| **Teste x produção** | Existe um MySQL local para testes e um RDS; **a EC2 atual é a única do app** | O app de loja e a conta de demonstração ficam no mesmo lugar dos testes | Ambiente de teste separado: uma segunda EC2 pequena (ou o mesmo servidor com **outra porta e outro schema**, mais barato) com banco, chaves JWT e bucket próprios. **Nunca** apontar o teste para o banco de produção. Se o dinheiro for curto: manter um só servidor, mas com o deploy manual acima |
| **Banco** | RDS, versão e tamanho desconhecidos aqui | Perder o banco é perder o cadastro e as assinaturas | Backup automático do RDS ligado (retenção de pelo menos 7 dias), **snapshot manual antes de cada migration** (como a `docs/religar-servidor.md` já pede), proteção contra exclusão, teste de restauração uma vez |
| **Notas (S3)** | Bucket com URL assinada de 1h | Apagar sem querer | Versionamento do bucket e regra de limpeza; chaves só em variável de ambiente |
| **HTTPS** | nginx + certbot, `EnforceHTTPSMiddleware`, HSTS | Renovação do certificado falhar sem ninguém notar | Conferir `certbot renew` agendado e um alerta de vencimento. O app já recusa HTTP para `softspend.com.br` |
| **Disponibilidade** | Uma instância, restart no deploy, `Restart=on-failure` | Queda sem ninguém saber | Alarme simples (CloudWatch ou monitor gratuito batendo em `/health`) avisando por e-mail; IP fixo (Elastic IP); disco e RDS com alarme de espaço |
| **Segredos** | `.env` na EC2, segredos do GitHub | Chave da Apple e do Gemini são dinheiro | Chaves novas só na produção, nunca as de teste; guardar a `.p8` da Apple com cuidado (download único) |
| **Limites** | `slowapi` por rota; `TRUST_PROXY` atrás do nginx | A IA é a rota que custa | Já limitada a 20 por minuto por IP; adicionar teto diário por usuário (barato de fazer, protege de abuso, mesmo que a leitura custe centavos) |
| **Domínio** | `softspend.com.br` aponta para a API | O site de Termos e Privacidade precisa viver em algum lugar | Servir as duas páginas estáticas pelo próprio nginx (`/privacidade`, `/termos`, `/suporte`); sem custo extra |
| **Dimensionamento** | Desconhecido | — | Conferir o uso de CPU e memória da EC2 e do RDS com o `/health` e o CloudWatch; para algumas centenas de usuários o porte pequeno costuma bastar. Só subir de porte com dado |

## 4. Ordem das tarefas até a loja

Legenda: **[Você]** = decisão ou ação do usuário; **[Devin]** = código; **[Claude]** = revisão e documentos. As decisões do usuário estão em **negrito** e têm número (U1 a U9, as perguntas estão na nota do projeto).

**Fase 0: decisões e conta (começa já; destrava o resto)**
1. **[Você]** U1 (preço e plano), U2 (o que fica bloqueado), U5 (identificador do app), U6 (iOS mínimo e países).
2. **[Você]** U4: criar a conta de desenvolvedor (US$ 99 por ano) e inscrever-se no Small Business Program; preencher o Acordo de Apps Pagos (banco e impostos).
3. **[Você]** U3: ver na AWS o tipo e o custo da EC2 e do RDS (mostrar a fatura do mês), para fechar o ponto de equilíbrio.
3b. **[Você]** G1: conferir no Google AI Studio se o projeto da `GEMINI_API_KEY` tem faturamento (plano pago); se não tiver, ligar o faturamento no Google Cloud e definir alerta de gasto (§2.1).

**Fase 1: código sem conta paga (em paralelo, o Devin pode começar já)**
4. **[Devin, backend]** B1 assinatura: tabelas, `GET /api/assinatura`, interruptor `BILLING_ENFORCEMENT`, máquina de estado com teste de tabela. B2: verificação do JWS e `POST` de transações. B3: webhook e conciliação diária. B4: bloqueio de ciclo novo e de IA com `403 subscription_required`. (B4 depende só de B1.)
5. **[Devin, iOS]** I1: `LojaAssinatura` e tela de planos (com mock da loja), restaurar compras, gerenciar assinatura. I2: bloqueios na interface e tratamento do `403` no `SyncActor` sem perder item. I3: aviso de assinatura na exclusão de conta **e** apagar os dados locais do usuário. I4: links de Termos e Privacidade (cadastro, Perfil, planos). I5: `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption`, tirar o que é só de desenvolvimento do Release.
6. **[Devin, backend]** B5: teto diário da IA por usuário; script de seed da conta de demonstração.
7. **[Claude]** Escrever os rascunhos de Termos, Política de Privacidade, ficha da loja e notas da revisão; revisar os PRs (atenção ao sync e ao interruptor).

**Fase 2: servidor de produção**
8. **[Você]** U8/U9: revisar e aprovar Termos e Política (idealmente um advogado; fiscal e retenção de dados de compra).
9. **[Você]** Ligar backup do RDS, versionamento do S3, alarmes, Elastic IP (o Claude guia, passo a passo).
10. **[Devin]** Separar o deploy: automático para teste, manual com aprovação para produção (**[Você]** faz o merge, porque mexe em publicação). Publicar as páginas estáticas no nginx.
11. **[Você]** Com a conta paga: criar os dois produtos de assinatura e o teste de 7 dias, a chave da App Store Server API e a URL do webhook; colocar os segredos na EC2.

**Fase 3: teste e envio**
12. **[Você/Mac]** Build de Release, *Product > Archive*, *Generate Privacy Report*, conferir ícone, `xcodebuild test`.
13. **[Você]** TestFlight interno: compra Sandbox, restaurar, cancelar, exclusão de conta, ciclo criado offline e enviado depois, gasto com IA.
14. **[Você]** Preencher a ficha (rótulo de privacidade igual ao manifesto), capturas (o Devin pode gerar a lista de telas com `-demo`), nota de revisão com a conta de demonstração.
15. **[Você]** **Ligar `BILLING_ENFORCEMENT=on` em produção só depois do teste do passo 13 e antes de enviar.** A primeira assinatura vai **junto com a versão do app** no mesmo envio.
16. **[Você]** Enviar para revisão; **[Claude/Devin]** corrigir o que a Apple apontar.

## 5. Riscos que mais derrubam envios

- Sem conta de demonstração funcionando, ou com o servidor fora do ar durante a revisão.
- Política de Privacidade ausente ou sem citar a IA (Gemini) e o armazenamento das notas.
- Chave do Gemini em projeto sem faturamento (plano gratuito): o Google pode usar as notas dos clientes para melhorar os modelos (§2.1).
- Assinatura sem "restaurar compras" ou com tela de planos sem preço, duração, renovação e links.
- `iOS 26` como mínimo: legal para a Apple, mas reduz muito quem pode instalar.
- Mudar o identificador do app depois de criado na loja: não dá.
