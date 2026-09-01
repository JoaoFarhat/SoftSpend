#!/bin/bash
set -e

APP_DIR=/home/ubuntu/SoftSpend/Python
LOG_DIR=/var/log/softspend
SERVICE_NAME=softspend

echo "Atualizando pacotes do sistema..."
sudo apt update

echo "Instalando dependencias de build para Pillow..."
sudo apt install -y \
    python3-venv \
    libjpeg-dev \
    libpng-dev \
    libwebp-dev \
    libtiff-dev \
    zlib1g-dev \
    libfreetype6-dev \
    liblcms2-dev \
    libopenjp2-7-dev \
    libharfbuzz-dev \
    libfribidi-dev

# Em distros com Python 3.14 (ex: Ubuntu 26.04 resolute), wheels oficiais do
# Pillow ainda nao estao disponiveis. Instalar python3-pil do sistema e criar
# a venv com acesso aos pacotes do sistema evita compilacao do source.
sudo apt install -y python3-pil

echo "Criando diretorio de logs..."
sudo mkdir -p "$LOG_DIR"
sudo chown ubuntu:ubuntu "$LOG_DIR"

echo "Criando virtualenv (com acesso a pacotes do sistema)..."
python3 -m venv "$APP_DIR/.venv" --system-site-packages

echo "Instalando dependencias Python..."
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"

echo "Instalando service systemd..."
sudo cp "$(dirname "$0")/$SERVICE_NAME.service" /etc/systemd/system/
sudo systemctl daemon-reload

echo "Instalando logrotate..."
sudo cp "$(dirname "$0")/logrotate-softspend" /etc/logrotate.d/softspend

echo "Habilitando e iniciando servico..."
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# ---------------------------------------------------------------------------
# nginx + TLS
#
# A config final referencia os certificados do Let's Encrypt. Numa maquina nova
# eles ainda nao existem, e instalar essa config direto deixa o nginx sem subir
# (`nginx -t` falha), o que por sua vez impede o certbot de responder ao desafio
# HTTP-01. Por isso o fluxo e: config HTTP-only -> certbot -> config final.
# ---------------------------------------------------------------------------
echo "Instalando nginx e certbot..."
sudo apt install -y nginx certbot python3-certbot-nginx

NGINX_CONF="$(dirname "$0")/nginx-softspend.conf"
DOMAIN="${DOMAIN:-softspend.com.br}"
ACME_WEBROOT=/var/www/certbot

if [ ! -f "$NGINX_CONF" ]; then
    echo "AVISO: $NGINX_CONF nao encontrado; nginx nao foi configurado."
    exit 0
fi

sudo mkdir -p "$ACME_WEBROOT"

# Config minima: serve o desafio ACME e faz proxy da API sobre HTTP. Sem
# referencia a certificado, entao o nginx sempre sobe.
sudo tee /etc/nginx/sites-available/softspend > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 20M;

    location /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/softspend /etc/nginx/sites-enabled/softspend
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    if [ -n "${CERTBOT_EMAIL:-}" ]; then
        echo "Obtendo certificado SSL para $DOMAIN..."
        sudo certbot certonly --webroot -w "$ACME_WEBROOT" \
            -d "$DOMAIN" --agree-tos --non-interactive \
            --email "$CERTBOT_EMAIL" || true
    else
        echo "AVISO: CERTBOT_EMAIL nao definido; certificado nao foi emitido."
    fi
fi

# So troca para a config com TLS se o certificado realmente existir. Caso
# contrario o nginx segue no ar em HTTP — degradado, mas nao fora do ar.
if [ -f "$CERT_DIR/fullchain.pem" ]; then
    echo "Aplicando config nginx com TLS..."
    sudo cp /etc/nginx/sites-available/softspend /tmp/softspend-nginx-http.bak
    sudo cp "$NGINX_CONF" /etc/nginx/sites-available/softspend

    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "TLS ativo em https://$DOMAIN"
    else
        echo "ERRO: config TLS invalida; revertendo para HTTP."
        sudo cp /tmp/softspend-nginx-http.bak /etc/nginx/sites-available/softspend
        sudo nginx -t && sudo systemctl reload nginx
        exit 1
    fi
else
    echo "AVISO: sem certificado em $CERT_DIR; nginx segue apenas em HTTP."
    echo "      Depois de apontar o DNS para esta instancia, rode:"
    echo "      sudo certbot certonly --webroot -w $ACME_WEBROOT -d $DOMAIN"
    echo "      e execute este script novamente."
fi

echo "Pronto. Logs em: $LOG_DIR"
echo "Comandos uteis:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  tail -f $LOG_DIR/app.log"
