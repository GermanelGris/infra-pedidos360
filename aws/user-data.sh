#!/bin/bash
# Se ejecuta UNA vez, como root, al primer arranque de la EC2 ec2-apps.
# Equivale a la "preparación de la instancia por SSH" del Paso 9 del informe.
set -euxo pipefail

# 1) Docker + Git
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user

# 2) Plugins de Docker: compose y buildx 0.19.3 (compose build exige buildx >= 0.17)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
curl -SL https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-amd64 \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-buildx

# 3) Swap de 2 GB (la t3.small tiene poca RAM para compilar 3 proyectos Java)
dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

# 4) Repos en ~/pedidos360
sudo -u ec2-user bash -c '
  mkdir -p ~/pedidos360 && cd ~/pedidos360
  git clone https://github.com/GermanelGris/ms-pedidos360-bff.git
  git clone https://github.com/GermanelGris/ms-pedidos360-orders.git
  git clone https://github.com/GermanelGris/ms-pedidos360-catalog.git
  git clone https://github.com/GermanelGris/infra-pedidos360.git infra
'
