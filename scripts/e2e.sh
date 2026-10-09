#!/usr/bin/env bash
#
# Las pruebas de punta a punta de mto-frontend (e2e/, Playwright) contra la plataforma entera: los
# seis servicios, el gateway, los dos frontales y la infraestructura, levantados aqui con este
# compose y con el realm ensamblado. Es lo que corre el job «e2e» del CI de mto-platform,
# mto-frontend y mto-backoffice; tambien vale en local, con Docker, Node 22 y la plataforma parada
# (la levanta el script, con las imagenes de cada commit).
#
#   scripts/e2e.sh
#
# Lo que hace, en orden:
#
#   1. Los repositorios. Cada hermano que falte al lado de mto-platform se clona en superficial, en
#      la misma rama si la tiene y si no en master, como hace el CI con el realm: un cambio
#      coordinado vive en la misma rama en todos y asi se prueba junto. Son publicos: no hace falta
#      token. El que ya este (el repo que llama al script, o todos en local) se usa tal cual.
#   2. Las imagenes. La de cada aplicacion es la que publico su CI para ese commit (sha-<7> en
#      GHCR) y, si no existe (una rama de trabajo, el commit de un PR), se construye desde el
#      checkout con la etiqueta e2e. MTO_<APP>_TAG le dice a compose cual usa cada una.
#   3. La plataforma: la infraestructura con --wait, el realm con apply-partials.sh y despues las
#      aplicaciones, hasta que todas responden (seis minutos como mucho).
#   4. Las pruebas, en mto-frontend, con CI=true (playwright.config.js: mas margen, sin test.only y
#      sin reintentos). El informe queda en mto-frontend/playwright-report y las trazas de lo que
#      falle, en mto-frontend/test-results.
#
# Si algo falla, el estado y los logs de compose quedan en $E2E_OUTPUT (por defecto
# mto-platform/e2e-output), que el CI sube junto al informe, y la plataforma se queda levantada
# para mirarla; la salida de cada imagen construida queda alli tambien. El propio log dice ademas lo
# que hace falta para entenderlo sin bajarse nada: por que no se ha construido una imagen, la pagina
# de cada prueba que ha fallado y las ultimas lineas de cada aplicacion, cada cosa en su grupo
# plegado en el CI. Sin reintentos: un fallo se diagnostica.
#
# El navegador llega a Keycloak (auth.mto.local) por los --host-resolver-rules de Playwright y las
# pruebas piden sus tokens a localhost: no hace falta tocar /etc/hosts.

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATAFORMA="$(dirname "$AQUI")"
HERMANOS="$(dirname "$PLATAFORMA")"
OUTPUT="${E2E_OUTPUT:-$PLATAFORMA/e2e-output}"
OWNER=alexwarrior1991
# Las aplicaciones de la plataforma: el sufijo del repositorio, el del servicio de compose y el de
# su imagen (mto-<app>).
APPS=(configuration stock maintenance users notification field gateway backoffice frontend)
INFRA=(postgres redis rabbitmq keycloak jaeger mailpit)

# Un bloque del log: plegado en el de GitHub Actions y con su cabecera en local. Lo de dentro son
# datos (paginas y logs, con lo que escribieron las pruebas): en el CI va entre stop-commands, para
# que ninguna linea que empiece por :: se lea como un comando del runner.
abrir_grupo() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    PAUSA="e2e-$RANDOM$RANDOM$RANDOM"
    echo "::group::$1"
    echo "::stop-commands::$PAUSA"
  else
    echo "=== $1"
  fi
}

cerrar_grupo() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::$PAUSA::"
    echo "::endgroup::"
  fi
}

# Lo que se ve de un fallo sin bajarse el artefacto: la pagina de cada prueba que ha fallado (el
# error-context.md que deja Playwright: el error y la instantanea de accesibilidad de la pagina) y
# las ultimas lineas de cada aplicacion.
contar_el_fallo() {
  local resultados="$HERMANOS/mto-frontend/test-results" fichero app
  if [[ -d "$resultados" ]]; then
    while IFS= read -r -d '' fichero; do
      abrir_grupo "La pagina al fallar: $(basename "$(dirname "$fichero")")"
      head -n 400 "$fichero"
      cerrar_grupo
    done < <(find "$resultados" -name error-context.md -print0 | sort -z)
  fi
  for app in "${APPS[@]}"; do
    abrir_grupo "Las ultimas lineas de mto-$app"
    (cd "$PLATAFORMA" && docker compose --profile all logs --no-color --tail 200 "$app") 2>&1 || true
    cerrar_grupo
  done
}

al_salir() {
  local estado=$?
  if [[ $estado -ne 0 && -f "$PLATAFORMA/.env" ]]; then
    mkdir -p "$OUTPUT"
    (cd "$PLATAFORMA" && docker compose --profile all ps -a) > "$OUTPUT/compose-ps.txt" 2>&1 || true
    (cd "$PLATAFORMA" && docker compose --profile all logs --no-color --timestamps) > "$OUTPUT/compose.log" 2>&1 || true
    contar_el_fallo || true
    echo "Ha fallado (salida $estado). El estado y los logs de la plataforma estan en $OUTPUT" >&2
  fi
}
trap al_salir EXIT

# --- 1. Los repositorios ------------------------------------------------------------------------

RAMA="${E2E_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}}"
if [[ -z "$RAMA" ]]; then
  RAMA="$(git -C "$PLATAFORMA" rev-parse --abbrev-ref HEAD)"
fi
echo "Rama de la pasada: $RAMA"

for repo in "${APPS[@]}"; do
  dir="$HERMANOS/mto-$repo"
  if [[ -d "$dir/.git" ]]; then
    echo "mto-$repo: el checkout que hay, en $(git -C "$dir" rev-parse --short=7 HEAD)"
    continue
  fi
  url="https://github.com/$OWNER/mto-$repo"
  ref=master
  if git ls-remote --exit-code --heads "$url" "$RAMA" > /dev/null 2>&1; then
    ref="$RAMA"
  fi
  git clone --quiet --depth 1 --branch "$ref" "$url" "$dir"
  echo "mto-$repo: $ref, en $(git -C "$dir" rev-parse --short=7 HEAD)"
done

# --- 2. Las imagenes ----------------------------------------------------------------------------

cd "$PLATAFORMA"
if [[ ! -f .env ]]; then
  cp .env.example .env
fi
# Los puertos de .env, para esperar a cada aplicacion donde compose la publica.
set -a
# shellcheck disable=SC1091
source .env
set +a

# Si GHCR tiene esa etiqueta: el registro responde 200 a la peticion del manifiesto, con un token
# anonimo (las imagenes son publicas). Solo pregunta; no descarga nada.
publicada() { # imagen (sin el registro) y etiqueta
  local token
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:$1:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"], end="")')" || return 1
  curl -fs -o /dev/null -I -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$1/manifests/$2"
}

# La imagen de una aplicacion desde su checkout. La salida entera de docker build queda en
# $OUTPUT/build-mto-<app>.log (el CI la sube con el resto) y, si falla, sus ultimas lineas salen en el
# log en su grupo: con --quiet solo se veia el paso que habia fallado, no por que (una descarga de
# Maven o de npm caida, por ejemplo).
construir() { # app e imagen con su etiqueta
  local salida="$OUTPUT/build-mto-$1.log"
  mkdir -p "$OUTPUT"
  if ! docker build --progress plain --tag "$2" "$HERMANOS/mto-$1" > "$salida" 2>&1; then
    abrir_grupo "Por que no se construye mto-$1: las ultimas lineas de docker build"
    tail -n 80 "$salida"
    cerrar_grupo
    echo "mto-$1: no se ha podido construir la imagen; la salida entera esta en $salida" >&2
    return 1
  fi
}

PUBLICADAS=()
for app in "${APPS[@]}"; do
  imagen="ghcr.io/$OWNER/mto-$app"
  # La etiqueta que pone docker/metadata-action (type=sha,format=short): los siete primeros.
  sha="$(git -C "$HERMANOS/mto-$app" rev-parse HEAD | cut -c1-7)"
  variable="MTO_$(tr '[:lower:]' '[:upper:]' <<< "$app")_TAG"
  if publicada "$OWNER/mto-$app" "sha-$sha"; then
    export "$variable=sha-$sha"
    PUBLICADAS+=("$app")
    echo "mto-$app: la imagen publicada $imagen:sha-$sha"
  else
    echo "mto-$app: sin imagen publicada para $sha; se construye desde el checkout"
    construir "$app" "$imagen:e2e"
    export "$variable=e2e"
  fi
done

docker compose --profile all pull --quiet "${INFRA[@]}" ${PUBLICADAS[@]+"${PUBLICADAS[@]}"}

# --- 3. La plataforma ---------------------------------------------------------------------------

docker compose up -d --wait --wait-timeout 300 "${INFRA[@]}"
./keycloak/apply-partials.sh
docker compose --profile all up -d

# Las aplicaciones no llevan healthcheck en compose: se pregunta a cada una donde la publica.
SONDAS=(
  "mto-configuration http://localhost:${MTO_CONFIGURATION_PORT:-8081}/actuator/health"
  "mto-stock http://localhost:${MTO_STOCK_PORT:-8080}/actuator/health"
  "mto-maintenance http://localhost:${MTO_MAINTENANCE_PORT:-8083}/actuator/health"
  "mto-users http://localhost:${MTO_USERS_PORT:-8084}/actuator/health"
  "mto-notification http://localhost:${MTO_NOTIFICATION_PORT:-8086}/actuator/health"
  "mto-field http://localhost:${MTO_FIELD_PORT:-8087}/actuator/health"
  "mto-gateway http://localhost:${MTO_GATEWAY_PORT:-8090}/actuator/health"
  "mto-backoffice http://localhost:${MTO_BACKOFFICE_PORT:-8085}/actuator/health"
  "mto-frontend http://localhost:${MTO_FRONTEND_PORT:-4200}/healthz"
)
limite=$((SECONDS + 360))
for sonda in "${SONDAS[@]}"; do
  nombre="${sonda%% *}"
  url="${sonda#* }"
  until curl -fsS -o /dev/null "$url"; do
    if (( SECONDS > limite )); then
      echo "$nombre no responde en $url despues de seis minutos" >&2
      exit 1
    fi
    sleep 5
  done
  echo "$nombre responde"
done

# --- 4. Las pruebas -----------------------------------------------------------------------------

cd "$HERMANOS/mto-frontend"
npm ci --no-audit --no-fund
if [[ -n "${CI:-}" ]]; then
  npx playwright install --with-deps chromium
else
  npx playwright install chromium
fi
CI="${CI:-true}" npx playwright test
