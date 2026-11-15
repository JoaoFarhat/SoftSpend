# Roteiro de envio para a Apple (no Mac)

Estado: 15/11/2026. Uma lista só, na ordem. Cada passo diz onde fazer (Mac, iPhone, iPad, servidor, App Store Connect) e quando está pronto. Só documento: nada aqui muda o app. Fontes: `docs/publicacao.md` §4 (passos 12 a 16), `docs/assinatura.md` §4 e §5, `docs/loja.md`.

Decisão de 15/11: **v1 com iPhone e iPad** (`TARGETED_DEVICE_FAMILY = 1,2`). Isso muda o roteiro em três pontos: o app precisa ser conferido no iPad (passo 11), a ficha leva capturas de iPad 13" (passo 20) e o TestFlight deve ser instalado também num iPad (passo 16).

## A. Antes de abrir o Xcode (servidor e conta)

1. **[Você]** Conta Apple paga no CNPJ ativa e contrato de Apps Pagos assinado (`docs/assinatura.md` §5, item 1). Pronto quando os produtos de assinatura aparecem na App Store Connect.
2. **[Você]** App Store Connect criado como em `docs/assinatura.md` §5 (app, grupo com os dois produtos, oferta de 14 dias, carência, notificações, chave `.p8`, testadores Sandbox). Anote o ID numérico do app e o Issuer ID e Key ID da chave.
3. **[Você]** Na EC2: variáveis `APPLE_*` no `.env`, certificados em `Python/certificados_apple/` e `sudo systemctl restart softspend`. Pronto quando a notificação de teste da Apple recebe 200 do `/api/webhooks/apple`.
4. **[Você]** No servidor, conferir que `BILLING_ENFORCEMENT` está `off` (ainda) e `APPLE_ACEITA_SANDBOX=true` (a revisão da Apple compra em Sandbox).
5. **[Você]** Conferir que o último merge na `main` já foi para a produção (deploy verde) e que `https://softspend.com.br/termos`, `/privacidade` e `/suporte` abrem sem login (config do nginx copiada para a EC2).
6. **[Você]** Conta de demonstração na produção: rodar `python -m scripts.criar_conta_demo --email ...` (senha só em `DEMO_SENHA`), pôr o id impresso em `ACESSO_LIBERADO_USUARIOS` no `.env` e reiniciar o serviço. Pronto quando, entrando com ela no app, a viagem de 7 dias aparece.
7. **[Você]** `GEMINI_API_KEY` da produção em projeto com faturamento (tarefa G1), senão o Google pode usar as notas dos clientes para treinar modelos.

## B. No Mac: conferir o app

8. **[Mac]** `git pull` da `main`, abrir `SoftexVamo/SoftSpend.xcodeproj` e rodar os testes: `xcodebuild test` no esquema `SoftSpend`. Pronto quando passam todos (o CI do GitHub já compila e testa a cada PR, mas rode uma vez aqui).
9. **[Mac]** Build de **Release** no simulador e no aparelho, sem erro e sem aviso novo.
10. **[iPhone, conferências pendentes]** Instalar o app no iPhone e conferir uma a uma (instale com o app **anterior sincronizado**: o identificador mudou para `br.com.softspend.app`, então o iPhone vê outro app):
    - **PR #32 (gasto ou dia apagado em outro aparelho):** num aparelho apague um gasto, no outro abra a viagem e confirme que o gasto some sem erro.
    - **PR #33 (encurtar viagem):** abra viagem com gasto no último dia, edite a volta para um dia antes; deve aparecer "Encurtar a viagem?"; toque em "Cancelar" e confirme que o gasto continua.
    - **PR #41 (atalho do Apple Pay):** crie a automação no app Atalhos pelo passo a passo do Perfil > Apple Pay (atalho) e faça uma compra (ou rode o atalho à mão); o gasto aparece no dia de hoje.
    - **PR #43 (fila sem viagem):** sem viagem para a data, rode o atalho; aparece o aviso no Início e a folha oferece "Lançar em…" ou "Descartar" (com confirmação).
    - **PR #55 (cartões do Apple Pay):** no Perfil, os cartões aparecem com uma chave cada; desligue um e confirme que a compra desse cartão não entra.
    - **PR #58 (iOS 17):** abrir o app e passar pelas telas principais no visual novo; se tiver aparelho com iOS 17, melhor ainda.
    - **PR #63 (excluir conta):** com uma conta de teste, Perfil > Excluir conta; a confirmação avisa que a assinatura da App Store não é cancelada, e os dados do aparelho somem.
    - **PR #68 (bloqueios da assinatura):** só dá para ver com `tem_acesso = false`; faça isto no passo 15 (TestFlight), não aqui.
11. **[iPad]** Repetir o essencial no iPad (aparelho ou simulador iPad 13"): entrar, ver o Início, lançar um gasto, abrir a câmera/galeria, abrir os planos, girar a tela. Anote qualquer tela cortada ou esticada: isso é correção de código antes de enviar (o app não foi desenhado para iPad).
12. **[Mac]** Ícone: conferir que o ícone de 1024×1024 não tem transparência e como fica no claro e no escuro.

## C. Archive e privacidade

13. **[Mac]** Escolher "Any iOS Device (arm64)" e *Product > Archive*. Pronto quando a janela do Organizer mostra o arquivo com o bundle `br.com.softspend.app` e a versão 1.0.
14. **[Mac]** No Organizer, *Generate Privacy Report* (relatório de privacidade) e comparar com `docs/loja.md` §6 e com `PrivacyInfo.xcprivacy`: mesmos tipos de dado, rastreamento "não". Se o relatório mostrar algo a mais (SDK ou API de motivo obrigatório), corrigir o manifesto e o quadro da ficha juntos.
15. **[Mac]** *Distribute App > App Store Connect > Upload*. Pronto quando o build aparece em TestFlight, processado, sem e-mail de problema.

## D. TestFlight (Sandbox)

16. **[iPhone e iPad]** Instalar o build pelo TestFlight (testador interno) e entrar com um Apple ID Sandbox, em Ajustes > App Store > Conta Sandbox.
17. **[iPhone]** Com `BILLING_ENFORCEMENT=off`, testar nesta ordem e anotar o resultado:
    - Perfil > Assinatura: os dois planos aparecem com preço e "14 dias" vindos da App Store.
    - Comprar o mensal (teste grátis): o `GET /api/assinatura` passa para `trial` e a faixa "Teste grátis até DD/MM" aparece.
    - Restaurar compras em outro aparelho ou depois de reinstalar.
    - Cancelar pelo "Gerenciar assinatura" e ver o estado mudar.
    - Excluir conta (a assinatura não é cancelada, o aviso diz isso).
    - Criar viagem sem internet, ligar a rede e ver subir sozinha.
    - Gasto com leitura por IA (pede consentimento na primeira vez).
    - Importar uma fatura real (PDF) e conferir o aviso da primeira importação.
18. **[Você, servidor]** **Ligar `BILLING_ENFORCEMENT=on` agora**, só depois de o passo 17 passar e antes de enviar (`docs/publicacao.md` §4, passo 15): na EC2 editar o `.env`, `sudo systemctl restart softspend`. Antes de ligar, responder as decisões de `docs/assinatura.md` §6 (contas antigas, carência de cobrança, até quando aceitar Sandbox). Se algo der errado, voltar a `off` (instantâneo, nada é apagado).
19. **[iPhone]** Com `on`, conferir os bloqueios (PR #68): uma conta nova sem teste iniciado deve abrir a tela de planos ao tentar nova viagem, ler comprovante com IA, exportar e importar fatura; ver, editar e lançar gasto à mão continuam livres; a conta de demonstração passa em tudo sem comprar. Se a conta de demonstração for bloqueada, o id não está em `ACESSO_LIBERADO_USUARIOS`.

## E. Ficha e envio

20. **[Mac]** Capturas pelo modo `-demo` no simulador, em dois tamanhos: iPhone 6,9" (1320×2868) e **iPad 13" (2064×2752)**, de 3 a 10 de cada, estados em `docs/loja.md` §7. Se alguma tela do iPad ficar feia nas capturas, é sinal de correção de código (passo 11) antes de seguir. Fazer à mão: a tela de planos (captura exigida de cada produto) e, se quiser, a importação de fatura.
21. **[Você]** Preencher a ficha com `docs/loja.md`: dados, descrição, palavras-chave, classificação etária, texto de renovação, rótulo de privacidade (igual ao passo 14), capturas e URLs. Direitos autorais e nome do titular só depois dos dados da empresa.
22. **[Você]** Notas para a revisão com o e-mail e a senha da conta de demonstração (`docs/loja.md` §8). Conferir a lista "Antes de enviar" dali: conta demo existe na produção e está liberada, Gemini com faturamento, páginas abertas, compra Sandbox feita, `APPLE_ACEITA_SANDBOX=true`.
23. **[Você]** Escolher o build do passo 15 na versão 1.0, anexar os dois produtos de assinatura **no mesmo envio** (a primeira assinatura vai junto com a versão), e *Add for Review > Submit*.
24. **[Você]** Durante a revisão: servidor no ar (o alarme do GitHub avisa por e-mail), `BILLING_ENFORCEMENT=on`, `APPLE_ACEITA_SANDBOX=true`. Se a Apple recusar, mande o texto da recusa; correção é do Devin e revisão do Claude.
25. **[Você]** Depois de **aprovada**: decidir se `APPLE_ACEITA_SANDBOX` vira `false` (`docs/assinatura.md` §6) e liberar a versão.

## Quando parar e voltar

- Passo 8 ou 9 falha: bug de código, volta para o Devin com a mensagem do Xcode.
- Passo 10 ou 11 acha defeito: abrir tarefa; não enviar antes de corrigir um defeito que perde dado (sync, exclusão) ou deixa uma tela do iPad inutilizável.
- Passo 14 mostra dado fora do manifesto: corrigir manifesto e ficha no mesmo PR.
- Passo 17 falha em produtos que não carregam: conferir o contrato de Apps Pagos (passo 1) antes de mexer no código.
