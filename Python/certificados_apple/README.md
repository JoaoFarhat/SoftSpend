# Certificados raiz da Apple

Usados por `services/apple_service.py` para verificar a cadeia dos JWS da
App Store (`docs/assinatura.md` §2.1). São **públicos**; ficam no repositório
e são lidos do disco (todo `*.cer` desta pasta). Nunca baixados em tempo de
requisição.

**Pendente:** os arquivos ainda não estão aqui (a sessão que escreveu a AS2
não tinha acesso à rede). Sem eles, `/api/assinatura/transacoes`, o webhook e
o job respondem 503 / saem com código 2. Para colocar, de
<https://www.apple.com/certificateauthority/>:

```bash
cd Python/certificados_apple
curl -fsSLO https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
curl -fsSLO https://www.apple.com/certificateauthority/AppleRootCA-G2.cer
curl -fsSLO https://www.apple.com/appleca/AppleIncRootCertificate.cer
openssl x509 -inform der -in AppleRootCA-G3.cer -noout -subject -fingerprint -sha256
```

Conferir a impressão digital SHA-256 com a publicada na mesma página da Apple
antes de commitar.
