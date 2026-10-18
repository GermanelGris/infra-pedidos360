#!/bin/bash
# Paso 11 del informe: crea el .env en la EC2, construye las imágenes de a una y levanta el stack.
# Uso (Git Bash, desde infra/aws):  EIP=<ip-elastica> DB_HOST=<endpoint-rds> bash desplegar-ec2.sh
# Espera ~3 min después de crear la EC2 para que el user-data termine de instalar Docker y clonar los repos.
set -euo pipefail
: "${EIP:?Falta EIP}" "${DB_HOST:?Falta DB_HOST}"
KEY="${KEY:-../../../labsuser.pem}"   # llave en la carpeta que contiene pedidos360/ (o KEY=<ruta>)
read -r -s -p "Contraseña de la RDS: " DB_PASSWORD; echo
read -r -s -p "Contraseña para RabbitMQ: " RABBITMQ_PASSWORD; echo

ssh -i "$KEY" -o StrictHostKeyChecking=accept-new ec2-user@"$EIP" bash -s <<EOF
set -e
cd ~/pedidos360
for r in ms-pedidos360-notify ms-pedidos360-mq-admin; do
  [ -d \$r ] || git clone https://github.com/GermanelGris/\$r.git
done
for r in ms-pedidos360-bff ms-pedidos360-orders ms-pedidos360-catalog ms-pedidos360-notify ms-pedidos360-mq-admin infra; do
  (cd \$r && git pull)
done

cd infra/apps
cat > .env <<ENV
TENANT_ID=bd2636b9-f868-446b-a06f-542bde5b43ae
API_CLIENT_ID=9626370e-d9b7-4f84-9a68-444cde77f6da
API_SCOPE=Pedidos.ReadWrite
CORS_ALLOWED_ORIGINS=http://localhost:4200,https://germanelgris.github.io
DB_HOST=$DB_HOST
DB_USER=admin
DB_PASSWORD=$DB_PASSWORD
RABBITMQ_USER=pedidos360
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
ENV
chmod 600 .env

# De a una por la RAM limitada
sudo docker compose build catalog
sudo docker compose build orders
sudo docker compose build bff
sudo docker compose build notify
sudo docker compose build mq-admin
sudo docker compose up -d
sudo docker compose ps
sleep 40
curl -s http://localhost:8080/actuator/health; echo
curl -s -o /dev/null -w "GET /api/me sin token -> %{http_code}\n" http://localhost:8080/api/me
EOF
