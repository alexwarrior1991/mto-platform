#!/usr/bin/env python3
"""Comprueba sobre un Keycloak de verdad que el realm 'mto' ensamblado conserva lo que declara cada parcial.

check_realm_consistency.py lee los ficheros; lo que Keycloak hace con ellos solo se ve aplicandolos.
Y hay cosas que solo se rompen al aplicarlos: una importacion parcial con OVERWRITE sustituye el
cliente entero por lo que trae el fichero, de modo que un fichero que reabre un cliente solo para
ponerle el secreto local podria dejarlo sin redirect URI, sin audience mappers o sin cuenta de
servicio, y ninguna comprobacion estatica lo veria.

Se ejecuta despues de keycloak/apply-partials.sh, contra el Keycloak del compose, y comprueba:

- que cada cliente declarado en una parcial esta en el realm con lo que la parcial dice de el:
  flags, URIs, atributos y protocol mappers;
- que cada secreto de un fichero de desarrollo es el que tiene el cliente;
- que las cuentas de servicio tienen los roles que apply-partials.sh les concede.

Solo libreria estandar, como check_realm_consistency.py.

Uso:
    python3 scripts/check_applied_realm.py [--repos DIR]

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

from check_realm_consistency import Problemas, clientes_de, leer

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

# Los roles que apply-partials.sh concede a cada cuenta de servicio: {cliente: (cliente del API, roles)}.
# El mismo reparto que las llamadas a conceder_roles_de_servicio. Si cambia alli, cambia aqui.
ROLES_DE_SERVICIO = {
    "mto-maintenance-svc": ("mto-stock-api", {"stock-read", "stock-write"}),
    "mto-users-svc": (
        "realm-management",
        {"view-users", "query-users", "manage-users", "view-clients", "query-clients", "view-realm"},
    ),
}


def ficheros(raiz):
    """Las parciales y los ficheros de desarrollo, en el orden de apply-partials.sh."""
    plataforma = raiz / "mto-platform" / "keycloak"
    parciales = [
        raiz / "mto-configuration" / "keycloak" / "mto-configuration-partial-import.json",
        raiz / "mto-stock" / "keycloak" / "mto-stock-partial-import.json",
        raiz / "mto-gateway" / "keycloak" / "mto-gateway-partial-import.json",
        raiz / "mto-maintenance" / "keycloak" / "mto-maintenance-partial-import.json",
        raiz / "mto-users" / "keycloak" / "mto-users-partial-import.json",
        raiz / "mto-backoffice" / "keycloak" / "mto-backoffice-partial-import.json",
        plataforma / "mto-ops-cross-service.json",
    ]
    desarrollo = [
        raiz / "mto-configuration" / "keycloak" / "mto-configuration-dev.json",
        raiz / "mto-stock" / "keycloak" / "mto-stock-dev.json",
        raiz / "mto-maintenance" / "keycloak" / "mto-maintenance-dev.json",
        raiz / "mto-users" / "keycloak" / "mto-users-dev.json",
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


def los_clientes_conservan_lo_que_declaran(keycloak, parciales, problemas):
    declarados = {}
    for ruta in parciales:
        for client_id, cliente in clientes_de(leer(ruta)).items():
            declarados.setdefault(client_id, (ruta.name, cliente))
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
    for client_id, (cliente_api, esperados) in ROLES_DE_SERVICIO.items():
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--repos",
        type=Path,
        default=Path(__file__).resolve().parent.parent.parent,
        help="Directorio que contiene los siete repositorios como hermanos.",
    )
    args = parser.parse_args()

    parciales, desarrollo = ficheros(args.repos.resolve())
    keycloak = Keycloak(
        os.environ.get("KC_URL", "http://localhost:8082"),
        os.environ.get("KC_REALM", "mto"),
        os.environ.get("KC_BOOTSTRAP_ADMIN_USERNAME", "admin"),
        os.environ.get("KC_BOOTSTRAP_ADMIN_PASSWORD", "admin"),
    )

    problemas = Problemas()
    clientes = los_clientes_conservan_lo_que_declaran(keycloak, parciales, problemas)
    secretos = los_secretos_son_los_de_desarrollo(keycloak, desarrollo, problemas)
    las_cuentas_de_servicio_tienen_sus_roles(keycloak, problemas)

    codigo = problemas.informe()
    if codigo == 0:
        print(f"Realm ensamblado correcto: {clientes} clientes y {secretos} secretos comprobados en Keycloak.")
    return codigo


if __name__ == "__main__":
    sys.exit(main())
