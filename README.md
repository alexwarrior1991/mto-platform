# mto-platform

Entorno de **desarrollo local** del dominio MTO: una sola infraestructura compartida por
`mto-configuration`, `mto-stock`, `mto-maintenance`, `mto-users`, `mto-gateway` y
`mto-backoffice`, y el realm de Keycloak que los seis usan.

No es el mecanismo de despliegue de entornos reales.

## Por que existe

Cada repositorio traia su propio stack completo, y eso provocaba tres problemas que no daban error:

- **El realm no tenia dueño.** Estaba repartido en cinco ficheros de tres repositorios, y los dos
  `mto-realm-local.json` habian divergido hasta ser realms distintos con el mismo nombre. Cada uno
  se montaba con `--import-realm` en el Keycloak de su propio stack, asi que ganaba el que
  arrancases primero y el otro servicio se quedaba sin su cliente. `mto-gateway-api` no estaba en
  ninguno de los dos.
- **Cada repositorio levantaba su propio RabbitMQ.** `mto-configuration` publicaba los eventos de
  datos maestros en un broker y `mto-stock` escuchaba en otro. Los mensajes no llegaban y **nada
  fallaba**: ni un error, ni un aviso.
- **Los stacks chocaban de puertos** en 5432, 5672, 15672, 8082, 9000, 16686 y 4318.

Aqui hay un solo Postgres con las tres bases, un solo Redis, **un solo broker**, un solo Keycloak y
un solo colector de trazas.

## Requisitos

Docker y Docker Compose. Y una entrada en el fichero de hosts de tu maquina, porque el `iss` de los
tokens es esa URL y tiene que resolverse igual desde dentro de compose y desde el IDE:

```
127.0.0.1  auth.mto.local  otel.mto.local
```

Los siete repositorios tienen que estar como hermanos en el mismo directorio: el script de
ensamblado del realm lee la importacion parcial de cada servicio desde su propio repositorio.

```
mto/
├── mto-platform/
├── mto-configuration/
├── mto-stock/
├── mto-maintenance/
├── mto-users/
├── mto-gateway/
└── mto-backoffice/
```

## Arrancar

```bash
cp .env.example .env    # editese si hace falta
docker compose --profile all up -d
./keycloak/apply-partials.sh
```

La infraestructura no tiene perfil, asi que arranca siempre. Cada aplicacion lleva el suyo:

```bash
docker compose --profile all up -d                              # todo
docker compose up -d                                            # solo infraestructura
docker compose --profile stock up -d                            # infraestructura + mto-stock
docker compose --profile stock --profile maintenance up -d      # mto-maintenance y el stock al que llama
docker compose --profile configuration --profile gateway up -d  # dos de cinco
docker compose --profile users --profile gateway up -d          # administracion de usuarios detras del gateway
docker compose --profile backoffice --profile gateway up -d     # la web y el gateway al que llama
```

`mto-users` no tiene base de datos ni broker: administra usuarios, roles y perfiles del realm por
la Admin API de Keycloak con su cuenta de servicio `mto-users-svc`, cuyos roles de
`realm-management` concede `apply-partials.sh` (paso 8).

`mto-backoffice` (la aplicacion web, Vaadin) tiene el perfil `backoffice` y necesita el gateway
(`--profile backoffice --profile gateway`, o `all`). Su servicio lleva `build` ademas de `image`:
hasta que la imagen exista en GHCR —la publica su CI al fusionar en `master`— compose la
construye desde el checkout hermano `../mto-backoffice`, asi que `--profile all` funciona igual;
cuando exista, `docker compose pull backoffice` la trae. En desarrollo lo habitual sigue siendo
arrancarlo desde su repositorio (`./mvnw spring-boot:run`, puerto 8085) contra esta
infraestructura. Entra por `http://localhost:8085` con `config.responsable` / `local`.

`mto-maintenance` llama a `mto-stock` para reservar y consumir material: sin el, arranca igual,
pero cada reserva queda en `FAILED` hasta reintentarla. Sus activos (perfiles, seccionadores,
aisladores de seccion) llegan por los eventos de `mto-configuration`, asi que para verlos hace
falta que ese servicio haya publicado algo.

### Trabajar sobre un servicio

Levanta todo, para el que vayas a tocar y arrancalo desde el IDE contra esta misma
infraestructura:

```bash
docker compose --profile all up -d
docker compose stop stock
```

Funciona porque Keycloak y el colector se alcanzan **por el host con un nombre estable**
(`auth.mto.local`, `otel.mto.local`) y no por el nombre del servicio de compose: la URL es la misma
dentro y fuera. Postgres, Redis y RabbitMQ estan publicados en el host, asi que desde el IDE se
llega a ellos por `localhost`.

Si ademas quieres que el gateway enrute al servicio que corre en tu IDE:

```bash
# en .env
MTO_STOCK_URL=http://host.docker.internal:8080
```

## Puertos

| | |
|---|---|
| `mto-stock` | 8080 |
| `mto-configuration` | 8081 |
| `mto-maintenance` | 8083 |
| `mto-users` | 8084 |
| `mto-backoffice` | 8085 |
| `mto-gateway` | 8090 |
| Keycloak | 8082 (management 9000) |
| Jaeger | 16686 (OTLP HTTP 4318, gRPC 4317) |
| PostgreSQL | 5432 |
| Redis | 6379 |
| RabbitMQ | 5672 (consola 15672) |

Todos son parametrizables desde `.env`.

El gateway enruta `/api/configuration/**` a `/api/v1/configuration/**`, `/api/stock/**` a
`/api/v1/inventory/**`, `/api/maintenance/**` a `/api/v1/maintenance/**` y `/api/users/**` a
`/api/v1/users/**`.

## Las imagenes

Se descargan de GHCR, publicadas por el CI de cada repositorio al entrar en `master`. Si el
paquete no es publico hace falta autenticarse una vez:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u TU_USUARIO --password-stdin
```

Para probar un cambio sin publicar, construye la imagen en el repositorio del servicio y pon su
etiqueta en `MTO_<SERVICIO>_TAG`.

## El realm

Esta es la parte que antes no tenia dueño. Ahora se ensambla en un orden fijo:

| paso | fichero | repositorio | que aporta |
|---|---|---|---|
| 1 | `keycloak/mto-realm-local.json` | platform | crea el realm: ajustes, `mto-frontend` y el perfil de usuario |
| 2 | `mto-configuration-partial-import.json` | configuration | `mto-configuration-api`, `mto-configuration-svc`, sus permisos y sus perfiles |
| 3 | `mto-stock-partial-import.json` | stock | `mto-stock-api`, sus permisos y los perfiles `mto-warehouse-*` |
| 4 | `mto-gateway-partial-import.json` | gateway | `mto-gateway-api` y sus roles de operacion |
| 5 | `mto-maintenance-partial-import.json` | maintenance | `mto-maintenance-api`, `mto-maintenance-svc`, sus permisos y los perfiles `mto-maintenance-*` |
| 5b | `mto-users-partial-import.json` | users | `mto-users-api`, `mto-users-svc`, sus permisos y los perfiles `mto-users-*` |
| 5c | `mto-backoffice-partial-import.json` | backoffice | `mto-backoffice`, el cliente de login del backoffice web (confidencial, Authorization Code) con los audience mapper hacia los cinco API; no declara roles |
| 6 | `keycloak/mto-ops-cross-service.json` | platform | `mto-ops`, que agrupa el Actuator de **los cinco** |
| 7 | `mto-configuration-dev.json` / `mto-stock-dev.json` / `mto-maintenance-dev.json` / `mto-users-dev.json` / `mto-backoffice-dev.json` | cada servicio | usuarios de desarrollo (por `partialImport`) y secretos locales de las cuentas de servicio y del cliente `mto-backoffice` (por la API de administracion, sobre el cliente ya importado) |
| 8 | *(API de administracion)* | platform | `stock-read` y `stock-write` para la cuenta de servicio `mto-maintenance-svc`; `view-users`, `query-users`, `manage-users`, `view-clients`, `query-clients` y `view-realm` de `realm-management` para `mto-users-svc` |

El paso 1 lo hace el contenedor al arrancar (`--import-realm`); del 2 al 8, `apply-partials.sh`.

Los secretos del paso 7 no se importan con el resto del fichero, y el motivo cuesta caro si no se
sabe: **una importacion parcial con `OVERWRITE` sustituye el cliente ENTERO** por lo que trae el
fichero, y los ficheros de desarrollo reabren cada cliente confidencial solo con `{clientId, secret}`.
Medido sobre Keycloak 26.1.5 con un realm recien creado, al aplicarlos tal cual:

- `mto-backoffice` se quedaba sin redirect URI, sin post-logout y sin sus cinco audience mapper, asi
  que el login del backoffice no podia funcionar;
- las tres cuentas de servicio perdian su audiencia hacia `mto-stock-api` y la cuenta de servicio, y
  ganaban el flujo de navegador.

Antes se creia que `partialImport` no aplicaba `serviceAccountsEnabled`, y el guion lo reponia con un
paso propio (el antiguo 7b). Si lo aplica: lo que lo borraba era el fichero de desarrollo. Ahora de
esos ficheros se importa todo menos los clientes que solo traen el secreto, y el secreto se pone sobre
el cliente ya importado (se lee entero y se devuelve con el secreto). `scripts/check_applied_realm.py`
lo comprueba en el CI contra un Keycloak de verdad (abajo).

El 8 existe porque una importacion parcial no asigna roles a la cuenta de servicio de un cliente,
y la parcial de un servicio tampoco deberia decidir por si sola que puede tocar en el almacen de
otro —ni, en el caso de `mto-users`, que puede administrar del realm—; en un entorno desplegado se
hace en la consola (Clients → `mto-maintenance-svc` / `mto-users-svc` → Service accounts roles).
`mto-users-svc` lleva solo esos seis roles de `realm-management`: ni `manage-realm`, ni
`manage-clients`, ni `realm-admin`, y nunca una credencial del realm `master`.

**El orden no es un detalle.** Un compuesto solo puede nombrar roles de clientes que ya existan en
el realm: `mto-ops-cross-service.json` nombra los cinco, asi que va detras de las parciales que los
crean. Al reves Keycloak responde *App doesn't exist in role definitions* y no aplica nada.

El realm base trae ademas el **perfil de usuario declarativo** con
`unmanagedAttributePolicy: ADMIN_EDIT`. Sin el, Keycloak 26 descarta en silencio los `attributes`
que `mto-users` manda al crear o modificar un usuario: la llamada responde 200 y el atributo no
existe. Se declara con los cuatro atributos del perfil por defecto (`username`, `email`,
`firstName`, `lastName`) mas la politica; una configuracion que solo lleve la politica deja el
perfil sin atributos y se pierden `firstName` y `lastName`.

Cada servicio sigue siendo dueño de sus clientes, roles y perfiles, en su propio repositorio: asi
un rol se cambia en el mismo commit que el codigo que lo comprueba (`SecurityRoles`). La plataforma
es dueña del realm base, del perfil que cruza servicios y del orden.

Los usuarios de desarrollo van en un fichero aparte del de clientes y roles para que la parcial se
pueda aplicar en un entorno desplegado sin arrastrarlos:

```bash
./keycloak/apply-partials.sh --no-dev-users
```

### Usuarios de desarrollo

Los crea el paso 7. La contraseña de todos es `local`.

| usuario | perfil |
|---|---|
| `config.lector` / `.editor` / `.responsable` / `.auditor` / `.ops` | `mto-viewer` / `mto-editor` / `mto-admin` / `mto-auditor` / `mto-ops` |
| `almacen.lector` / `.operario` / `.responsable` | `mto-warehouse-viewer` / `mto-warehouse-operator` / `mto-warehouse-admin` |
| `mantenimiento.lector` / `.tecnico` / `.responsable` | `mto-maintenance-viewer` / `mto-maintenance-technician` / `mto-maintenance-manager` |
| `usuarios.lector` / `.gestor` / `.responsable` | `mto-users-viewer` / `mto-users-manager` / `mto-users-admin` |

### Pedir un token a mano

El realm esta pensado para Authorization Code con PKCE y un frontal en `localhost:4200`. En local
ese frontal no siempre esta levantado, y probar la API con `curl` o cargar un maestro necesita un
token. Por eso `mto-realm-local.json` —y **solo** ese— abre el *password grant* en `mto-frontend`:

```bash
curl -sS -X POST http://auth.mto.local:8082/realms/mto/protocol/openid-connect/token \
  -d grant_type=password -d client_id=mto-frontend \
  -d username=config.responsable -d password=local -o /tmp/tok.json
TOKEN=$(grep -o '"access_token":"[^"]*"' /tmp/tok.json | cut -d'"' -f4)
```

El token dura 5 minutos (`accessTokenLifespan`), así que un **401 con el cuerpo vacío** a mitad de
una carga larga casi siempre es eso y no un problema de permisos.

Dos cosas que conviene tener presentes:

- **En lo que se despliega se queda cerrado.** El *password grant* manda la contraseña del usuario
  al cliente, que es justo lo que Authorization Code existe para evitar. `mto-realm.json` lo tiene
  a `false` y `check_realm_consistency.py` falla si alguien lo abre ahí.
- **Extrae el token sin que se cuele un byte de control.** El `grep -o` corta en la comilla de
  cierre; un `print()` de Python en Windows añade un `\r` que sobrevive a `$(...)`, viaja dentro de
  la cabecera `Authorization` y se traduce en un **400 con el cuerpo vacío y nada en el log de
  Keycloak**, porque la petición no llega a su código. Es el mismo fallo que documenta
  `apply-partials.sh`, y el síntoma no se parece en nada a su causa.

## Comprobar que el realm sigue encajando

```bash
python3 scripts/check_realm_consistency.py
```

Sustituye a `RealmDefinitionsTest`, que vivia en `mto-configuration` y solo veia los ficheros de
ese repositorio. Sin dependencias: este repositorio no lleva Maven. Comprueba, recorriendo los
ficheros **en el orden en que se aplican**, que ningun compuesto nombre un cliente o un rol que
todavia no existe, que el realm base y el local no se separen, que el base no gane usuarios ni
secretos **ni abra el password grant**, que todo cliente de login (`mto-frontend` y `mto-backoffice`)
emita audiencia para los cinco API, que
ningun cliente se declare dos veces con contenido distinto, que ningun texto se pase del ancho de
su columna en Keycloak y que `mto-ops` cubra el Actuator de los cinco servicios.

Los clientes del realm base y el local se comparan **campo a campo**, no solo por su nombre: una
diferencia de flags entre los dos es precisamente lo que deja el stack local probando una
autorizacion distinta de la real. Las diferencias deliberadas se declaran en
`DELTAS_DE_CLIENTE_PERMITIDOS`, con el motivo al lado.

Lo ejecuta el CI de este repositorio, que hace checkout de los siete.

### Y que Keycloak se queda con lo que dicen

```bash
./keycloak/apply-partials.sh && python3 scripts/check_applied_realm.py
```

Leer los ficheros no basta: lo que Keycloak hace con ellos solo se ve aplicandolos, y el fallo de los
secretos de desarrollo (arriba) no lo veia ninguna comprobacion estatica. `check_applied_realm.py`
lee el realm ya ensamblado por la API de administracion y exige a cada cliente lo que declara su
parcial (flags, URIs, atributos y audience mapper), a cada secreto de desarrollo que sea el que tiene
su cliente y a cada cuenta de servicio los roles que le concede el guion. El CI lo ejecuta tras
levantar el Keycloak del compose y aplicar las parciales, en el mismo job.

## Parar

```bash
docker compose --profile all down      # conserva los datos
docker compose --profile all down -v   # borra volumenes; el init de Postgres vuelve a aplicarse
```

Los usuarios y las bases los crea `postgres/init/01-databases.sql`, que PostgreSQL ejecuta **solo**
en la primera inicializacion del volumen. Cambiar un nombre o una credencial de base en `.env`
exige `down -v`.
