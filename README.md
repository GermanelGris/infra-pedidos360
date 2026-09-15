# infra — Pedidos360

Infraestructura de despliegue del sistema Pedidos360.

```
Angular (MSAL) ──Bearer JWT──> AWS API Gateway (JWT Authorizer)
                                   │
                                   ▼
 ec2-apps · Docker Compose
 ├─ ms-pedidos360-bff      :8080  valida JWT + roles (único puerto público)
 ├─ ms-pedidos360-orders   :8081  ──eventos──> Kafka  (orders.events, audit.timeline)
 │                                ──comandos─> RabbitMQ (email.send, kitchen.ticket, invoice.gen)
 ├─ ms-pedidos360-catalog  :8082
 ├─ ms-pedidos360-notify   :8083  <── RabbitMQ (q.cmd.email / kitchen / invoice + DLQ)
 ├─ ms-pedidos360-report   :8084  <── Kafka orders.events   → /api/report/*
 └─ ms-pedidos360-audit    :8085  <── Kafka audit.timeline  → /api/audit/*
        │
        ▼
 Amazon RDS MySQL (schemas pedidos360_orders / _catalog / _report / _audit)

 ec2-mq     · RabbitMQ + Management UI (5672, 15672)
 ec2-kafka  · Zookeeper + Kafka (9092) [+ Kafka UI 8090]
```

## Estructura

| Carpeta | Uso |
|---|---|
| `apps/compose.yml` | ec2-apps: bff, orders y catalog; con el perfil `messaging` también notify, report y audit |
| `apps/.env.example` | Variables requeridas (copiar a `.env`, que no se sube) |
| `mq/compose.yml` | ec2-mq: RabbitMQ con Management UI |
| `kafka/compose.yml` | ec2-kafka: Zookeeper + Kafka (con el perfil `ui` también Kafka UI) |
| `local/compose.yml` | Todo en un PC: MySQL, microservicios y, con el perfil `messaging`, RabbitMQ + Kafka |

Los repos se clonan uno al lado del otro:

```
pedidos360/
├─ infra/
├─ ms-pedidos360-bff/
├─ ms-pedidos360-orders/
├─ ms-pedidos360-catalog/
├─ ms-pedidos360-notify/
├─ ms-pedidos360-report/
└─ ms-pedidos360-audit/
```

## Mensajería: activación

La mensajería es **opcional**. Sin ella, la EP1 funciona igual.

| Variable en orders | Comportamiento |
|---|---|
| `MESSAGING_ENABLED=false` (por defecto) | No se conecta a RabbitMQ ni a Kafka |
| `MESSAGING_ENABLED=true` | Después de cada commit publica el evento en `orders.events`, la auditoría en `audit.timeline` y los comandos en RabbitMQ |

### RabbitMQ (6 colas, 3 flujos)

| Exchange | Cola | Binding |
|---|---|---|
| `cmd.direct` | `q.cmd.email` / `q.cmd.kitchen` / `q.cmd.invoice` | `email.send` / `kitchen.ticket` / `invoice.gen` |
| `cmd.topic` | `q.cmd.email` / `q.cmd.kitchen` / `q.cmd.invoice` | `email.*` / `kitchen.#` / `invoice.*` |
| `cmd.dead.dlx` | `*.dlq` | misma routing key |

### Kafka

| Tópico | Particiones | Política | Retención |
|---|---|---|---|
| `orders.events` | 3 | delete | 7 días |
| `audit.timeline` | 3 | compact,delete | 30 días |
| `orders.events.report.DLT`, `audit.timeline.audit.DLT` | 3 | delete | 14 días |

## Local

```bash
cd local
docker compose up -d --build                                          # backend EP1
MESSAGING_ENABLED=true docker compose --profile messaging up -d --build # todo el caso
```

| UI | URL |
|---|---|
| RabbitMQ Management | http://localhost:15672 (pedidos360 / pedidos360) |

## AWS

**ec2-apps**
```bash
cd apps
cp .env.example .env && nano .env
docker compose up -d --build                         # EP1
docker compose --profile messaging up -d --build     # con mensajería (MESSAGING_ENABLED=true)
curl http://localhost:8080/actuator/health
```

**ec2-mq**
```bash
cd mq && docker compose up -d
```

**ec2-kafka**
```bash
cd kafka && KAFKA_ADVERTISED_HOST=<ip-privada-ec2-kafka> docker compose up -d
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
| ec2-apps | 22 | Mi IP |
| ec2-apps | 8080 | 0.0.0.0/0 (API Gateway) |
| RDS | 3306 | Security Group de ec2-apps |
| ec2-mq | 5672 | Security Group de ec2-apps |
| ec2-mq | 15672 | Mi IP (Management UI) |
| ec2-kafka | 9092 | Security Group de ec2-apps |

## Autores

Germán Maraboli & Camila Vera

Proyecto Pedidos360 · DSY1107 Desarrollo Cloud Native I · Duoc UC
