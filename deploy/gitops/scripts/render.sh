#!/usr/bin/env bash
# Renderiza un entorno como lo haria Argo CD: la App of Apps (apps/ con values-<entorno>.yaml) y, por cada
# Application que genera, su chart con sus ficheros de values en el mismo orden y saltando los que no
# existen (ignoreMissingValueFiles). Deja un fichero por Application en el directorio de salida, para
# kubeconform. Lo usa el job deploy del CI; en local hace falta helm.
#
#   deploy/gitops/scripts/render.sh staging /tmp/render-staging
set -euo pipefail

entorno=${1:?uso: render.sh <staging|prod> <directorio de salida>}
salida=${2:?uso: render.sh <staging|prod> <directorio de salida>}
gitops=$(cd "$(dirname "$0")/.." && pwd)
helm=${HELM:-helm}

mkdir -p "$salida"
"$helm" template "mto-$entorno" "$gitops/apps" -f "$gitops/apps/values-$entorno.yaml" > "$salida/00-apps.yaml"

# Cada Application en una linea: release|chart|namespace|values1,values2,...
awk '
  /^---/ { if (release != "") print release "|" path "|" ns "|" files; release = ""; path = ""; ns = ""; files = "" }
  /^ *releaseName:/ { release = $2 }
  /^ *path: deploy\/gitops\/charts\// { path = $2 }
  /^ *namespace:/ && in_destination { ns = $2 }
  /^ *destination:/ { in_destination = 1; next }
  /^ *[a-zA-Z]+:/ && !/^ *namespace:/ && !/^ *server:/ { in_destination = 0 }
  /^ *- \.\.\/\.\.\/values\// { files = files (files == "" ? "" : ",") $2 }
  END { if (release != "") print release "|" path "|" ns "|" files }
' "$salida/00-apps.yaml" | while IFS='|' read -r release path namespace files; do
  chart="$gitops/../../$path"
  argumentos=()
  IFS=',' read -ra ficheros <<< "$files"
  for fichero in "${ficheros[@]}"; do
    [ -f "$chart/$fichero" ] && argumentos+=(-f "$chart/$fichero")
  done
  echo "$release: $(( ${#argumentos[@]} / 2 )) ficheros de values"
  "$helm" template "$release" "$chart" --namespace "$namespace" "${argumentos[@]}" > "$salida/$release.yaml"
done
