#!/usr/bin/env bash
#
# Ensambla el realm 'mto' completo sobre el Keycloak local.
#
# El realm BASE lo crea el contenedor al arrancar con --import-realm (mto-realm-local.json): trae
# los ajustes del realm y 'mto-frontend', y nada mas. Todo lo demas -los clientes de cada servicio,
# sus permisos y sus perfiles- lo aporta cada repositorio con su propia importacion parcial, para
# que un rol se pueda cambiar en el mismo commit que el codigo que lo comprueba (SecurityRoles).
#
# EL ORDEN IMPORTA. Un compuesto solo puede nombrar roles de clientes que ya existan en el realm:
# mto-ops-cross-service.json nombra los cuatro, asi que va DESPUES de las parciales que los crean.
# Al reves Keycloak responde "App doesn't exist in role definitions" y no aplica nada.
#
# Uso:
#   ./keycloak/apply-partials.sh                 # con los usuarios de desarrollo
#   ./keycloak/apply-partials.sh --no-dev-users  # solo clientes, roles y perfiles
#
# Espera los cinco repositorios como hermanos en el mismo directorio.

set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8082}"
KC_REALM="${KC_REALM:-mto}"
KC_ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-admin}"

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATAFORMA="$(dirname "$AQUI")"
HERMANOS="$(dirname "$PLATAFORMA")"

CON_USUARIOS=1
case "${1:-}" in
  --no-dev-users) CON_USUARIOS=0 ;;
  "") ;;
  *) echo "Opcion desconocida: $1 (solo se admite --no-dev-users)" >&2; exit 2 ;;
esac

# Primero las parciales que CREAN los clientes; despues las que los nombran.
FICHEROS=(
  "$HERMANOS/mto-configuration/keycloak/mto-configuration-partial-import.json"
  "$HERMANOS/mto-stock/keycloak/mto-stock-partial-import.json"
  "$HERMANOS/mto-gateway/keycloak/mto-gateway-partial-import.json"
  "$HERMANOS/mto-maintenance/keycloak/mto-maintenance-partial-import.json"
  "$AQUI/mto-ops-cross-service.json"
)

if [[ $CON_USUARIOS -eq 1 ]]; then
  FICHEROS+=(
    "$HERMANOS/mto-configuration/keycloak/mto-configuration-dev.json"
    "$HERMANOS/mto-stock/keycloak/mto-stock-dev.json"
    "$HERMANOS/mto-maintenance/keycloak/mto-maintenance-dev.json"
  )
fi

# Se comprueban todos antes de aplicar ninguno: dejar el realm a medias por un fichero que falta
# es peor que no haber empezado.
faltan=0
for fichero in "${FICHEROS[@]}"; do
  if [[ ! -f "$fichero" ]]; then
    echo "No se encuentra $fichero" >&2
    faltan=1
  fi
done
if [[ $faltan -eq 1 ]]; then
  echo >&2
  echo "Los cinco repositorios tienen que estar como hermanos en $HERMANOS." >&2
  exit 1
fi

for herramienta in curl python3; do
  command -v "$herramienta" >/dev/null || { echo "Hace falta $herramienta" >&2; exit 1; }
done

# En MSYS2, Cygwin o Git Bash, 'python3' suele ser el Python NATIVO de Windows, y ese no entiende
# las rutas del shell: un '/drives/c/...' o un '/c/...' no significan nada para el. Bash resuelve
# el [[ -f ]] de arriba y Python despues no encuentra el fichero, de modo que la comprobacion
# previa da via libre y la ejecucion revienta a mitad de camino, que es justo lo que esa
# comprobacion existe para evitar.
#
#   FileNotFoundError: [Errno 2] No such file or directory:
#   '/drives/c/Users/.../mto-configuration/keycloak/mto-configuration-partial-import.json'
#
# cygpath es la traduccion oficial y solo existe en esos entornos; fuera de ellos la ruta ya
# sirve tal cual y la funcion no hace nada.
ruta_nativa() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

echo "Pidiendo token de administrador a $KC_URL"
# end="" y no un print a secas: en Windows, print() traduce el \n a \r\n, y la sustitucion de
# ordenes de bash quita el salto de linea final PERO NO EL RETORNO DE CARRO. El token queda con un
# \r pegado, la cabecera sale como 'Authorization: Bearer eyJ...\r' y el analizador HTTP la
# rechaza por malformada: 400 con el cuerpo vacio y NADA en el log de Keycloak, porque la peticion
# no llega a su codigo. El sintoma no se parece en nada a su causa.
TOKEN="$(curl -sS --fail-with-body -X POST \
  "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASSWORD" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"], end="")')"

# Ultima linea de defensa: cualquier \r que llegue hasta aqui, venga de donde venga, rompe la
# cabecera igual. Es la segunda vez que este guion se cae por no traducir entre el mundo de bash y
# el de Windows, asi que se limpia y ya.
TOKEN="${TOKEN//$'\r'/}"

if [[ -z "$TOKEN" ]]; then
  echo "No se ha podido obtener el token de administrador de $KC_URL" >&2
  exit 1
fi

for fichero in "${FICHEROS[@]}"; do
  nombre="$(basename "$fichero")"
  echo "Aplicando $nombre"

  # La estrategia por defecto de partialImport es FAIL: sin ifResourceExists el script no se puede
  # reejecutar. Y tiene que ser OVERWRITE y no SKIP porque una importacion parcial reescribe el rol
  # entero: con SKIP, mto-ops-cross-service.json se saltaria por existir ya el rol y el perfil de
  # explotacion se quedaria sin el Actuator de stock y del gateway, que es justo para lo que existe.
  cuerpo="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["ifResourceExists"] = "OVERWRITE"
json.dump(d, sys.stdout)
' "$(ruta_nativa "$fichero")")"

  respuesta="$(curl -sS --fail-with-body -X POST \
    "$KC_URL/admin/realms/$KC_REALM/partialImport" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$cuerpo")"

  python3 -c '
import json, sys
r = json.loads(sys.argv[1] or "{}")
print("   ", r.get("overwritten", 0), "sobrescritos,", r.get("added", 0), "anadidos,", r.get("skipped", 0), "omitidos")
' "$respuesta"
done

# Lo que una importacion parcial no puede traer: los roles de la cuenta de servicio de un cliente.
# mto-maintenance-svc llama a mto-stock y necesita stock-read y stock-write de mto-stock-api, pero
# un partialImport no asigna roles a usuarios de servicio y la parcial de mantenimiento tampoco
# deberia decidir por si sola que puede tocar en el almacen de otro. Se hace aqui, en el entorno
# local, por la API de administracion; en un entorno desplegado es una decision que se toma en la
# consola (Clients -> mto-maintenance-svc -> Service accounts roles). Reejecutable: asignar un rol
# que ya esta asignado no cambia nada.
conceder_roles_de_servicio() {
  local cliente_svc="$1" cliente_api="$2"; shift 2
  local roles=("$@")
  echo "Concediendo a la cuenta de servicio de $cliente_svc los roles ${roles[*]} de $cliente_api"

  local id_svc id_api usuario_svc
  id_svc="$(curl -sS --fail-with-body "$KC_URL/admin/realms/$KC_REALM/clients?clientId=$cliente_svc" \
    -H "Authorization: Bearer $TOKEN" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c[0]["id"] if c else "", end="")')"
  id_api="$(curl -sS --fail-with-body "$KC_URL/admin/realms/$KC_REALM/clients?clientId=$cliente_api" \
    -H "Authorization: Bearer $TOKEN" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c[0]["id"] if c else "", end="")')"
  if [[ -z "$id_svc" || -z "$id_api" ]]; then
    echo "   no se encuentra $cliente_svc o $cliente_api en el realm; se omite" >&2
    return 0
  fi
  usuario_svc="$(curl -sS --fail-with-body "$KC_URL/admin/realms/$KC_REALM/clients/$id_svc/service-account-user" \
    -H "Authorization: Bearer $TOKEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"], end="")')"

  local cuerpo
  cuerpo="$(curl -sS --fail-with-body "$KC_URL/admin/realms/$KC_REALM/clients/$id_api/roles" \
    -H "Authorization: Bearer $TOKEN" | python3 -c '
import json, sys
pedidos = set(sys.argv[1:])
roles = [{"id": r["id"], "name": r["name"]} for r in json.load(sys.stdin) if r["name"] in pedidos]
faltan = pedidos - {r["name"] for r in roles}
if faltan:
    sys.exit("roles inexistentes en el cliente: " + ", ".join(sorted(faltan)))
json.dump(roles, sys.stdout)
' "${roles[@]}")"

  curl -sS --fail-with-body -X POST \
    "$KC_URL/admin/realms/$KC_REALM/users/$usuario_svc/role-mappings/clients/$id_api" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$cuerpo"
  echo "    hecho"
}

conceder_roles_de_servicio mto-maintenance-svc mto-stock-api stock-read stock-write

echo
echo "Realm '$KC_REALM' ensamblado."
