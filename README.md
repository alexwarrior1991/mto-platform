# mto-platform

Entorno de **desarrollo local** del dominio MTO: una sola infraestructura compartida por
`mto-configuration`, `mto-stock` y `mto-gateway`, y el realm de Keycloak que los tres usan.

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

Aqui hay un solo Postgres con las dos bases, un solo Redis, **un solo broker**, un solo Keycloak y
un solo colector de trazas.

## Requisitos

Docker y Docker Compose. Y una entrada en el fichero de hosts de tu maquina, porque el `iss` de los
tokens es esa URL y tiene que resolverse igual desde dentro de compose y desde el IDE:

```
127.0.0.1  auth.mto.local  otel.mto.local
```

Los cuatro repositorios tienen que estar como hermanos en el mismo directorio: el script de
ensamblado del realm lee la importacion parcial de cada servicio desde su propio repositorio.

```
mto/
├── mto-platform/
├── mto-configuration/
├── mto-stock/
└── mto-gateway/
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
docker compose --profile configuration --profile gateway up -d  # dos de tres
```

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
| `mto-gateway` | 8090 |
| Keycloak | 8082 (management 9000) |
| Jaeger | 16686 (OTLP HTTP 4318, gRPC 4317) |
| PostgreSQL | 5432 |
| Redis | 6379 |
| RabbitMQ | 5672 (consola 15672) |

Todos son parametrizables desde `.env`.

El gateway enruta `/api/configuration/**` a `/api/v1/configuration/**` y `/api/stock/**` a
`/api/v1/inventory/**`.

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
| 1 | `keycloak/mto-realm-local.json` | platform | crea el realm: ajustes y `mto-frontend` |
| 2 | `mto-configuration-partial-import.json` | configuration | `mto-configuration-api`, `mto-configuration-svc`, sus permisos y sus perfiles |
| 3 | `mto-stock-partial-import.json` | stock | `mto-stock-api`, sus permisos y los perfiles `mto-warehouse-*` |
| 4 | `mto-gateway-partial-import.json` | gateway | `mto-gateway-api` y sus roles de operacion |
| 5 | `keycloak/mto-ops-cross-service.json` | platform | `mto-ops`, que agrupa el Actuator de **los tres** |
| 6 | `mto-configuration-dev.json` / `mto-stock-dev.json` | cada servicio | usuarios de desarrollo |

El paso 1 lo hace el contenedor al arrancar (`--import-realm`); del 2 al 6, `apply-partials.sh`.

**El orden no es un detalle.** Un compuesto solo puede nombrar roles de clientes que ya existan en
el realm: `mto-ops-cross-service.json` nombra los tres, asi que va detras de las parciales que los
crean. Al reves Keycloak responde *App doesn't exist in role definitions* y no aplica nada.

Cada servicio sigue siendo dueño de sus clientes, roles y perfiles, en su propio repositorio: asi
un rol se cambia en el mismo commit que el codigo que lo comprueba (`SecurityRoles`). La plataforma
es dueña del realm base, del perfil que cruza servicios y del orden.

Los usuarios de desarrollo van en un fichero aparte del de clientes y roles para que la parcial se
pueda aplicar en un entorno desplegado sin arrastrarlos:

```bash
./keycloak/apply-partials.sh --no-dev-users
```

### Usuarios de desarrollo

Los crea el paso 6. La contraseña de todos es `local`.

| usuario | perfil |
|---|---|
| `config.lector` / `.editor` / `.responsable` / `.auditor` / `.ops` | `mto-viewer` / `mto-editor` / `mto-admin` / `mto-auditor` / `mto-ops` |
| `almacen.lector` / `.operario` / `.responsable` | `mto-warehouse-viewer` / `mto-warehouse-operator` / `mto-warehouse-admin` |

## Comprobar que el realm sigue encajando

```bash
python3 scripts/check_realm_consistency.py
```

Sustituye a `RealmDefinitionsTest`, que vivia en `mto-configuration` y solo veia los ficheros de
ese repositorio. Sin dependencias: este repositorio no lleva Maven. Comprueba, recorriendo los
ficheros **en el orden en que se aplican**, que ningun compuesto nombre un cliente o un rol que
todavia no existe, que el realm base y el local no se separen, que el base no gane usuarios ni
secretos, que `mto-frontend` emita audiencia para los tres API, que ningun cliente se declare dos
veces con contenido distinto y que `mto-ops` cubra el Actuator de los tres servicios.

Lo ejecuta el CI de este repositorio, que hace checkout de los cuatro.

## Parar

```bash
docker compose --profile all down      # conserva los datos
docker compose --profile all down -v   # borra volumenes; el init de Postgres vuelve a aplicarse
```

Los usuarios y las bases los crea `postgres/init/01-databases.sql`, que PostgreSQL ejecuta **solo**
en la primera inicializacion del volumen. Cambiar un nombre o una credencial de base en `.env`
exige `down -v`.
