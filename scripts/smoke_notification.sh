#!/usr/bin/env bash
#
# Comprueba de punta a punta, sobre el stack ya levantado, lo que mto-notification necesita del
# resto del dominio. No levanta nada: antes,
#
#   docker compose --profile all up -d && ./keycloak/apply-partials.sh
#
# y despues
#
#   scripts/smoke_notification.sh
#
# Habla con curl y con tokens del password grant que mto-realm-local.json abre en mto-frontend
# (solo en local), como documenta README.md. Cada paso imprime lo que comprueba y por que; un
# fallo no para el guion, para que una sola pasada diga todo lo que esta mal, y el codigo de
# salida es 1 si algo fallo.
#
# Fase 1 (lo que hay hoy en el stack):
#
#   1. mto-notification responde en su puerto y el gateway le enruta (/api/notifications/actuator/health).
#   2. El token de una persona lleva la audiencia mto-notification-api y los permisos de su perfil.
#   3. La API decide por recurso: sin token 401; con un permiso que no abre el recurso 403; con el
#      que lo abre, la cadena deja pasar (404 mientras el recurso no existe: esta es la fase 1).
#   4. Keycloak registra los accesos y mto-notification-svc puede leerlos con view-events: un login
#      y tres fallos seguidos de una persona aparecen en /admin/realms/mto/events.
#   5. Los eventos de administracion tambien: un cambio hecho por mto-users llega con el id interno
#      del cliente de su cuenta de servicio (authDetails.clientId es un UUID, no el clientId), que
#      es lo que distingue un cambio de la aplicacion de uno hecho en la consola.
#   6. El correo del realm llega a Mailpit: el correo de acciones de mto-users, que sin SMTP
#      fallaba con un 502, aparece en el buzon.
#
# Fase 2a (el servicio):
#
#   7. El lector de Keycloak alimenta el registro: las dos fuentes dan una pasada buena, el login y
#      los tres fallos del paso 4 salen por /access (con el permiso del auditor) y nunca por /activity.
#   8. Tres fallos seguidos son UNA racha (access.login.streak) y UN aviso: en la bandeja de
#      config.ops (perfil mto-ops), que la marca leida y que notificacion.lector no ve; por correo,
#      con la entrega expandida por el directorio y el mensaje en Mailpit. Un cuarto fallo no repite.
#   9. Un cambio del realm hecho con admin-cli llega como users.admin.user-updated con actor PERSON
#      y avisa como «fuera de la aplicacion».
#
# Fases 2b a 4b (los eventos propios de los demas servicios):
#
#  10. El cambio del paso 5, hecho por mto-users, llega con la persona (users.user.enabled de
#      usuarios.responsable) y el evento de administracion de Keycloak del mismo cambio, hecho por su
#      cuenta de servicio, queda fundido con el: solo sale con includeSuperseded=true.
#  11. Un trabajo de mto-configuration (una importacion de listas de valores en seco) deja UNA linea
#      configuration.job.finished y UN aviso a quien lo lanzo.
#  12. Una orden urgente avisa a mantenimiento.responsable en su bandeja y por correo.
#  13. Un material que cruza su minimo avisa a almacen.responsable en su bandeja y por correo; un
#      segundo cruce queda en el registro pero no vuelve a avisar (freno de 24 h por material).
#
# Lo que deja en el stack, a proposito y con nombres que se reconocen: el tramo SMOKE-NOTIF de
# mantenimiento (via 999999, se reutiliza) con una orden urgente cancelada por pasada, el almacen
# SMOKE-NOTIF de stock (se reutiliza) y un material SMOKE-<fecha> retirado por pasada, ademas de los
# avisos y correos de cada paso. La importacion del paso 11 es en seco: no escribe ningun catalogo.

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATAFORMA="$(dirname "$AQUI")"
# Los repositorios hermanos (el paso 11 sube un maestro de mto-configuration).
HERMANOS="$(dirname "$PLATAFORMA")"

# Los puertos y el secreto de la cuenta de servicio, del .env del stack (o del ejemplo si no hay).
if [[ -f "$PLATAFORMA/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$PLATAFORMA/.env"; set +a
else
  echo "No hay $PLATAFORMA/.env; se usan los valores de .env.example" >&2
  # shellcheck disable=SC1091
  set -a; source "$PLATAFORMA/.env.example"; set +a
fi

KC_URL="${KC_URL:-http://auth.mto.local:${KEYCLOAK_PORT:-8082}}"
KC_REALM="${KC_REALM:-mto}"
KC_ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-admin}"
GATEWAY="${GATEWAY_URL:-http://localhost:${MTO_GATEWAY_PORT:-8090}}"
NOTIFICATION="${NOTIFICATION_URL:-http://localhost:${MTO_NOTIFICATION_PORT:-8086}}"
MAILPIT="${MAILPIT_URL:-http://localhost:${MAILPIT_UI_PORT:-8025}}"
SVC_SECRET="${MTO_NOTIFICATION_SERVICE_CLIENT_SECRET:-mto-notification-svc-secret}"
CONTRASENA_LOCAL="${DEV_USERS_PASSWORD:-local}"

for herramienta in curl python3; do
  command -v "$herramienta" >/dev/null || { echo "Hace falta $herramienta" >&2; exit 2; }
done

BIEN=0
MAL=0
ok()   { BIEN=$((BIEN + 1)); echo "  [ok]   $1"; }
mal()  { MAL=$((MAL + 1)); echo "  [MAL]  $1" >&2; }
paso() { echo; echo "$1"; }

# Codigo HTTP de una peticion; el cuerpo, si hace falta, en el fichero que se indique.
codigo() { curl -sS -o "${CUERPO:-/dev/null}" -w '%{http_code}' "$@" 2>/dev/null || echo "000"; }

# Un campo de un JSON por su ruta con puntos (a.b.0.c), o vacio.
campo() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("", end=""); sys.exit()
for parte in sys.argv[1].split("."):
    if isinstance(d, list):
        d = d[int(parte)] if parte.isdigit() and int(parte) < len(d) else None
    elif isinstance(d, dict):
        d = d.get(parte)
    else:
        d = None
    if d is None:
        break
print("" if d is None else (json.dumps(d) if isinstance(d, (dict, list)) else d), end="")
' "$1"
}

# Token del password grant de una persona (mto-frontend), o vacio.
token_de() {
  curl -sS -X POST "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=mto-frontend \
    -d "username=$1" -d "password=$2" 2>/dev/null | campo access_token | tr -d '\r'
}

# Token de una cuenta de servicio (client_credentials), o vacio.
token_de_servicio() {
  curl -sS -X POST "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
    -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$2" 2>/dev/null \
    | campo access_token | tr -d '\r'
}

# El payload de un JWT, en JSON, sin comprobar la firma: aqui solo se mira lo que lleva dentro.
claims_de() {
  python3 -c '
import base64, json, sys
parte = sys.argv[1].split(".")[1]
print(json.dumps(json.loads(base64.urlsafe_b64decode(parte + "=" * (-len(parte) % 4)))))
' "$1"
}

# Espera hasta que un GET responda el codigo pedido, con un tope de segundos.
esperar() {
  local url="$1" esperado="$2" tope="${3:-60}" i
  for ((i = 0; i < tope; i++)); do
    [[ "$(codigo "$url")" == "$esperado" ]] && return 0
    sleep 1
  done
  return 1
}

# Espera en la bandeja del token $1 un aviso de la regla $2 sobre el sujeto $3 (el id de la orden,
# del material, del trabajo...), desde $DESDE. Deja su id en AVISO_ID. Un print de Python acaba en
# \r\n con el Python de Windows: se escribe sin salto de linea, como en campo().
aviso() {
  local token="$1" regla="$2" sujeto="$3" i
  AVISO_ID=""
  for ((i = 0; i < 30; i++)); do
    if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $token" "$API/inbox?from=$DESDE&size=100")" == "200" ]]; then
      AVISO_ID="$(python3 -c '
import json, sys
for item in json.load(open(sys.argv[1])).get("content", []):
    if item.get("ruleKey") == sys.argv[2] and item.get("subjectId") == sys.argv[3]:
        print(item["id"], end="")
        break
' "$CUERPO" "$regla" "$sujeto")"
      [[ -n "$AVISO_ID" ]] && return 0
    fi
    sleep 2
  done
  return 1
}

# Espera en Mailpit un correo para la direccion $1 cuyo asunto lleve $2.
correo() {
  local para="$1" texto="$2" i
  for ((i = 0; i < 30; i++)); do
    if curl -sS "$MAILPIT/api/v1/search?query=to:$para&limit=50" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if any(sys.argv[1] in (m.get("Subject") or "") for m in d.get("messages") or []) else 1)
' "$texto"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- 1. El servicio y el gateway ------------------------------------------------------------------
paso "1. mto-notification responde y el gateway le enruta"

if esperar "$NOTIFICATION/actuator/health/readiness" 200 90; then
  ok "mto-notification listo en $NOTIFICATION"
else
  mal "mto-notification no responde en $NOTIFICATION/actuator/health/readiness (esta levantado con --profile all o notification?)"
fi

if esperar "$GATEWAY/api/notifications/actuator/health" 200 30; then
  ok "el gateway enruta /api/notifications/actuator/health"
else
  mal "el gateway no enruta /api/notifications/actuator/health (codigo $(codigo "$GATEWAY/api/notifications/actuator/health"))"
fi

# --- 2. La audiencia y los permisos en el token ---------------------------------------------------
paso "2. El token de una persona lleva la audiencia mto-notification-api y sus permisos"

TOKEN_AUDITOR="$(token_de notificacion.auditor "$CONTRASENA_LOCAL")"
TOKEN_LECTOR="$(token_de notificacion.lector "$CONTRASENA_LOCAL")"
TOKEN_RESPONSABLE="$(token_de notificacion.responsable "$CONTRASENA_LOCAL")"
if [[ -z "$TOKEN_AUDITOR" || -z "$TOKEN_LECTOR" || -z "$TOKEN_RESPONSABLE" ]]; then
  mal "no hay token para los usuarios de desarrollo de mto-notification (se aplico mto-notification-dev.json?)"
else
  CLAIMS="$(claims_de "$TOKEN_AUDITOR")"
  if [[ "$(printf '%s' "$CLAIMS" | campo aud)" == *'"mto-notification-api"'* ]]; then
    ok "el token lleva mto-notification-api en aud (audience mapper de mto-frontend)"
  else
    mal "el token de notificacion.auditor no lleva mto-notification-api en aud: $(printf '%s' "$CLAIMS" | campo aud)"
  fi
  ROLES="$(printf '%s' "$CLAIMS" | campo resource_access.mto-notification-api.roles)"
  for rol in notification-inbox notification-activity-read notification-access-read; do
    if [[ "$ROLES" == *"\"$rol\""* ]]; then
      ok "notificacion.auditor tiene $rol (perfil mto-notification-auditor)"
    else
      mal "a notificacion.auditor le falta $rol: $ROLES"
    fi
  done
  if [[ "$ROLES" == *'"notification-admin"'* ]]; then
    mal "notificacion.auditor NO deberia tener notification-admin"
  else
    ok "notificacion.auditor no tiene notification-admin"
  fi
fi

# --- 3. La API decide por recurso -----------------------------------------------------------------
paso "3. Sin token 401; un permiso no abre el recurso de otro (403); el suyo deja pasar"

API="$GATEWAY/api/notifications"
c="$(codigo "$API/inbox")"
[[ "$c" == "401" ]] && ok "GET /inbox sin token: 401" || mal "GET /inbox sin token: $c (se esperaba 401)"

if [[ -n "$TOKEN_LECTOR" ]]; then
  c="$(codigo -H "Authorization: Bearer $TOKEN_LECTOR" "$API/access")"
  [[ "$c" == "403" ]] && ok "GET /access con notification-inbox + activity-read pero sin access-read: 403" \
    || mal "GET /access como notificacion.lector: $c (se esperaba 403)"
  c="$(codigo -H "Authorization: Bearer $TOKEN_LECTOR" "$API/admin/sources")"
  [[ "$c" == "403" ]] && ok "GET /admin/sources sin notification-admin: 403" \
    || mal "GET /admin/sources como notificacion.lector: $c (se esperaba 403)"
  c="$(codigo -H "Authorization: Bearer $TOKEN_LECTOR" "$API/inbox")"
  case "$c" in
    200) ok "GET /inbox con notification-inbox: 200, la bandeja de notificacion.lector" ;;
    404) mal "GET /inbox con notification-inbox: 404, la imagen del stack es anterior a la fase 2a" ;;
    *)   mal "GET /inbox como notificacion.lector: $c (se esperaba 200)" ;;
  esac
fi

# --- 4. Los eventos de acceso, leidos con la cuenta de servicio -----------------------------------
paso "4. Keycloak registra los accesos y mto-notification-svc los lee con view-events"

TOKEN_SVC="$(token_de_servicio mto-notification-svc "$SVC_SECRET")"
if [[ -z "$TOKEN_SVC" ]]; then
  mal "mto-notification-svc no consigue token con el secreto de .env (MTO_NOTIFICATION_SERVICE_CLIENT_SECRET)"
else
  ok "mto-notification-svc consigue su token (client_credentials)"

  # Un login que se vea: config.responsable entra por el password grant.
  if [[ -n "$(token_de config.responsable "$CONTRASENA_LOCAL")" ]]; then
    ok "login de config.responsable"
  else
    mal "config.responsable no consigue token"
  fi
  # Y tres fallos seguidos de config.lector. El realm no tiene proteccion de fuerza bruta, asi que
  # no bloquea a nadie; en la fase 2a estos tres fallos seran UN access.login.streak.
  for i in 1 2 3; do
    curl -sS -o /dev/null -X POST "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=mto-frontend -d username=config.lector -d "password=incorrecta-$i"
  done

  CUERPO="$(mktemp)"
  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_SVC" "$KC_URL/admin/realms/$KC_REALM/events?type=LOGIN&max=20")"
  if [[ "$c" != "200" ]]; then
    mal "GET /admin/realms/$KC_REALM/events con mto-notification-svc: $c (falta view-events? lo concede apply-partials.sh)"
  elif python3 -c '
import json, sys
eventos = json.load(open(sys.argv[1]))
sys.exit(0 if any(e.get("type") == "LOGIN" and (e.get("details") or {}).get("username") == "config.responsable" for e in eventos) else 1)
' "$CUERPO"; then
    ok "el login de config.responsable esta en los eventos del realm (eventsEnabled y LOGIN activados)"
  else
    mal "el login de config.responsable no aparece en /events?type=LOGIN (eventos del realm apagados o LOGIN fuera de enabledEventTypes?)"
  fi

  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_SVC" "$KC_URL/admin/realms/$KC_REALM/events?type=LOGIN_ERROR&max=50")"
  if [[ "$c" == "200" ]] && python3 -c '
import json, sys
eventos = json.load(open(sys.argv[1]))
fallos = [e for e in eventos if e.get("type") == "LOGIN_ERROR" and (e.get("details") or {}).get("username") == "config.lector"]
sys.exit(0 if len(fallos) >= 3 else 1)
' "$CUERPO"; then
    ok "los tres fallos de config.lector estan en /events?type=LOGIN_ERROR, con su usuario e IP"
  else
    mal "no se ven tres LOGIN_ERROR de config.lector (codigo $c)"
  fi

  # Lo que NO tiene que estar: los tokens de las cuentas de servicio no son accesos de nadie.
  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_SVC" "$KC_URL/admin/realms/$KC_REALM/events?type=CLIENT_LOGIN&max=5")"
  if [[ "$c" == "200" && "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))), end="")' "$CUERPO")" == "0" ]]; then
    ok "ningun CLIENT_LOGIN registrado: los tipos de maquina siguen fuera de enabledEventTypes"
  else
    mal "hay eventos CLIENT_LOGIN en el realm (codigo $c): el ruido de las cuentas de servicio se esta registrando"
  fi

  # Y lo que no puede hacer: reconfigurar o borrar eventos exige manage-events, que no tiene.
  c="$(codigo -X DELETE -H "Authorization: Bearer $TOKEN_SVC" "$KC_URL/admin/realms/$KC_REALM/events")"
  [[ "$c" == "403" ]] && ok "DELETE /events con mto-notification-svc: 403 (sin manage-events, es un lector)" \
    || mal "DELETE /events con mto-notification-svc: $c (se esperaba 403: no debe tener manage-events)"
  rm -f "$CUERPO"
fi

# --- 5. Los eventos de administracion, con el cliente que los hizo --------------------------------
paso "5. Un cambio hecho por mto-users llega como evento de administracion con su clientId"

TOKEN_USUARIOS="$(token_de usuarios.responsable "$CONTRASENA_LOCAL")"
if [[ -z "$TOKEN_USUARIOS" || -z "${TOKEN_SVC:-}" ]]; then
  mal "sin token de usuarios.responsable o de mto-notification-svc; se omite"
else
  CUERPO="$(mktemp)"
  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_USUARIOS" "$GATEWAY/api/users?username=config.lector&max=1")"
  ID_LECTOR="$(campo content.0.id < "$CUERPO")"
  if [[ "$c" != "200" || -z "$ID_LECTOR" ]]; then
    mal "no se encuentra config.lector por /api/users (codigo $c): esta mto-users levantado?"
  else
    # Un cambio que no cambia nada: activar a quien ya esta activo. Keycloak lo registra igual.
    c="$(codigo -X PATCH -H "Authorization: Bearer $TOKEN_USUARIOS" -H "Content-Type: application/json" \
      -d '{"enabled": true}' "$GATEWAY/api/users/$ID_LECTOR/enabled")"
    if [[ "$c" != "200" && "$c" != "204" ]]; then
      mal "PATCH /api/users/$ID_LECTOR/enabled: $c"
    else
      sleep 1
      # authDetails.clientId trae el id INTERNO del cliente (un UUID), no su clientId: se resuelve
      # con view-clients, que es lo mismo que hace mto-notification al leerlo.
      ID_USERS_SVC="$(curl -sS -H "Authorization: Bearer $TOKEN_SVC" "$KC_URL/admin/realms/$KC_REALM/clients?clientId=mto-users-svc" 2>/dev/null \
        | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d[0]["id"] if d else "", end="")')"
      c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_SVC" \
        "$KC_URL/admin/realms/$KC_REALM/admin-events?resourceTypes=USER&operationTypes=UPDATE&max=20")"
      if [[ -z "$ID_USERS_SVC" ]]; then
        mal "mto-notification-svc no puede leer el cliente mto-users-svc (falta view-clients?)"
      elif [[ "$c" == "200" ]] && python3 -c '
import json, sys
eventos = json.load(open(sys.argv[1]))
sys.exit(0 if any(e.get("resourcePath") == "users/" + sys.argv[2] and (e.get("authDetails") or {}).get("clientId") == sys.argv[3] for e in eventos) else 1)
' "$CUERPO" "$ID_LECTOR" "$ID_USERS_SVC"; then
        ok "el UPDATE de users/$ID_LECTOR esta en /admin-events con authDetails.clientId = id interno de mto-users-svc"
      else
        mal "el cambio de mto-users no aparece en /admin-events con el id de mto-users-svc (codigo $c; adminEventsEnabled?)"
      fi
    fi
  fi
  rm -f "$CUERPO"
fi

# --- 6. El correo del realm llega a Mailpit -------------------------------------------------------
paso "6. El correo de acciones de mto-users llega a Mailpit (SMTP del realm local)"

if ! esperar "$MAILPIT/api/v1/info" 200 10; then
  mal "Mailpit no responde en $MAILPIT (es infraestructura: arranca sin perfil)"
elif [[ -z "${TOKEN_USUARIOS:-}" || -z "${ID_LECTOR:-}" ]]; then
  mal "sin usuarios.responsable o sin el id de config.lector; se omite"
else
  ok "Mailpit responde en $MAILPIT"
  CUERPO="$(mktemp)"
  c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_USUARIOS" -H "Content-Type: application/json" \
    -d '{"actions": ["UPDATE_PASSWORD"]}' "$GATEWAY/api/users/$ID_LECTOR/execute-actions-email")"
  if [[ "$c" != "202" ]]; then
    mal "POST /api/users/$ID_LECTOR/execute-actions-email: $c $(campo errorCode < "$CUERPO") (sin SMTP en el realm era 502 KC-502)"
  else
    LLEGO=0
    for ((i = 0; i < 20; i++)); do
      if curl -sS "$MAILPIT/api/v1/search?query=to:config.lector@mto.local&limit=5" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if (d.get("messages_count") or len(d.get("messages") or [])) > 0 else 1)
'; then
        LLEGO=1; break
      fi
      sleep 1
    done
    if [[ $LLEGO -eq 1 ]]; then
      ok "el correo de acciones para config.lector@mto.local esta en Mailpit ($MAILPIT)"
    else
      mal "el correo de acciones no ha llegado a Mailpit en 20 s (smtpServer del realm apuntando a mailpit:1025?)"
    fi
  fi
  rm -f "$CUERPO"
fi

# --- 7. El registro y los accesos por la API (fase 2a) --------------------------------------------
paso "7. El lector de Keycloak alimenta el registro: las fuentes avanzan y los accesos salen por la API"

# Todo lo de esta fase se mira desde hace diez minutos: el guion puede pasarse varias veces al dia
# y el registro guarda los accesos 90 dias.
# Sin salto de linea: con el Python de Windows acabaria en \r, que bash no quita y que rompe la URL.
DESDE="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"), end="")')"
# config.ops (perfil mto-ops) tiene la bandeja, el registro y la administracion; los accesos, con
# usuario e IP, son del auditor.
TOKEN_OPS="$(token_de config.ops "$CONTRASENA_LOCAL")"

# Espera hasta que una lista paginada tenga al menos N elementos; deja el cuerpo en CUERPO.
esperar_total() {
  local url="$1" token="$2" minimo="$3" tope="${4:-60}" i total
  for ((i = 0; i < tope; i++)); do
    if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $token" "$url")" == "200" ]]; then
      total="$(campo page.totalElements < "$CUERPO")"
      [[ -n "$total" && "$total" -ge "$minimo" ]] && return 0
    fi
    sleep 2
  done
  return 1
}

if [[ -z "$TOKEN_OPS" || -z "${TOKEN_AUDITOR:-}" ]]; then
  mal "sin token de config.ops o de notificacion.auditor; se omite la fase 2a"
else
  CUERPO="$(mktemp)"
  # a) Las dos marcas del lector avanzan: la cuenta de servicio pide su token y lee /events y /admin-events.
  LEIDO=0
  for ((i = 0; i < 45; i++)); do
    if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/admin/sources")" == "200" ]] && python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
cursores = {c["kind"]: c for c in d.get("cursors", [])}
sys.exit(0 if all(cursores.get(k, {}).get("lastSuccessAt") and not cursores[k].get("lastError") for k in ("KEYCLOAK_LOGIN", "KEYCLOAK_ADMIN")) else 1)
' "$CUERPO"; then
      LEIDO=1; break
    fi
    sleep 2
  done
  if [[ $LEIDO -eq 1 ]]; then
    ok "GET /admin/sources: las dos fuentes de Keycloak con una pasada buena y sin error"
  else
    mal "las fuentes de Keycloak no dan una pasada buena en 90 s: $(campo cursors < "$CUERPO") (secreto de mto-notification-svc? view-events?)"
  fi

  # b) El login de config.responsable del paso 4 esta en el registro de accesos.
  if esperar_total "$API/access?username=config.responsable&outcome=SUCCESS&from=$DESDE" "$TOKEN_AUDITOR" 1 60; then
    ok "GET /access: el login de config.responsable es un access.login con su IP ($(campo content.0.ipAddress < "$CUERPO"))"
  else
    mal "el login de config.responsable no aparece en /access en 2 min (el lector sondea cada 20 s)"
  fi

  # c) Y los tres fallos de config.lector, cada uno con su linea.
  if esperar_total "$API/access?username=config.lector&type=access.login.failed&from=$DESDE" "$TOKEN_AUDITOR" 3 60; then
    ok "GET /access: los tres fallos de config.lector son tres access.login.failed"
  else
    mal "no hay tres access.login.failed de config.lector en /access: $(campo page.totalElements < "$CUERPO")"
  fi

  # d) Los accesos nunca salen por el registro general: category=ACCESS es un 400.
  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/activity?category=ACCESS")"
  [[ "$c" == "400" && "$(campo errorCode < "$CUERPO")" == "VAL-001" ]] \
    && ok "GET /activity?category=ACCESS: 400 VAL-001, los accesos tienen su endpoint y su permiso" \
    || mal "GET /activity?category=ACCESS: $c $(campo errorCode < "$CUERPO") (se esperaba 400 VAL-001)"
  rm -f "$CUERPO"
fi

# --- 8. La racha: tres fallos son UN aviso -------------------------------------------------------
paso "8. Tres fallos seguidos son UNA racha y UN aviso en la bandeja y por correo; el cuarto no repite"

if [[ -z "${TOKEN_OPS:-}" || -z "${TOKEN_AUDITOR:-}" ]]; then
  mal "sin token de config.ops o de notificacion.auditor; se omite"
else
  CUERPO="$(mktemp)"
  RACHA_URL="$API/access?username=config.lector&type=access.login.streak&from=$DESDE"
  if esperar_total "$RACHA_URL" "$TOKEN_AUDITOR" 1 60; then
    TOTAL="$(campo page.totalElements < "$CUERPO")"
    [[ "$TOTAL" == "1" ]] && ok "una sola access.login.streak de config.lector desde hace diez minutos" \
      || mal "hay $TOTAL rachas de config.lector desde hace diez minutos (se esperaba una)"
  else
    mal "no aparece ninguna access.login.streak de config.lector (umbral 3 en 10 min; el detector corre al ingerir el tercer fallo)"
  fi

  # El aviso, en la bandeja de config.ops (mto-ops es audiencia de la regla access-login-streak).
  ID_AVISO=""
  for ((i = 0; i < 15; i++)); do
    if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/inbox?from=$DESDE&size=50")" == "200" ]]; then
      ID_AVISO="$(python3 -c '
import json, sys
for item in json.load(open(sys.argv[1])).get("content", []):
    if item.get("ruleKey") == "access-login-streak" and "config.lector" in (item.get("title") or ""):
        print(item["id"], end=""); break
' "$CUERPO")"
      [[ -n "$ID_AVISO" ]] && break
    fi
    sleep 2
  done
  if [[ -z "$ID_AVISO" ]]; then
    mal "config.ops no tiene en su bandeja el aviso de la racha de config.lector (regla access-login-streak)"
  else
    ok "GET /inbox de config.ops: el aviso de la racha ($ID_AVISO)"
    c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_OPS" "$API/inbox/$ID_AVISO/read")"
    [[ "$c" == "200" && "$(campo read < "$CUERPO")" == "True" ]] && ok "POST /inbox/$ID_AVISO/read: leida" \
      || mal "POST /inbox/$ID_AVISO/read: $c read=$(campo read < "$CUERPO")"
    c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_LECTOR" "$API/inbox/$ID_AVISO/read" -X POST)"
    [[ "$c" == "404" ]] && ok "el mismo aviso no es de notificacion.lector: 404 NTF-404 (a quien le toca se resuelve con el token)" \
      || mal "POST /inbox/$ID_AVISO/read como notificacion.lector: $c (se esperaba 404)"

    # El correo: una entrega por audiencia, expandida a los miembros con direccion, y el mensaje en Mailpit.
    ENVIADA=0
    for ((i = 0; i < 30; i++)); do
      if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/admin/deliveries?notificationId=$ID_AVISO&channel=email&size=50")" == "200" ]] && python3 -c '
import json, sys
filas = json.load(open(sys.argv[1])).get("content", [])
sys.exit(0 if any(f.get("scope") == "RECIPIENT" and f.get("status") == "SENT" and f.get("recipient") == "config.ops@mto.local" for f in filas) else 1)
' "$CUERPO"; then
        ENVIADA=1; break
      fi
      sleep 2
    done
    if [[ $ENVIADA -eq 1 ]]; then
      ok "GET /admin/deliveries: la entrega a config.ops@mto.local esta SENT (audiencia PROFILE:mto-ops expandida por el directorio)"
    else
      mal "la entrega de correo a config.ops@mto.local no llega a SENT en 60 s: $(python3 -c 'import json,sys; print([(f.get("scope"), f.get("recipient") or f.get("audienceKey"), f.get("status"), f.get("lastError")) for f in json.load(open(sys.argv[1])).get("content", [])])' "$CUERPO")"
    fi
    LLEGO=0
    for ((i = 0; i < 15; i++)); do
      if curl -sS "$MAILPIT/api/v1/search?query=to:config.ops@mto.local%20subject:Racha&limit=5" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if (d.get("messages_count") or len(d.get("messages") or [])) > 0 else 1)
'; then
        LLEGO=1; break
      fi
      sleep 2
    done
    [[ $LLEGO -eq 1 ]] && ok "el correo «Racha de accesos fallidos» para config.ops@mto.local esta en Mailpit" \
      || mal "el correo de la racha no esta en Mailpit ($MAILPIT; SPRING_MAIL_HOST=mailpit en el servicio?)"
  fi

  # Un cuarto fallo dentro de la misma ventana no abre otra racha: la clave es la ventana.
  curl -sS -o /dev/null -X POST "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=mto-frontend -d username=config.lector -d password=incorrecta-4
  if esperar_total "$API/access?username=config.lector&type=access.login.failed&from=$DESDE" "$TOKEN_AUDITOR" 4 60; then
    sleep 5
    CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_AUDITOR" "$RACHA_URL" >/dev/null
    TOTAL="$(campo page.totalElements < "$CUERPO")"
    [[ "$TOTAL" == "1" ]] && ok "tras el cuarto fallo sigue habiendo una sola racha" \
      || mal "tras el cuarto fallo hay $TOTAL rachas (se esperaba una)"
  else
    mal "el cuarto fallo de config.lector no llega al registro en 2 min"
  fi
  rm -f "$CUERPO"
fi

# --- 9. Un cambio hecho fuera de la aplicacion ---------------------------------------------------
paso "9. Un cambio del realm desde la consola es «fuera de la aplicacion»"

TOKEN_KC_ADMIN="$(curl -sS -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASSWORD" 2>/dev/null \
  | campo access_token | tr -d '\r')"
if [[ -z "$TOKEN_KC_ADMIN" || -z "${TOKEN_OPS:-}" ]]; then
  mal "sin token del administrador de Keycloak (KC_BOOTSTRAP_ADMIN_*) o de config.ops; se omite"
else
  CUERPO="$(mktemp)"
  if [[ -z "${ID_LECTOR:-}" ]]; then
    CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_KC_ADMIN" "$KC_URL/admin/realms/$KC_REALM/users?username=config.lector&exact=true" >/dev/null
    ID_LECTOR="$(campo 0.id < "$CUERPO")"
  fi
  # Lo que haria alguien en la consola o con kcadm: un cambio que no cambia nada, con admin-cli.
  c="$(codigo -X PUT -H "Authorization: Bearer $TOKEN_KC_ADMIN" -H "Content-Type: application/json" \
    -d '{"enabled": true}' "$KC_URL/admin/realms/$KC_REALM/users/$ID_LECTOR")"
  if [[ "$c" != "204" ]]; then
    mal "PUT /admin/realms/$KC_REALM/users/$ID_LECTOR con admin-cli: $c"
  else
    ACTIVIDAD_URL="$API/activity?category=USERS&type=users.admin.user-updated&subjectId=$ID_LECTOR&from=$DESDE&size=50"
    VISTO=0
    for ((i = 0; i < 45; i++)); do
      if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$ACTIVIDAD_URL")" == "200" ]] && python3 -c '
import json, sys
filas = json.load(open(sys.argv[1])).get("content", [])
sys.exit(0 if any(f.get("sourceService") == "keycloak-admin" and (f.get("actor") or {}).get("kind") == "PERSON" for f in filas) else 1)
' "$CUERPO"; then
        VISTO=1; break
      fi
      sleep 2
    done
    if [[ $VISTO -eq 1 ]]; then
      # El del paso 5, hecho por mto-users, ya no sale aqui: el correlador lo funde con el evento de
      # mto-users del mismo cambio y /activity lo esconde. Lo comprueba el paso 10.
      ok "GET /activity: el cambio de la consola es users.admin.user-updated con actor PERSON (clientId admin-cli)"
    else
      mal "el cambio de la consola no aparece en /activity como users.admin.user-updated en 90 s"
    fi

    AVISO=0
    for ((i = 0; i < 15; i++)); do
      if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/inbox?from=$DESDE&size=50")" == "200" ]] && python3 -c '
import json, sys
sys.exit(0 if any(i.get("ruleKey") == "users-change-outside-application" for i in json.load(open(sys.argv[1])).get("content", [])) else 1)
' "$CUERPO"; then
        AVISO=1; break
      fi
      sleep 2
    done
    [[ $AVISO -eq 1 ]] && ok "config.ops tiene el aviso «Cambio en el realm fuera de la aplicacion» (regla users-change-outside-application)" \
      || mal "no hay aviso users-change-outside-application en la bandeja de config.ops"
  fi
  rm -f "$CUERPO"
fi

# --- 10. El cambio de mto-users, con la persona y una sola vez ------------------------------------
paso "10. El cambio del paso 5, hecho por mto-users, llega con la persona y el de Keycloak queda fundido"

if [[ -z "${TOKEN_OPS:-}" || -z "${ID_LECTOR:-}" ]]; then
  mal "sin token de config.ops o sin el id de config.lector del paso 5; se omite"
else
  CUERPO="$(mktemp)"
  # El paso 5 activo a config.lector desde mto-users: su evento (users.user.enabled, con
  # usuarios.responsable) y el de administracion que Keycloak escribe del mismo cambio
  # (users.admin.user-updated, con la cuenta de servicio de mto-users). El correlador marca el de
  # Keycloak con superseded_by apuntando al de mto-users, llegue el que llegue primero.
  FUNDIDA=""
  for ((i = 0; i < 45; i++)); do
    if [[ "$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/activity?category=USERS&subjectId=$ID_LECTOR&from=$DESDE&includeSuperseded=true&size=50")" == "200" ]]; then
      FUNDIDA="$(python3 -c '
import json, sys
filas = json.load(open(sys.argv[1])).get("content", [])
personas = {f["id"] for f in filas if f.get("type") == "users.user.enabled"
            and (f.get("actor") or {}).get("kind") == "PERSON"
            and (f.get("actor") or {}).get("username") == "usuarios.responsable"}
for f in filas:
    if (f.get("type") == "users.admin.user-updated" and (f.get("actor") or {}).get("kind") == "SERVICE"
            and f.get("supersededBy") in personas):
        print(f["id"], end="")
        break
' "$CUERPO")"
      [[ -n "$FUNDIDA" ]] && break
    fi
    sleep 2
  done
  if [[ -z "$FUNDIDA" ]]; then
    mal "no hay users.user.enabled de usuarios.responsable con el users.admin.user-updated de mto-users-svc fundido en 90 s (mto-users publica en mto.users.exchange?)"
  else
    ok "GET /activity?includeSuperseded=true: users.user.enabled con usuarios.responsable, y el users.admin.user-updated de mto-users-svc fundido en el"
    c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_OPS" "$API/activity?category=USERS&subjectId=$ID_LECTOR&from=$DESDE&size=50")"
    if [[ "$c" == "200" ]] && python3 -c '
import json, sys
sys.exit(0 if all(f.get("id") != sys.argv[2] for f in json.load(open(sys.argv[1])).get("content", [])) else 1)
' "$CUERPO" "$FUNDIDA"; then
      ok "GET /activity sin includeSuperseded no la ensena: el cambio cuenta una vez, con la persona"
    else
      mal "la linea fundida de Keycloak sale en /activity sin includeSuperseded (codigo $c)"
    fi
  fi
  rm -f "$CUERPO"
fi

# --- 11. Un trabajo de mto-configuration: una linea y un aviso a quien lo lanzo -------------------
paso "11. Un trabajo de mto-configuration deja UNA linea configuration.job.finished y UN aviso a quien lo lanzo"

TOKEN_CONFIG="$(token_de config.responsable "$CONTRASENA_LOCAL")"
if [[ -z "$TOKEN_CONFIG" ]]; then
  mal "sin token de config.responsable; se omite"
elif [[ ! -f "$HERMANOS/mto-configuration/data/lov-master.xlsx" ]]; then
  mal "no se encuentra $HERMANOS/mto-configuration/data/lov-master.xlsx (mto-configuration tiene que estar como hermano); se omite"
else
  CUERPO="$(mktemp)"
  # Una importacion de listas de valores EN SECO: no escribe ningun catalogo, pero el trabajo termina
  # y publica job.finished por mto.configuration.exchange. Las listas de valores no publican datos
  # maestros, asi que todo su rastro es esa linea y su aviso. El fichero va con ruta relativa desde su
  # repositorio: un curl nativo de Windows no entiende las rutas del shell.
  c="$(cd "$HERMANOS/mto-configuration" && CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_CONFIG" \
    -F "file=@data/lov-master.xlsx" "$GATEWAY/api/configuration/lovs/jobs/import?dryRun=true")"
  TRABAJO="$(campo id < "$CUERPO")"
  if [[ "$c" != "202" || -z "$TRABAJO" ]]; then
    mal "POST /api/configuration/lovs/jobs/import?dryRun=true: $c $(campo code < "$CUERPO") (un 429 es que ya corre otra importacion)"
  else
    ok "importacion de listas de valores en seco lanzada por config.responsable: trabajo $TRABAJO"
    if esperar_total "$API/activity?type=configuration.job.finished&subjectId=$TRABAJO" "$TOKEN_CONFIG" 1 60; then
      TOTAL="$(campo page.totalElements < "$CUERPO")"
      [[ "$TOTAL" == "1" ]] && ok "GET /activity: una linea configuration.job.finished del trabajo ($(campo content.0.payload.status < "$CUERPO"))" \
        || mal "hay $TOTAL lineas configuration.job.finished del trabajo $TRABAJO (se esperaba una)"
    else
      mal "el trabajo $TRABAJO no deja su linea configuration.job.finished en 2 min (mto-configuration publica en mto.configuration.exchange?)"
    fi
    if aviso "$TOKEN_CONFIG" configuration-job-finished "$TRABAJO"; then
      ok "config.responsable tiene el aviso del trabajo terminado (regla configuration-job-finished, a quien lo lanzo)"
    else
      mal "config.responsable no tiene el aviso del trabajo $TRABAJO en 60 s (regla configuration-job-finished)"
    fi
  fi
  rm -f "$CUERPO"
fi

# --- 12. Una orden urgente: aviso y correo a mantenimiento.responsable ----------------------------
paso "12. Una orden urgente avisa a mantenimiento.responsable, en su bandeja y por correo"

TOKEN_TECNICO="$(token_de mantenimiento.tecnico "$CONTRASENA_LOCAL")"
TOKEN_MANTENIMIENTO="$(token_de mantenimiento.responsable "$CONTRASENA_LOCAL")"
MANTENIMIENTO="$GATEWAY/api/maintenance"
if [[ -z "$TOKEN_TECNICO" || -z "$TOKEN_MANTENIMIENTO" ]]; then
  mal "sin token de mantenimiento.tecnico o de mantenimiento.responsable; se omite"
else
  CUERPO="$(mktemp)"
  # Un tramo propio y fijo, SMOKE-NOTIF, sobre una via que no existe (999999): se crea la primera vez y
  # se reutiliza despues. La orden es nueva en cada pasada y se cancela al final.
  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_TECNICO" "$MANTENIMIENTO/assets?code=SMOKE-NOTIF&size=20")"
  TRAMO="$(python3 -c '
import json, sys
for activo in json.load(open(sys.argv[1])).get("content", []):
    if activo.get("code") == "SMOKE-NOTIF":
        print(activo["id"], end="")
        break
' "$CUERPO" 2>/dev/null)"
  if [[ -z "$TRAMO" ]]; then
    c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_TECNICO" -H "Content-Type: application/json" \
      -d '{"code":"SMOKE-NOTIF","name":"Tramo del script de humo de mto-notification","trackId":999999,"startKp":0.000,"endKp":1.000,"trackKind":"MAIN"}' \
      "$MANTENIMIENTO/assets")"
    TRAMO="$(campo id < "$CUERPO")"
  fi
  if [[ -z "$TRAMO" ]]; then
    mal "no se encuentra ni se puede crear el tramo SMOKE-NOTIF en mto-maintenance (codigo $c)"
  else
    c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_TECNICO" -H "Content-Type: application/json" \
      -d "{\"title\":\"Prueba del script de humo\",\"type\":\"URGENT\",\"assetId\":\"$TRAMO\"}" "$MANTENIMIENTO/orders")"
    ORDEN="$(campo id < "$CUERPO")"
    CODIGO_ORDEN="$(campo code < "$CUERPO")"
    if [[ "$c" != "201" || -z "$ORDEN" ]]; then
      mal "POST /api/maintenance/orders con type URGENT: $c $(campo errorCode < "$CUERPO")"
    else
      ok "orden urgente $CODIGO_ORDEN creada por mantenimiento.tecnico sobre el tramo SMOKE-NOTIF"
      if aviso "$TOKEN_MANTENIMIENTO" maintenance-order-urgent "$ORDEN"; then
        ok "mantenimiento.responsable tiene el aviso «Orden urgente $CODIGO_ORDEN» (regla maintenance-order-urgent)"
      else
        mal "mantenimiento.responsable no tiene el aviso de $CODIGO_ORDEN en 60 s (mto-maintenance publica en mto.maintenance.exchange?)"
      fi
      if correo "mantenimiento.responsable@mto.local" "$CODIGO_ORDEN"; then
        ok "el correo de la orden urgente $CODIGO_ORDEN para mantenimiento.responsable@mto.local esta en Mailpit"
      else
        mal "el correo de la orden urgente $CODIGO_ORDEN no esta en Mailpit ($MAILPIT)"
      fi
      # Se cancela para no dejar ordenes urgentes abiertas; eso tambien avisa (maintenance-order-closed).
      c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_MANTENIMIENTO" -H "Content-Type: application/json" \
        -d '{"reason":"Prueba del script de humo de mto-notification"}' "$MANTENIMIENTO/orders/$ORDEN/cancel")"
      [[ "$c" == "200" ]] && ok "la orden $CODIGO_ORDEN, cancelada por mantenimiento.responsable" \
        || mal "POST /api/maintenance/orders/$ORDEN/cancel: $c $(campo errorCode < "$CUERPO")"
    fi
  fi
  rm -f "$CUERPO"
fi

# --- 13. Un material bajo minimo: un aviso al cruzar, y ninguno mas en el dia ---------------------
paso "13. Un material que cruza su minimo avisa a almacen.responsable una vez; el segundo cruce no repite"

TOKEN_ALMACEN="$(token_de almacen.responsable "$CONTRASENA_LOCAL")"
ALMACEN_API="$GATEWAY/api/stock"
if [[ -z "$TOKEN_ALMACEN" ]]; then
  mal "sin token de almacen.responsable; se omite"
else
  CUERPO="$(mktemp)"
  # Un almacen fijo, SMOKE-NOTIF, que se crea la primera vez; y un material nuevo en cada pasada,
  # porque el freno de la regla es de 24 h por material. El material se retira al final.
  c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_ALMACEN" "$ALMACEN_API/warehouses?search=SMOKE-NOTIF&size=20")"
  ALMACEN="$(python3 -c '
import json, sys
for almacen in json.load(open(sys.argv[1])).get("content", []):
    if almacen.get("code") == "SMOKE-NOTIF":
        print(almacen["id"], end="")
        break
' "$CUERPO" 2>/dev/null)"
  if [[ -z "$ALMACEN" ]]; then
    c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_ALMACEN" -H "Content-Type: application/json" \
      -d '{"code":"SMOKE-NOTIF","name":"Almacen del script de humo de mto-notification"}' "$ALMACEN_API/warehouses")"
    ALMACEN="$(campo id < "$CUERPO")"
  fi
  MATERIAL_CODIGO="SMOKE-$(date -u +%Y%m%d%H%M%S)"
  MATERIAL_CUERPO="{\"code\":\"$MATERIAL_CODIGO\",\"name\":\"Material del script de humo\",\"unitOfMeasure\":\"ud\",\"minimumStockLevel\":10"
  MATERIAL=""
  if [[ -n "$ALMACEN" ]]; then
    c="$(CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_ALMACEN" -H "Content-Type: application/json" \
      -d "$MATERIAL_CUERPO}" "$ALMACEN_API/materials")"
    MATERIAL="$(campo id < "$CUERPO")"
  fi
  if [[ -z "$ALMACEN" || -z "$MATERIAL" ]]; then
    mal "no se puede preparar el almacen SMOKE-NOTIF o el material $MATERIAL_CODIGO en mto-stock (codigo $c)"
  else
    movimiento() {
      CUERPO="$CUERPO" codigo -X POST -H "Authorization: Bearer $TOKEN_ALMACEN" -H "Content-Type: application/json" \
        -d "{\"materialId\":\"$MATERIAL\",\"warehouseId\":\"$ALMACEN\",\"quantity\":$2,\"externalReference\":\"SMOKE-NOTIF\"}" \
        "$ALMACEN_API/movements/$1"
    }
    # 15 de entrada y 10 de salida: el disponible pasa de 15 a 5, por debajo del minimo de 10.
    entrada="$(movimiento entries 15)"
    salida="$(movimiento outputs 10)"
    if [[ "$entrada" != "201" || "$salida" != "201" ]]; then
      mal "entrada $entrada y salida $salida del material $MATERIAL_CODIGO (se esperaban 201)"
    else
      ok "$MATERIAL_CODIGO: entrada de 15 y salida de 10, de 15 a 5 disponibles con un minimo de 10"
      if aviso "$TOKEN_ALMACEN" stock-material-below-minimum "$MATERIAL"; then
        ok "almacen.responsable tiene el aviso «Material $MATERIAL_CODIGO por debajo del minimo» (regla stock-material-below-minimum)"
      else
        mal "almacen.responsable no tiene el aviso de $MATERIAL_CODIGO en 60 s (mto-stock publica en mto.stock.exchange?)"
      fi
      if correo "almacen.responsable@mto.local" "$MATERIAL_CODIGO"; then
        ok "el correo de $MATERIAL_CODIGO para almacen.responsable@mto.local esta en Mailpit"
      else
        mal "el correo del material $MATERIAL_CODIGO bajo minimo no esta en Mailpit ($MAILPIT)"
      fi
      # Vuelve a cruzar: 10 de entrada (15) y 10 de salida (5). Stock publica otra vez y el registro lo
      # guarda, pero la regla no avisa otra vez del mismo material en 24 h.
      entrada="$(movimiento entries 10)"
      salida="$(movimiento outputs 10)"
      if [[ "$entrada" == "201" && "$salida" == "201" ]] \
          && esperar_total "$API/activity?type=stock.material.below-minimum&subjectId=$MATERIAL" "$TOKEN_ALMACEN" 2 30; then
        sleep 5
        CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_ALMACEN" "$API/inbox?from=$DESDE&size=100" >/dev/null
        AVISOS="$(python3 -c '
import json, sys
filas = json.load(open(sys.argv[1])).get("content", [])
print(sum(1 for f in filas if f.get("ruleKey") == "stock-material-below-minimum" and f.get("subjectId") == sys.argv[2]), end="")
' "$CUERPO" "$MATERIAL")"
        [[ "$AVISOS" == "1" ]] && ok "segundo cruce: dos lineas stock.material.below-minimum en el registro y un solo aviso (freno de 24 h por material)" \
          || mal "tras el segundo cruce hay $AVISOS avisos de $MATERIAL_CODIGO (se esperaba uno)"
      else
        mal "el segundo cruce de $MATERIAL_CODIGO no deja su segunda linea en el registro (entrada $entrada, salida $salida)"
      fi
    fi
    # Se retira el material: sus apuntes se quedan, pero deja de estar entre los activos.
    c="$(CUERPO="$CUERPO" codigo -X PUT -H "Authorization: Bearer $TOKEN_ALMACEN" -H "Content-Type: application/json" \
      -d "$MATERIAL_CUERPO,\"active\":false}" "$ALMACEN_API/materials/$MATERIAL")"
    [[ "$c" == "200" ]] && ok "el material $MATERIAL_CODIGO, retirado" \
      || mal "PUT /api/stock/materials/$MATERIAL con active=false: $c"
  fi
  rm -f "$CUERPO"
fi

# --- Resumen ---------------------------------------------------------------------------------------
echo
echo "$BIEN comprobaciones bien, $MAL mal."
echo "Deja el tramo y el almacen SMOKE-NOTIF, una orden urgente cancelada, un material SMOKE-<fecha> retirado y sus avisos y correos."
[[ $MAL -eq 0 ]]
