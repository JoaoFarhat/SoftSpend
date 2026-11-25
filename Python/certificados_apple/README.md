# Certificados raiz da Apple

Usados por `services/apple_service.py` para verificar a cadeia dos JWS da
App Store (`docs/assinatura.md` §2.1). São **públicos**; ficam no repositório
e são lidos do disco (todo `*.cer` desta pasta). Nunca baixados em tempo de
requisição.

Arquivos (baixados de <https://www.apple.com/certificateauthority/> em 25/11/2026):

| Arquivo | Certificado | Vale até | SHA-256 |
| --- | --- | --- | --- |
| `AppleRootCA-G3.cer` | Apple Root CA - G3 | 30/04/2039 | `63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79` |
| `AppleRootCA-G2.cer` | Apple Root CA - G2 | 30/04/2039 | `C2:B9:B0:42:DD:57:83:0E:7D:11:7D:AC:55:AC:8A:E1:94:07:D3:8E:41:D8:8F:32:15:BC:3A:89:04:44:A0:50` |
| `AppleIncRootCertificate.cer` | Apple Root CA | 09/02/2035 | `B0:B1:73:0E:CB:C7:FF:45:05:14:2C:49:F1:29:5E:6E:DA:6B:CA:ED:7E:2C:68:C5:BE:91:B5:A1:10:01:F0:24` |

Para conferir um arquivo:

```bash
openssl x509 -inform der -in AppleRootCA-G3.cer -noout -subject -fingerprint -sha256
```
