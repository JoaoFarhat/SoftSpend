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

echo "Pronto. Logs em: $LOG_DIR"
echo "Comandos uteis:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  tail -f $LOG_DIR/app.log"
