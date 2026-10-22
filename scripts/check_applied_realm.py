#!/usr/bin/env python3
"""Comprueba sobre un Keycloak de verdad que el realm 'mto' ensamblado conserva lo que declara cada parcial.

check_realm_consistency.py lee los ficheros; lo que Keycloak hace con ellos solo se ve aplicandolos.
Y hay cosas que solo se rompen al aplicarlos: una importacion parcial con OVERWRITE sustituye el
cliente entero por lo que trae el fichero, de modo que un fichero que reabre un cliente solo para
ponerle el secreto local podria dejarlo sin redirect URI, sin audience mappers o sin cuenta de
servicio, y ninguna comprobacion estatica lo veria.

Se ejecuta despues de keycloak/apply-partials.sh, contra el Keycloak del compose, y comprueba:

- que cada cliente declarado en el realm de partida o en una parcial esta en el realm con lo que el
  fichero dice de el: flags, URIs, atributos y protocol mappers;
- que cada secreto de un fichero de desarrollo es el que tiene el cliente;
- que las cuentas de servicio tienen los roles que apply-partials.sh les concede;
- que los eventos del realm quedan como los declara mto-realm.json (events/config y la caducidad de
  los de administracion), y el SMTP como el realm local: es lo que mto-notification lee.

En un entorno desplegado (OpenShift, deploy/), el realm se monta sin los ficheros de desarrollo y con
las URLs publicas de ese entorno. Para eso:

- --no-dev-users: el realm de partida es mto-realm.json (no el local), y no se comprueban ni los
  secretos de desarrollo ni el SMTP de Mailpit;
- --overrides FICHERO: lo que el entorno cambia de un cliente (rootUrl, redirectUris, webOrigins,
  atributos...), con la forma {"clients": {"<clientId>": {campo: valor}}}. Es el mismo fichero que lee
  deploy/keycloak/build_realm_import.py al montar el realm, asi que se comprueba lo que se aplico.

Solo libreria estandar, como check_realm_consistency.py.

Uso:
    python3 scripts/check_applied_realm.py [--repos DIR] [--no-dev-users] [--overrides FICHERO]

KC_URL y KC_REALM, y las credenciales KC_BOOTSTRAP_ADMIN_USERNAME / KC_BOOTSTRAP_ADMIN_PASSWORD,
se leen del entorno con los mismos valores por defecto que apply-partials.sh.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from check_realm_consistency import CLIENTES_API, Problemas, clientes_de, leer

# Los campos de un cliente que se comparan tal cual cuando la parcial los declara.
CAMPOS_SIMPLES = (
    "enabled",
    "protocol",
    "publicClient",
    "bearerOnly",
    "standardFlowEnabled",
    "implicitFlowEnabled",
    "directAccessGrantsEnabled",
    "serviceAccountsEnabled",
    "rootUrl",
    "baseUrl",
)

# Las listas, que se comparan como conjuntos: Keycloak no garantiza el orden.
CAMPOS_LISTA = ("redirectUris", "webOrigins")

# Los roles que apply-partials.sh concede a cada cuenta de servicio: (cliente, cliente del API, roles).
# El mismo reparto que las llamadas a conceder_roles_de_servicio. Si cambia alli, cambia aqui. Tambien
# lo lee deploy/keycloak/build_realm_import.py, que los concede en un entorno desplegado.
ROLES_DE_SERVICIO = [
    ("mto-maintenance-svc", "mto-stock-api", {"stock-read", "stock-write"}),
    ("mto-field-svc", "mto-maintenance-api", {"maintenance-read", "maintenance-write"}),
    (
        "mto-users-svc",
        "realm-management",
        {"view-users", "query-users", "manage-users", "view-clients", "query-clients", "view-realm"},
    ),
    (
        "mto-notification-svc",
        "realm-management",
        {"view-events", "view-users", "query-users", "view-clients", "query-clients", "view-realm"},
    ),
    ("mto-resources-svc", "realm-management", {"view-users", "query-users", "view-realm"}),
    ("mto-telematics-svc", "mto-resources-api", {"resources-telematics-write"}),
    # Prometheus raspa /actuator/prometheus de cada servicio con esta cuenta: solo ops-metrics, en los ocho.
    *[("mto-metrics-svc", api, {"ops-metrics"}) for api in CLIENTES_API],
]

# Lo que apply-partials.sh manda a events/config, tal cual lo declara mto-realm.json.
CAMPOS_DE_EVENTOS = (
    "eventsEnabled",
    "eventsExpiration",
    "eventsListeners",
    "enabledEventTypes",
    "adminEventsEnabled",
    "adminEventsDetailsEnabled",
)


def ficheros(raiz):
    """Las parciales y los ficheros de desarrollo, en el orden de apply-partials.sh."""
    plataforma = raiz / "mto-platform" / "keycloak"
    parciales = [
        raiz / "mto-notification" / "keycloak" / "mto-notification-partial-import.json",
        raiz / "mto-configuration" / "keycloak" / "mto-configuration-partial-import.json",
        raiz / "mto-stock" / "keycloak" / "mto-stock-partial-import.json",
        raiz / "mto-gateway" / "keycloak" / "mto-gateway-partial-import.json",
        raiz / "mto-resources" / "keycloak" / "mto-resources-partial-import.json",
        raiz / "mto-maintenance" / "keycloak" / "mto-maintenance-partial-import.json",
        raiz / "mto-users" / "keycloak" / "mto-users-partial-import.json",
        raiz / "mto-field" / "keycloak" / "mto-field-partial-import.json",
        raiz / "mto-backoffice" / "keycloak" / "mto-backoffice-partial-import.json",
        plataforma / "mto-ops-cross-service.json",
        plataforma / "mto-positions-cross-service.json",
        plataforma / "mto-metrics-cross-service.json",
    ]
    desarrollo = [
        raiz / "mto-notification" / "keycloak" / "mto-notification-dev.json",
        raiz / "mto-configuration" / "keycloak" / "mto-configuration-dev.json",
        raiz / "mto-stock" / "keycloak" / "mto-stock-dev.json",
        raiz / "mto-maintenance" / "keycloak" / "mto-maintenance-dev.json",
        raiz / "mto-users" / "keycloak" / "mto-users-dev.json",
        raiz / "mto-field" / "keycloak" / "mto-field-dev.json",
        raiz / "mto-resources" / "keycloak" / "mto-resources-dev.json",
        raiz / "mto-backoffice" / "keycloak" / "mto-backoffice-dev.json",
    ]
    return parciales, desarrollo


class Keycloak:
    """Lo justo de la Admin API: un token de administrador y GET con el."""

    def __init__(self, url, realm, usuario, contrasena):
        self.url = url.rstrip("/")
        self.realm = realm
        cuerpo = urllib.parse.urlencode(
            {"grant_type": "password", "client_id": "admin-cli", "username": usuario, "password": contrasena}
        ).encode()
        respuesta = self._pedir(f"{self.url}/realms/master/protocol/openid-connect/token", cuerpo)
        self.token = respuesta["access_token"]

    def _pedir(self, url, cuerpo=None, token=None):
        peticion = urllib.request.Request(url, data=cuerpo)
        if token:
            peticion.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(peticion, timeout=30) as respuesta:
                return json.load(respuesta)
        except urllib.error.HTTPError as error:
            raise SystemExit(f"{url} respondio {error.code}: {error.read().decode(errors='replace')}") from error

    def get(self, ruta):
        return self._pedir(f"{self.url}/admin/realms/{self.realm}{ruta}", token=self.token)

    def cliente(self, client_id):
        encontrados = self.get(f"/clients?clientId={urllib.parse.quote(client_id)}")
        return encontrados[0] if encontrados else None


def diferencias(declarado, real):
    """Lo que la parcial declara de un cliente y el realm no tiene tal cual, en lineas legibles."""
    lineas = []
    for campo in CAMPOS_SIMPLES:
        if campo in declarado and real.get(campo) != declarado[campo]:
            lineas.append(f"{campo}: la parcial dice {declarado[campo]!r} y el realm tiene {real.get(campo)!r}")
    for campo in CAMPOS_LISTA:
        if campo in declarado and set(real.get(campo) or []) != set(declarado[campo]):
            lineas.append(f"{campo}: la parcial dice {sorted(declarado[campo])} y el realm tiene {sorted(real.get(campo) or [])}")
    atributos = real.get("attributes") or {}
    for clave, valor in (declarado.get("attributes") or {}).items():
        if atributos.get(clave) != valor:
            lineas.append(f"attributes.{clave}: la parcial dice {valor!r} y el realm tiene {atributos.get(clave)!r}")
    mappers = {m.get("name"): m for m in real.get("protocolMappers") or []}
    for mapper in declarado.get("protocolMappers") or []:
        nombre = mapper.get("name")
        encontrado = mappers.get(nombre)
        if encontrado is None:
            lineas.append(f"protocolMappers: falta '{nombre}'")
            continue
        if encontrado.get("protocolMapper") != mapper.get("protocolMapper"):
            lineas.append(f"protocolMappers.{nombre}: es {encontrado.get('protocolMapper')} y no {mapper.get('protocolMapper')}")
        configuracion = encontrado.get("config") or {}
        for clave, valor in (mapper.get("config") or {}).items():
            if configuracion.get(clave) != valor:
                lineas.append(f"protocolMappers.{nombre}.{clave}: la parcial dice {valor!r} y el realm tiene {configuracion.get(clave)!r}")
    return lineas


def con_overrides(cliente, overrides):
    """El cliente tal como queda en el entorno: lo que cambia el entorno sobre lo que dice su fichero.

    Los atributos se mezclan clave a clave (el entorno cambia uno, no todos); cualquier otro campo se
    sustituye entero. Sin nada para ese cliente, el cliente tal cual.
    """
    cambios = (overrides.get("clients") or {}).get(cliente.get("clientId")) or {}
    if not cambios:
        return cliente
    resultado = {**cliente, **{k: v for k, v in cambios.items() if k != "attributes"}}
    if "attributes" in cambios:
        resultado["attributes"] = {**(cliente.get("attributes") or {}), **cambios["attributes"]}
    return resultado


def los_clientes_conservan_lo_que_declaran(keycloak, realm_de_partida, parciales, overrides, problemas):
    declarados = {}
    for client_id, cliente in clientes_de(realm_de_partida[1]).items():
        declarados[client_id] = (realm_de_partida[0], con_overrides(cliente, overrides))
    for ruta in parciales:
        for client_id, cliente in clientes_de(leer(ruta)).items():
            declarados.setdefault(client_id, (ruta.name, con_overrides(cliente, overrides)))
    for client_id, (fichero, declarado) in declarados.items():
        real = keycloak.cliente(client_id)
        if real is None:
            problemas.error("un cliente declarado no esta en el realm", f"  '{client_id}' ({fichero}) no existe.")
            continue
        lineas = diferencias(declarado, real)
        if lineas:
            problemas.error(
                f"'{client_id}' no conserva lo que declara {fichero}",
                "\n".join(f"  {linea}" for linea in lineas),
            )
    return len(declarados)


def los_secretos_son_los_de_desarrollo(keycloak, desarrollo, problemas):
    comprobados = 0
    for ruta in desarrollo:
        for client_id, cliente in clientes_de(leer(ruta)).items():
            if "secret" not in cliente:
                continue
            real = keycloak.cliente(client_id)
            if real is None:
                problemas.error("un cliente con secreto local no esta en el realm", f"  '{client_id}' ({ruta.name}) no existe.")
                continue
            secreto = keycloak.get(f"/clients/{real['id']}/client-secret").get("value")
            comprobados += 1
            if secreto != cliente["secret"]:
                problemas.error(
                    f"'{client_id}' no tiene el secreto de {ruta.name}",
                    "  El servicio que lo usa en local no podra pedir su token.",
                )
    return comprobados


def las_cuentas_de_servicio_tienen_sus_roles(keycloak, problemas):
    for client_id, cliente_api, esperados in ROLES_DE_SERVICIO:
        cliente = keycloak.cliente(client_id)
        api = keycloak.cliente(cliente_api)
        if cliente is None or api is None:
            problemas.error("falta un cliente de las cuentas de servicio", f"  '{client_id}' o '{cliente_api}' no existe.")
            continue
        if not cliente.get("serviceAccountsEnabled"):
            problemas.error(f"'{client_id}' no tiene la cuenta de servicio activa", "  Sin ella no puede pedir su token.")
            continue
        usuario = keycloak.get(f"/clients/{cliente['id']}/service-account-user")
        asignados = {r["name"] for r in keycloak.get(f"/users/{usuario['id']}/role-mappings/clients/{api['id']}")}
        faltan = esperados - asignados
        if faltan:
            problemas.error(
                f"a la cuenta de servicio de '{client_id}' le faltan roles de '{cliente_api}'",
                f"  Faltan: {', '.join(sorted(faltan))}.",
            )


def los_eventos_del_realm_quedan_como_los_declara_el_base(keycloak, base, local, problemas):
    """Lo que mto-notification va a leer: events/config, la caducidad de los admin events y el SMTP.

    El --import-realm los aplica al crear el realm y apply-partials.sh los vuelve a aplicar por la
    API; si cualquiera de los dos caminos se dejara algo, el lector recibiria una lista vacia y
    nadie lo veria.
    """
    real = keycloak.get("/events/config")
    for campo in CAMPOS_DE_EVENTOS:
        esperado, tiene = base.get(campo), real.get(campo)
        if isinstance(esperado, list):
            esperado, tiene = set(esperado), set(tiene or [])
        if esperado != tiene:
            problemas.error(
                "los eventos del realm no quedan como los declara mto-realm.json",
                f"  events/config.{campo}: el fichero dice {base.get(campo)!r} y el realm tiene {real.get(campo)!r}.",
            )

    realm = keycloak.get("")
    atributos = realm.get("attributes") or {}
    for clave, valor in (base.get("attributes") or {}).items():
        if atributos.get(clave) != valor:
            problemas.error(
                "un atributo del realm no queda como lo declara mto-realm.json",
                f"  attributes.{clave}: el fichero dice {valor!r} y el realm tiene {atributos.get(clave)!r}.",
            )

    smtp = local.get("smtpServer") if local else None
    if smtp:
        real_smtp = realm.get("smtpServer") or {}
        # Keycloak enmascara la contrasena al leer; el realm local no declara ninguna.
        distintos = {clave: (valor, real_smtp.get(clave)) for clave, valor in smtp.items() if clave != "password" and real_smtp.get(clave) != valor}
        if distintos:
            problemas.error(
                "el SMTP del realm no es el de mto-realm-local.json",
                "\n".join(f"  smtpServer.{clave}: el fichero dice {v[0]!r} y el realm tiene {v[1]!r}" for clave, v in distintos.items())
                + "\n  Sin el, el correo de acciones de mto-users y los avisos de mto-notification no llegan a Mailpit.",
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--repos",
        type=Path,
        default=Path(__file__).resolve().parent.parent.parent,
        help="Directorio que contiene los diez repositorios como hermanos.",
    )
    parser.add_argument(
        "--no-dev-users",
        action="store_true",
        help="Realm desplegado: de partida mto-realm.json, sin ficheros de desarrollo ni SMTP de Mailpit.",
    )
    parser.add_argument(
        "--overrides",
        type=Path,
        help="JSON con lo que el entorno cambia de cada cliente: {\"clients\": {\"<clientId>\": {...}}}.",
    )
    args = parser.parse_args()

    raiz = args.repos.resolve()
    plataforma = raiz / "mto-platform" / "keycloak"
    base = leer(plataforma / "mto-realm.json")
    local = None if args.no_dev_users else leer(plataforma / "mto-realm-local.json")
    realm_de_partida = ("mto-realm.json", base) if args.no_dev_users else ("mto-realm-local.json", local)
    overrides = leer(args.overrides) if args.overrides else {}
    parciales, desarrollo = ficheros(raiz)
    if args.no_dev_users:
        desarrollo = []
    keycloak = Keycloak(
        os.environ.get("KC_URL", "http://localhost:8082"),
        os.environ.get("KC_REALM", "mto"),
        os.environ.get("KC_BOOTSTRAP_ADMIN_USERNAME", "admin"),
        os.environ.get("KC_BOOTSTRAP_ADMIN_PASSWORD", "admin"),
    )

    problemas = Problemas()
    clientes = los_clientes_conservan_lo_que_declaran(keycloak, realm_de_partida, parciales, overrides, problemas)
    secretos = los_secretos_son_los_de_desarrollo(keycloak, desarrollo, problemas)
    las_cuentas_de_servicio_tienen_sus_roles(keycloak, problemas)
    los_eventos_del_realm_quedan_como_los_declara_el_base(keycloak, base, local, problemas)

    codigo = problemas.informe()
    if codigo == 0:
        print(f"Realm ensamblado correcto: {clientes} clientes, {secretos} secretos y los eventos comprobados en Keycloak.")
    return codigo


if __name__ == "__main__":
    sys.exit(main())
