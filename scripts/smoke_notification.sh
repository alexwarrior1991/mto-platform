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
#   5. Los eventos de administracion tambien: un cambio hecho por mto-users llega con el clientId
#      de su cuenta de servicio, que es lo que distingue un cambio de la aplicacion de uno hecho
#      en la consola.
#   6. El correo del realm llega a Mailpit: el correo de acciones de mto-users, que sin SMTP
#      fallaba con un 502, aparece en el buzon.
#
# Con cada fase del servicio se anaden aqui sus pasos, en este orden (README de mto-notification):
# la bandeja y el registro por la API (2a), la racha de tres fallos como UN aviso (2a), la
# importacion de LOV como UN aviso resumido y la de perfiles como UNA linea con su recuento (2b/2d),
# el cambio hecho fuera de la aplicacion frente al hecho desde el backoffice (2c/2d), la orden
# urgente que avisa a mantenimiento.responsable con correo (3b) y el material bajo minimo que avisa
# a almacen.responsable una sola vez al dia (4b).

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATAFORMA="$(dirname "$AQUI")"

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
  # En la fase 1 no hay recursos todavia: la cadena deja pasar y el servicio responde 404 (HTTP-404).
  # Cuando exista la bandeja, este paso pasara a esperar 200.
  c="$(codigo -H "Authorization: Bearer $TOKEN_LECTOR" "$API/inbox")"
  case "$c" in
    200) ok "GET /inbox con notification-inbox: 200 (la bandeja ya esta en el stack)" ;;
    404) ok "GET /inbox con notification-inbox: 404, la cadena deja pasar y el recurso aun no existe (fase 1)" ;;
    *)   mal "GET /inbox como notificacion.lector: $c (se esperaba 200 o, en la fase 1, 404)" ;;
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
  if [[ "$c" == "200" && "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CUERPO")" == "0" ]]; then
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
      c="$(CUERPO="$CUERPO" codigo -H "Authorization: Bearer $TOKEN_SVC" \
        "$KC_URL/admin/realms/$KC_REALM/admin-events?resourceTypes=USER&operationTypes=UPDATE&max=20")"
      if [[ "$c" == "200" ]] && python3 -c '
import json, sys
eventos = json.load(open(sys.argv[1]))
sys.exit(0 if any(e.get("resourcePath") == "users/" + sys.argv[2] and (e.get("authDetails") or {}).get("clientId") == "mto-users-svc" for e in eventos) else 1)
' "$CUERPO" "$ID_LECTOR"; then
        ok "el UPDATE de users/$ID_LECTOR esta en /admin-events con authDetails.clientId = mto-users-svc"
      else
        mal "el cambio de mto-users no aparece en /admin-events (codigo $c; adminEventsEnabled?)"
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

# --- Resumen ---------------------------------------------------------------------------------------
echo
echo "$BIEN comprobaciones bien, $MAL mal."
echo "Pasos de fases posteriores (bandeja, racha, importacion resumida, orden urgente, bajo minimo, cambio fuera de la aplicacion): se anaden con su fase."
[[ $MAL -eq 0 ]]
