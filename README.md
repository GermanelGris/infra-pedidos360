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
                          ├─ rabbit1 + rabbit2 (clúster) UI :15672/:15673  cmd.direct    → q.cmd.{email,kitchen,invoice}
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
docker compose up -d mysql rabbit1 rabbit2   # solo la base y el clúster (servicios desde el IDE)
```

- RabbitMQ Management UI: http://localhost:15672 (rabbit1) y http://localhost:15673 (rabbit2), `pedidos360` / `pedidos360`
- Swagger del administrador: http://localhost:8086/swagger-ui.html

## EC2

```bash
cd apps
cp .env.example .env && nano .env
docker compose up -d --build
curl http://localhost:8080/actuator/health
```

## Clúster RabbitMQ y políticas

El broker es un clúster de dos nodos, `rabbit1` y `rabbit2`, definidos en el mismo compose con un ancla YAML común (`x-rabbit-node`).

| Parámetro | rabbit1 | rabbit2 |
|---|---|---|
| Imagen | `rabbitmq:4-management` | igual |
| Usuario / clave | `RABBITMQ_USER` / `RABBITMQ_PASSWORD` | igual |
| `RABBITMQ_ERLANG_COOKIE` | secreto del `.env` | igual (sin esto no se pueden unir) |
| `hostname` / nombre de nodo | `rabbit1` / `rabbit@rabbit1` | `rabbit2` / `rabbit@rabbit2` |
| Volumen de datos | `rabbit1-data` | `rabbit2-data` |
| Management UI publicada | 15672 | 15673 |

- `rabbitmq/rabbitmq.conf` (montado en ambos) declara el descubrimiento `classic_config` con los dos nodos: el segundo se une solo al primero.
- Los microservicios se conectan con `SPRING_RABBITMQ_ADDRESSES=rabbit1:5672,rabbit2:5672` y, si cae uno, se reconectan al otro.
- Las colas son clásicas y viven en el nodo donde se declararon (`rabbit1`). Para que sobrevivan a la caída de ese nodo habría que declararlas como *quorum queues*.
- Verificación: `docker compose exec rabbit1 rabbitmqctl cluster_status` (Running Nodes: `rabbit@rabbit1`, `rabbit@rabbit2`) o Management UI → Overview → Nodes.

`rabbitmq/policies.sh` lo ejecuta el contenedor `rabbit-policies` cuando el clúster está arriba (luego termina con código 0):

| Policy | Colas | Definición |
|---|---|---|
| `colas-negocio` | `q.cmd.{email,kitchen,invoice}`, `q.report.orders`, `q.audit.orders` | `max-length` 10000, `overflow` reject-publish-dlx, `message-ttl` 24 h |
| `colas-dlq` | `*.dlq` | `max-length` 5000, `message-ttl` 7 días |
| `colas-temporales` | `tmp.*` (creadas desde el administrador) | `expires` 1 h sin uso, `max-length` 1000 |

Se usan policies y no argumentos `x-*` en la declaración porque una policy se cambia en caliente; cambiar los argumentos de una cola existente da `PRECONDITION_FAILED`. Las colas `.retry` no llevan policy: tienen su propio TTL de 5 s.

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
| EC2 | 15672, 15673 | Mi IP (Management UI de rabbit1 y rabbit2) |
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

Germán Marabolí, Sebastián Velez & Camila Vera

Proyecto Pedidos360 · DSY1107 Desarrollo Cloud Native I · Duoc UC
