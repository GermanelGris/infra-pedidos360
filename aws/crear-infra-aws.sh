#!/bin/bash
# Infraestructura AWS de Pedidos360 (EP1) con AWS CLI.
# Reproduce los Pasos 9 a 13 del INFORME-AVANCE-EP1.md:
#   EC2 ec2-apps + Security Group + IP elástica + RDS MySQL + API Gateway (HTTP API + JWT).
#
# Requisitos:
#   - AWS CLI v2 con las credenciales del Learner Lab (AWS Details → AWS CLI → pegar en ~/.aws/credentials).
#     Caducan cada sesión del lab: vuelve a pegarlas si ves "ExpiredToken".
#   - Ejecutar desde Git Bash, dentro de esta carpeta (infra/aws):  bash crear-infra-aws.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1          # evita que Git Bash convierta "/aws/..." y "/api/..." en rutas de Windows
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

# ---------- Variables ----------
TENANT_ID="bd2636b9-f868-446b-a06f-542bde5b43ae"
API_CLIENT_ID="9626370e-d9b7-4f84-9a68-444cde77f6da"
FRONT_ORIGIN="http://localhost:4200"     # agrega la URL de GitHub Pages en CORS más abajo si la usas
KEY_NAME="vockey"                        # par de llaves del Learner Lab (labsuser.pem)
DB_USER="admin"
read -r -s -p "Contraseña para la RDS (mín. 8 caracteres): " DB_PASSWORD; echo
MY_IP="$(curl -s https://checkip.amazonaws.com)"

# ---------- Paso 9: Security Group + EC2 ----------
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_APPS=$(aws ec2 create-security-group --group-name pedidos360-apps-sg \
  --description "Pedidos360 EC2: SSH y BFF" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_APPS" --protocol tcp --port 22   --cidr "$MY_IP/32"
aws ec2 authorize-security-group-ingress --group-id "$SG_APPS" --protocol tcp --port 8080 --cidr 0.0.0.0/0

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.small \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_APPS" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-apps}]' \
  --user-data file://user-data.sh \
  --query 'Instances[0].InstanceId' --output text)
echo "EC2: $INSTANCE_ID (esperando a que arranque...)"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# ---------- Paso 12: IP elástica ----------
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" > /dev/null
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
echo "IP elástica: $EIP"

# ---------- Paso 10: RDS MySQL (solo accesible desde la EC2) ----------
# Equivale a "Conectarse a un recurso de computación EC2" de la consola.
SG_RDS=$(aws ec2 create-security-group --group-name sg-pedidos360-rds \
  --description "Pedidos360 RDS: 3306 solo desde la EC2" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" --protocol tcp --port 3306 --source-group "$SG_APPS"

aws rds create-db-instance \
  --db-instance-identifier pedidos360-db \
  --engine mysql \
  --db-instance-class db.t3.micro \
  --allocated-storage 20 --storage-type gp3 \
  --master-username "$DB_USER" --master-user-password "$DB_PASSWORD" \
  --vpc-security-group-ids "$SG_RDS" \
  --no-publicly-accessible --no-multi-az \
  --backup-retention-period 0 \
  --monitoring-interval 0 > /dev/null      # sin monitoreo mejorado (falla en Learner Lab)
echo "RDS creándose (5-10 min)..."
aws rds wait db-instance-available --db-instance-identifier pedidos360-db
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier pedidos360-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS endpoint: $DB_HOST"
# Los schemas pedidos360_orders y pedidos360_catalog los crean los microservicios (createDatabaseIfNotExist=true).

# ---------- Paso 13: API Gateway (HTTP API) ----------
API_ID=$(aws apigatewayv2 create-api --name pedidos360-gateway --protocol-type HTTP \
  --cors-configuration "{
    \"AllowOrigins\": [\"$FRONT_ORIGIN\"],
    \"AllowMethods\": [\"GET\",\"POST\",\"PUT\",\"PATCH\",\"DELETE\",\"OPTIONS\"],
    \"AllowHeaders\": [\"authorization\",\"content-type\"],
    \"MaxAge\": 300
  }" --query ApiId --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" \
  --integration-type HTTP_PROXY --integration-method ANY \
  --integration-uri "http://$EIP:8080/api/{proxy}" \
  --payload-format-version 1.0 --query IntegrationId --output text)

AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer --api-id "$API_ID" \
  --name azure-entra-jwt --authorizer-type JWT \
  --identity-source '$request.header.Authorization' \
  --jwt-configuration "{
    \"Issuer\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0\",
    \"Audience\": [\"$API_CLIENT_ID\", \"api://$API_CLIENT_ID\"]
  }" --query AuthorizerId --output text)

# Ruta protegida por el JWT
aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'ANY /api/{proxy+}' \
  --target "integrations/$INTEGRATION_ID" \
  --authorization-type JWT --authorizer-id "$AUTHORIZER_ID" > /dev/null

# Preflight CORS sin autorizador (el navegador no manda token en OPTIONS)
aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'OPTIONS /api/{proxy+}' \
  --target "integrations/$INTEGRATION_ID" > /dev/null

aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy > /dev/null

API_URL="https://$API_ID.execute-api.us-east-1.amazonaws.com"

# ---------- Resumen ----------
cat <<EOF

================ LISTO ================
EC2          : $INSTANCE_ID  (IP elástica $EIP)
SG EC2       : $SG_APPS
SG RDS       : $SG_RDS
RDS endpoint : $DB_HOST
API Gateway  : $API_URL   -> poner en apiBaseUrl de environment.ts

Siguiente paso: desplegar los microservicios en la EC2 (ver desplegar-ec2.sh)
  EIP=$EIP DB_HOST=$DB_HOST bash desplegar-ec2.sh
EOF
