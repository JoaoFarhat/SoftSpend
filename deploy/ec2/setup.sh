#!/bin/bash
set -e

APP_DIR=/home/ubuntu/SoftSpend/Python
LOG_DIR=/var/log/softspend
SERVICE_NAME=softspend

echo "Criando diretorio de logs..."
sudo mkdir -p "$LOG_DIR"
sudo chown ubuntu:ubuntu "$LOG_DIR"

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
