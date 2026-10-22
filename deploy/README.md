# Desplegar MTO en OpenShift

Un entorno (`staging` o `prod`) en OpenShift, con varias replicas de cada servicio. Dos piezas:

- **Ansible** (`ansible/`) prepara el cluster y el proyecto una vez y cada vez que cambia un secreto: los
  operadores, el proyecto con su cuota, los secretos del vault y la Application raiz de Argo CD.
- **Argo CD** (OpenShift GitOps, `gitops/`) despliega todo lo demas desde Git y lo mantiene igual que Git: la
  infraestructura, el realm y los servicios.

```
deploy/
├── ansible/                       el playbook (site.yml), sus roles y un inventario por entorno
├── gitops/
│   ├── apps/                      la App of Apps: una Application por pieza, en ondas
│   ├── charts/mto-service/        el chart de cada servicio (Deployment, Service, Route, HPA, PDB, ServiceMonitor)
│   ├── charts/mto-infra/          PostgreSQL (CloudNativePG), RabbitMQ, Redis y Keycloak (RHBK)
│   ├── charts/mto-realm/          el realm: un Job con keycloak-config-cli y otro que lo comprueba
│   ├── values/{base,staging,prod} los values de cada Application
│   ├── schemas/                   el esquema de la Route para kubeconform
│   └── scripts/render.sh          renderiza un entorno como Argo CD
└── keycloak/                      build_realm_import.py y un ejemplo de overrides
```

## Requisitos

- OpenShift 4.16 o posterior, con los catalogos `redhat-operators` y `community-operators`.
- Un StorageClass `ReadWriteMany` para el PVC de `mto-configuration` (CephFS de ODF, por ejemplo) y uno por
  defecto `ReadWriteOnce` para PostgreSQL y RabbitMQ.
- Salida a `ghcr.io` (las imagenes), `docker.io` (keycloak-config-cli), `registry.redhat.io` y
  `registry.access.redhat.com` (Redis, Python del Job del realm) y `github.com` (el Job del realm clona los
  repositorios).
- En la maquina que ejecuta Ansible: Python 3.11+, `pip install -r ansible/requirements.txt` y
  `ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections`.

## Paso a paso

```bash
cd deploy/ansible
cp vault.example.yml inventories/staging/group_vars/all/vault.yml   # rellenar
ansible-vault encrypt inventories/staging/group_vars/all/vault.yml
# revisar inventories/staging/group_vars/all/main.yml: la API, el dominio, la cuota...
# y deploy/gitops/values/staging/common.yaml: las URLs publicas, el correo
ansible-playbook -i inventories/staging site.yml --ask-vault-pass
```

A partir de ahi Argo CD sincroniza solo. Las etiquetas del playbook (`operators`, `projects`, `secrets`,
`argocd`) ejecutan una parte: cambiar un secreto es `--tags secrets`.

Produccion es lo mismo con `inventories/prod` y `values/prod`, en su cluster (o en el mismo, en otro
proyecto: los nombres de host lo dicen).

## Lo que hace Ansible

| role | que hace |
|---|---|
| `openshift_auth` | pide un token de la API con el usuario del vault (`redhat.openshift.openshift_auth`) y lo revoca al terminar, falle lo que falle |
| `operators` | OpenShift GitOps, CloudNativePG, RabbitMQ Cluster Operator, cert-manager y ODF (solo la suscripcion: el `StorageCluster` es del cluster; `operators_odf_enabled: false` si ya hay RWX). Espera a que cada CSV este `Succeeded` |
| `projects` | el proyecto (`argocd.argoproj.io/managed-by: openshift-gitops`), su `ResourceQuota` y su `LimitRange`, un `ClusterRole` con los recursos de los operadores que el controlador de Argo CD necesita y su `RoleBinding` en el proyecto, el pull secret de `ghcr.io` (si el vault trae token) anadido a la cuenta `default`, la monitorizacion de proyectos de usuario (`enableUserWorkload`, conservando el resto de `cluster-monitoring-config`) y RHBK, que solo se instala por namespace |
| `secrets` | los Secret del vault, con `no_log` (abajo) |
| `argocd` | la comprobacion de salud de `Application` en la instancia de Argo CD (sin ella las ondas no esperan) y la Application raiz `mto-<entorno>` |

## Lo que despliega Argo CD

La Application raiz renderiza `gitops/apps` con `values-<entorno>.yaml`, y Ansible le pasa el repositorio y la
revision del inventario (`argocd_repo_url`, `argocd_target_revision`): la raiz y sus hijas siguen la misma, y
promover un entorno es cambiar la de su inventario. Cada hija espera a que la onda anterior este sana:

| onda | Application | por que ahi |
|---|---|---|
| 0 | `infra` | PostgreSQL con una base y un rol por servicio (y la de Keycloak), RabbitMQ de tres nodos, Redis y Keycloak |
| 1 | `realm` | el realm, cuando Keycloak responde |
| 2 | `notification`, `configuration`, `stock`, `users` | no dependen de otro servicio para arrancar |
| 3 | `maintenance` | su cola de `mto.resources.exchange` tiene que existir antes de que `mto-resources` publique (`mandatory=true`) |
| 4 | `resources` | la cola de las posiciones de `mto-field` es suya |
| 5 | `field` | |
| 6 | `gateway` | con los servicios ya arriba |
| 7 | `backoffice`, `frontend` | |

Los values de cada Application se leen en capas, del general al particular, y uno que no existe se salta:
`values/base/<fichero>` (lo que no cambia de un entorno a otro: variables, secretos que lee, puertos), luego
`values/<entorno>/common.yaml` (las URLs publicas en `global`, la etiqueta de las imagenes, el HPA) y luego
`values/<entorno>/<fichero>`. Las variables de entorno son un mapa, asi que las capas se mezclan, y cada valor
pasa por `tpl`: `"{{ .Values.global.keycloakUrl }}/realms/mto"`. Una variable que queda vacia no se pone.
`gitops/scripts/render.sh <entorno> <dir>` hace lo mismo que Argo CD, sin cluster.

## Los secretos

Nada secreto esta en Git: los charts nombran un Secret y una clave, y Ansible los crea desde el vault del
entorno (`ansible/vault.example.yml` dice que lleva; el real se cifra con `ansible-vault` y esta en
`.gitignore`).

| Secret | claves | lo leen |
|---|---|---|
| `mto-db-<servicio>` (configuration, stock, maintenance, notification, field, resources, keycloak) | `username`, `password` (basic-auth) | CloudNativePG (el rol de la base) y el servicio |
| `mto-rabbitmq-default-user` | `username`, `password` | lo genera el operador de RabbitMQ; los servicios |
| `mto-redis` | `password` | Redis, `mto-configuration` y `mto-stock` |
| `mto-messaging` | `signature-secret` | todos los que publican o consumen (la misma firma para todos) |
| `mto-keycloak-admin` | `username`, `password` | Keycloak (administrador de arranque) y los Jobs del realm |
| `mto-keycloak-client-secrets` | `KC_CLIENT_SECRET_<CLIENTID>` (los nueve clientes confidenciales) y `KC_SMTP_PASSWORD` | el Job del realm (los pone en Keycloak) y cada servicio el suyo |
| `mto-smtp` | `username`, `password` | `mto-notification` |
| `ghcr-pull`, `mto-git` | | la cuenta `default` del proyecto y el Job del realm, si los repositorios o las imagenes son privados |

Una contrasena de PostgreSQL cambiada la vuelve a poner CloudNativePG (etiqueta `cnpg.io/reload`); el
servicio la lee al reiniciarse. Un secreto de cliente cambiado lo pone el Job del realm en la siguiente
sincronizacion de `realm`.

## El realm

Lo aplica el chart `mto-realm` en cada sincronizacion, con los mismos ficheros y en el mismo orden que
`keycloak/apply-partials.sh` en local, **sin ningun `-dev.json`**: ni usuarios con contrasena `local` ni
secretos fijos.

1. Un initContainer clona los repositorios hermanos (`git.revision`, la misma para todos) y otro ejecuta
   `deploy/keycloak/build_realm_import.py`: `mto-realm.json` (el base), encima las doce parciales con la
   semantica del `partialImport` con `OVERWRITE`, lo que el entorno cambia (`overrides`, en
   `values/base/realm.yaml`: las URLs de `mto-frontend` y `mto-backoffice` y el SMTP), los secretos de los
   clientes y, como usuarios `service-account-*`, los roles de cada cuenta de servicio
   (`ROLES_DE_SERVICIO` de `scripts/check_applied_realm.py`, los mismos que concede `apply-partials.sh`).
2. keycloak-config-cli lo aplica con `IMPORT_MANAGED_*=no-delete`: crea y actualiza, nunca borra (lo creado a
   mano en el realm se queda, como con `apply-partials.sh`).
3. Otro Job, al final de la sincronizacion, ejecuta `check_applied_realm.py --no-dev-users --overrides`: si el
   realm no es lo que declaran los ficheros, la sincronizacion de `realm` falla y las ondas siguientes esperan.

Argo CD solo sincroniza cuando lo renderizado cambia, y el chart no cambia porque cambie una parcial en
otro repositorio: el realm se vuelve a aplicar al cambiar `git.revision` o los `overrides`, o con un Sync de
`mto-<entorno>-realm` a mano. En produccion, `git.revision` fijada a una etiqueta comun a los repositorios
hace que el realm cambie solo cuando se promueve.

`mto-metrics-svc` (`keycloak/mto-metrics-cross-service.json`) es la cuenta con la que Prometheus raspa
`/actuator/prometheus`: `ops-metrics` de los ocho API y sus ocho audiencias.

## Varias replicas

Lo que cada servicio necesita para correr con mas de una, y donde esta:

- **Colas quorum.** `APP_RABBITMQ_QUEUES_TYPE=quorum` y `x-delivery-limit` 5 (`values/base/rabbitmq.yaml`)
  en las colas de `mto-stock`, `mto-maintenance`, `mto-notification` y `mto-resources`, sobre un RabbitMQ
  de tres nodos. En local siguen clasicas. La firma de los mensajes es `REQUIRED`: todos firman con el mismo
  secreto.
- **`mto-configuration`** escribe los ficheros de sus trabajos en un PVC `ReadWriteMany` en `/data`
  (`persistence`), que comparten las replicas (`README_ASYNC_JOBS.md` §10 de `mto-configuration`).
- **`mto-backoffice`** guarda la sesion de Vaadin en memoria de un pod, a proposito (sin Spring Session ni
  sesiones en Redis): su Route vuelve al mismo pod con la cookie `mto-backoffice`, TLS `edge` (el chart
  rechaza `passthrough` con cookie, porque el router no la veria), `haproxy.router.openshift.io/timeout` de
  una hora por `@Push`, y un PDB. Detras del router construye su redirect URI con
  `SERVER_FORWARDHEADERSSTRATEGY=native`.
- **`mto-field`** habla gRPC por su propia Route, `passthrough` (el gateway no hace de proxy gRPC y el router
  no habla HTTP/2 en claro con el pod), con el perfil `grpc-tls` y el certificado del serving cert de
  OpenShift (`mto-field-tls`, firmado por la CA del servicio y para `mto-field.<proyecto>.svc`: un cliente de
  fuera la nombra con `--authority` y confia en esa CA, como el simulador con `--tls --ca --authority`). Con
  un certificado del host publico, `certificate.enabled` de cert-manager y sin la anotacion del serving cert.
  `terminationGracePeriodSeconds: 75` y un timeout de la Route de una noche. Cada pod es una replica del bus
  (su id, el nombre del pod).
- **`mto-gateway`** confia en las cabeceras del router (`SERVER_FORWARD_HEADERS_STRATEGY=framework`) y llama a
  cada servicio por su Service. **`mto-frontend`** llega al gateway por el FQDN de su Service (el resolver de
  nginx no usa los dominios de busqueda).
- Ningun pod recibe las variables de enlace de los Services (`enableServiceLinks: false`): `MTO_STOCK_PORT`
  y las demas se leerian como propiedades.
- Las conexiones a PostgreSQL: seis servicios con su pool de 10 y el HPA al maximo, mas Keycloak con 20 por
  instancia; `max_connections` de `mto-infra` lleva la cuenta.

## Metricas

Cada servicio Spring lleva un ServiceMonitor que pide un token a Keycloak con `mto-metrics-svc` (OAuth2
`client_credentials`, su secreto en `mto-keycloak-client-secrets`) y raspa `/actuator/prometheus` con el. Lo
lee la monitorizacion de proyectos de usuario de OpenShift, que el role `projects` activa. El backoffice y el
frontal no exponen Prometheus.

## Lo que no hace

- Copias de PostgreSQL: el `Cluster` de CloudNativePG no lleva `backup` (un `barmanObjectStore` hacia un
  almacen de objetos es lo siguiente).
- Trazas: sin colector, `global.tracing.enabled: false`; con uno (Red Hat build of OpenTelemetry), su URL en
  `global.tracing.endpoint`.
- El `StorageCluster` de ODF, el DNS y los certificados propios de las Routes: son del cluster. Cada host es
  un nivel bajo el dominio de aplicaciones (`mto-auth.<dominio>`), que cubre el comodin del router.

## Comprobar sin cluster

```bash
deploy/gitops/scripts/render.sh staging /tmp/render/staging
kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'deploy/gitops/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/render/staging/*.yaml
(cd deploy/ansible && ansible-playbook -i inventories/staging site.yml --syntax-check && ansible-lint site.yml roles)
```

Es lo que hace el job `deploy` del CI, con los dos entornos. El job `realm` prueba el camino del realm contra
un Keycloak limpio: `build_realm_import.py`, keycloak-config-cli dos veces y `check_applied_realm.py
--no-dev-users --overrides`.
