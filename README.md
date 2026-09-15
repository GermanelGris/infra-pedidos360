# infra — Pedidos360

Infraestructura de despliegue del sistema Pedidos360.

```
Angular (MSAL) ──Bearer JWT──> AWS API Gateway (JWT Authorizer)
                                   │
                                   ▼
                          EC2 · Docker Compose
                          ├─ ms-pedidos360-bff      :8080 (valida JWT + roles)
                          ├─ ms-pedidos360-orders   :8081 (interno)
                          └─ ms-pedidos360-catalog  :8082 (interno)
                                   │
                                   ▼
                          Amazon RDS MySQL
```

## Estructura

| Carpeta | Uso |
|---|---|
| `apps/compose.yml` | Despliegue en EC2 (bff, orders, catalog) contra Amazon RDS |
| `apps/.env.example` | Variables requeridas (copiar a `.env`, que no se sube) |
| `local/compose.yml` | Entorno local completo: MySQL + catalog + orders + bff |

Los repos se clonan uno al lado del otro:

```
pedidos360/
├─ infra/
├─ ms-pedidos360-bff/
├─ ms-pedidos360-orders/
└─ ms-pedidos360-catalog/
```

## Local

```bash
cd local
docker compose up -d --build        # todo el backend
docker compose up -d mysql          # solo la base (servicios desde el IDE)
```

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
| RDS | 3306 | Security Group de la EC2 |

## Autores

Germán Maraboli & Camila Vera

Proyecto Pedidos360 · DSY1107 Desarrollo Cloud Native I · Duoc UC
