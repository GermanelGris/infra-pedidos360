#!/bin/sh
# Políticas de retención y limpieza (P11). Las aplica el contenedor "rabbit-policies" una vez que el clúster
# está arriba; una policy se replica a todos los nodos y se aplica en caliente a las colas que calzan con el patrón.
# Se usan policies (y no argumentos x-* al declarar las colas) porque cambiar los argumentos de una cola existente
# provoca PRECONDITION_FAILED, mientras que una policy se puede cambiar sin recrear nada.
set -e
NODE=rabbit@rabbit1

rabbitmqctl -n "$NODE" await_startup

# Colas de negocio: como máximo 10 000 mensajes y 24 h de vida. Al llenarse, lo nuevo se rechaza hacia su DLQ
# (reject-publish-dlx) y lo que expira también se va a la DLQ, así nada se pierde en silencio.
rabbitmqctl -n "$NODE" set_policy --apply-to queues --priority 10 colas-negocio \
  '^q\.(cmd\.(email|kitchen|invoice)|report\.orders|audit\.orders)$' \
  '{"max-length":10000,"overflow":"reject-publish-dlx","message-ttl":86400000}'

# DLQ: como máximo 5 000 mensajes; se conservan 7 días para revisarlos y después se descartan.
rabbitmqctl -n "$NODE" set_policy --apply-to queues --priority 10 colas-dlq \
  '\.dlq$' \
  '{"max-length":5000,"message-ttl":604800000}'

# Colas temporales creadas desde el administrador (tmp.*): se borran solas tras 1 h sin uso.
rabbitmqctl -n "$NODE" set_policy --apply-to queues --priority 10 colas-temporales \
  '^tmp\.' \
  '{"expires":3600000,"max-length":1000}'

# Las colas .retry no llevan policy: ya declaran su propio x-message-ttl (5 s) para el reintento.
rabbitmqctl -n "$NODE" list_policies
