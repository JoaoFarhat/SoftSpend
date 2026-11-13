# Política de Privacidade do SoftSpend

**Rascunho para revisão. Campos entre colchetes dependem de decisão do responsável.**
Última atualização: [DATA]

## 1. Quem é responsável pelos seus dados
O SoftSpend é um aplicativo de controle de gastos por ciclo (viagens e períodos com orçamento diário). Quem trata os seus dados é:

- **Responsável:** [NOME DO TITULAR], inscrito no CNPJ [CNPJ], com endereço em [ENDEREÇO].
- **Contato para privacidade e direitos:** privacidade@[DOMÍNIO] (a caixa será criada antes da publicação).

## 2. Quais dados coletamos e para que
| Dado | Para que serve | De onde vem |
|---|---|---|
| Nome, nome de usuário e e-mail | Criar e identificar a sua conta | Você informa no cadastro |
| Senha | Confirmar o seu login. Guardamos só uma versão cifrada (hash), nunca a senha em texto | Você informa no cadastro |
| Ciclos, dias e gastos (título, valor, categoria e data) | Mostrar o seu controle de gastos e o saldo diário | Você lança no app |
| Foto de comprovante | Ler os dados do gasto com IA, se você pedir | Você fotografa ou escolhe no aparelho |
| Arquivo de fatura de cartão | Lançar as compras da fatura no ciclo, se você pedir | Você escolhe o arquivo |
| Identificadores da compra na Apple | Saber se a sua assinatura está ativa | Apple, na compra |
| Registro de sessões (token de renovação, em forma cifrada) | Manter você conectado com segurança e encerrar sessões | Gerado no seu login |

Não usamos seus dados para publicidade e não fazemos rastreamento entre apps ou sites de terceiros.

## 3. Quem recebe os seus dados
- **Google (modelo de IA Gemini):** recebe a foto ou o texto do comprovante e da fatura, somente para ler os dados do gasto. Isso só acontece com o seu consentimento, pedido no próprio app. [Confirmar: a chave usada em produção está no plano pago do Google, que não usa os dados para melhorar os modelos.]
- **Amazon Web Services (AWS):** hospeda o servidor e o banco de dados, no Brasil (região de São Paulo).
- **Apple:** processa a sua assinatura pela App Store.

Não vendemos nem compartilhamos seus dados com outras empresas.

## 4. Por quanto tempo guardamos os dados
- **Gastos, ciclos e comprovantes:** enquanto a sua conta existir. Ao apagar um gasto, o comprovante vai junto.
- **Conta excluída:** apagamos seus dados em até [30] dias, exceto os que a lei nos obriga a guardar.
- **Registros fiscais de compra:** [5] anos, porque a lei fiscal exige.

## 5. Como você pode exercer seus direitos
Você pode, a qualquer momento:
- **ver** os seus dados no app;
- **corrigir** os seus dados no app;
- **excluir a sua conta** no app (Perfil → Excluir conta). Isso apaga os seus dados, com o prazo do item 4;
- **pedir uma cópia** dos seus dados, pelo e-mail de contato.

Se achar que tratamos seus dados de forma errada, você pode também procurar a Autoridade Nacional de Proteção de Dados (ANPD).

## 6. Segurança
- Conexão cifrada (HTTPS) entre o app e o servidor.
- Senha guardada só como hash.
- Login guardado no Keychain do próprio aparelho.
- Acesso ao banco restrito ao servidor da aplicação.

Nenhum sistema é totalmente seguro. Se houver um incidente que possa afetar você, avisaremos por e-mail.

## 7. Mudanças nesta política
Se mudarmos esta política, avisaremos no app antes de a mudança valer.

---

### Notas para revisão (não publicar)
- Se o recurso de Open Finance for religado, esta política precisa ser atualizada antes, porque ele coleta dados de cartão e transações.
- O aviso de consentimento da fatura (F2) ainda precisa ser escrito, e deve dizer que a fatura vai à IA para leitura.
- O texto do Google depende de a chave estar no plano pago. Sem isso, a frase do item 3 não pode ser publicada.
