# infra — Pedidos360

Infraestructura de despliegue del sistema Pedidos360.

```
Angular (MSAL) ──Bearer JWT──> AWS API Gateway (JWT Authorizer)
                                   │
                                   ▼
                          EC2 · Docker Compose
                          ├─ ms-pedidos360-bff       :8080 (valida JWT + roles)
                          ├─ ms-pedidos360-orders    :8081 (interno) ──publica──┐
                          ├─ ms-pedidos360-catalog   :8082 (interno)            ▼
                          ├─ rabbitmq                :5672 / UI :15672   cmd.direct    → q.cmd.{email,kitchen,invoice}
                          │                                              orders.events → q.report.orders, q.audit.orders
                          ├─ ms-pedidos360-notify    :8083 (comandos: aviso, cocina, boleta)
                          ├─ ms-pedidos360-report    :8084 (eventos → KPIs, vía BFF solo Admin)
                          ├─ ms-pedidos360-audit     :8085 (eventos → timeline, vía BFF solo Admin)
                          └─ ms-pedidos360-mq-admin  :8086 (API REST de colas/exchanges/bindings, vía BFF solo Admin)

                          Todos los consumidores: ACK/NACK manual, reintentos con cola .retry (TTL) y DLQ.
                                   │
                                   ▼
                          Amazon RDS MySQL
```

## Estructura

| Carpeta | Uso |
|---|---|
| `apps/compose.yml` | Despliegue en EC2 (bff, orders, catalog, rabbitmq, notify, report, audit, mq-admin) contra Amazon RDS |
| `apps/.env.example` | Variables requeridas (copiar a `.env`, que no se sube) |
| `local/compose.yml` | Entorno local completo: MySQL + RabbitMQ + catalog + orders + notify + report + audit + mq-admin + bff |
| `aws/` | Scripts de creación de la infraestructura y primer despliegue |
| `.github/workflows/cd.yml` | Aplica `apps/compose.yml` en la EC2 cuando cambia |

Los repos se clonan uno al lado del otro:

```
pedidos360/
├─ infra/
├─ ms-pedidos360-bff/
├─ ms-pedidos360-orders/
├─ ms-pedidos360-catalog/
├─ ms-pedidos360-notify/
├─ ms-pedidos360-report/
├─ ms-pedidos360-audit/
└─ ms-pedidos360-mq-admin/
```

## Local

```bash
cd local
docker compose up -d --build              # todo el backend
docker compose up -d mysql rabbitmq       # solo la base y el broker (servicios desde el IDE)
```

- RabbitMQ Management UI: http://localhost:15672 (`pedidos360` / `pedidos360`)
- Swagger del administrador: http://localhost:8086/swagger-ui.html

## EC2

```bash
cd apps
cp .env.example .env && nano .env
docker compose up -d --build
curl http://localhost:8080/actuator/health
```

## API Gateway (HTTP API)

| Configuración | Valor |
|---|---|
| Ruta | `ANY /api/{proxy+}` |
| Integración | HTTP URI `http://<EC2_IP>:8080/api/{proxy}` |
| Authorizer | JWT · issuer `https://login.microsoftonline.com/<TENANT_ID>/v2.0` · audience `<API_CLIENT_ID>` |
| CORS | origin `http://localhost:4200` · headers `authorization, content-type` · métodos `GET, POST, PUT, PATCH, DELETE, OPTIONS` |

## Security Groups

| Recurso | Puerto | Origen |
|---|---|---|
| EC2 | 22 | Mi IP |
| EC2 | 8080 | 0.0.0.0/0 (API Gateway) |
| EC2 | 15672 | Mi IP (Management UI de RabbitMQ) |
| RDS | 3306 | Security Group de la EC2 |

## CI/CD (GitHub Actions)

Cada microservicio tiene `.github/workflows/ci-cd.yml`:

1. **CI** (cada push y PR): `./mvnw -B verify` con Java 21.
2. **CD** (push a `main` con pruebas en verde): entra por SSH a la EC2, hace `git pull` en el repo y ejecuta `docker compose up -d --build <servicio>`. Solo se reconstruye el contenedor que cambió.

`infra` tiene `.github/workflows/cd.yml`, que aplica el compose cuando cambia `apps/`. El frontend se publica en GitHub Pages con `deploy-pages.yml`.

Configuración (una vez por repositorio, en *Settings → Secrets and variables → Actions*):

| Secret | Valor |
|---|---|
| `EC2_HOST` | IP elástica de la EC2 |
| `EC2_SSH_KEY` | Contenido completo de `labsuser.pem` |

Los runners de GitHub no tienen IP fija, así que el puerto 22 de la EC2 debe aceptar `0.0.0.0/0`. El acceso sigue protegido porque solo se entra con la llave:

```bash
aws ec2 authorize-security-group-ingress --group-id <SG_EC2> --protocol tcp --port 22 --cidr 0.0.0.0/0
```

> En AWS Academy el laboratorio se apaga: el deploy solo funciona con el lab iniciado y la EC2 encendida. La IP elástica no cambia entre sesiones.

## Autores

Germán Maraboli & Camila Vera

Proyecto Pedidos360 · DSY1107 Desarrollo Cloud Native I · Duoc UC
