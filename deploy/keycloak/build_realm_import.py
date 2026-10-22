#!/usr/bin/env python3
"""Monta el realm 'mto' de un entorno desplegado en un solo fichero, para keycloak-config-cli.

En local el realm lo ensamblan el --import-realm del contenedor y keycloak/apply-partials.sh, parcial a
parcial y con los ficheros de desarrollo. En OpenShift (deploy/) lo aplica keycloak-config-cli desde un
Job, y este script le prepara lo que tiene que aplicar, a partir de LOS MISMOS ficheros:

- el realm de partida es mto-realm.json (el base: sin usuarios, sin secretos, sin password grant), con
  sus eventos y mto-frontend;
- encima, las parciales en el orden de apply-partials.sh (el mismo que lista check_applied_realm.py),
  con la semantica de su partialImport con OVERWRITE: un cliente, un rol o un grupo que reaparece en
  una parcial posterior sustituye entero al anterior;
- ningun fichero de desarrollo: ni usuarios con contrasena 'local' ni secretos fijos;
- lo que cambia el entorno (--overrides, el mismo fichero que lee check_applied_realm.py): las URLs de
  los clientes de login y, si hace falta, ajustes del realm como el SMTP;
- el secreto de cada cliente confidencial con flujo (una cuenta de servicio o un login con secreto),
  leido de la variable KC_CLIENT_SECRET_<CLIENTID> (mto-maintenance-svc -> KC_CLIENT_SECRET_MTO_MAINTENANCE_SVC),
  que en OpenShift sale del Secret que crea Ansible desde el vault. Falta uno y el script falla: un
  secreto generado por Keycloak no lo conoceria el servicio que lo usa;
- los roles de las cuentas de servicio que apply-partials.sh concede por la API, como usuarios
  service-account-<cliente> con sus clientRoles, sacados de ROLES_DE_SERVICIO de check_applied_realm.py.

Solo libreria estandar, como los scripts de comprobacion.

Uso:
    python3 deploy/keycloak/build_realm_import.py --repos DIR --overrides FICHERO --output realm-mto.json
"""

import argparse
import copy
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))

from check_applied_realm import ROLES_DE_SERVICIO, con_overrides, ficheros  # noqa: E402
from check_realm_consistency import leer  # noqa: E402

REALM = "mto"


def variable_del_secreto(client_id):
    return "KC_CLIENT_SECRET_" + re.sub(r"[^A-Za-z0-9]", "_", client_id).upper()


def por_clave(lista, clave):
    return {elemento[clave]: elemento for elemento in lista}


def mezclar(realm, parcial):
    """Aplica una parcial sobre el realm con la semantica de partialImport con OVERWRITE."""
    roles = parcial.get("roles") or {}
    destino = realm.setdefault("roles", {})
    if roles.get("realm"):
        actuales = por_clave(destino.get("realm", []), "name")
        actuales.update(por_clave(roles["realm"], "name"))
        destino["realm"] = list(actuales.values())
    for cliente, lista in (roles.get("client") or {}).items():
        actuales = por_clave(destino.setdefault("client", {}).get(cliente, []), "name")
        actuales.update(por_clave(lista, "name"))
        destino["client"][cliente] = list(actuales.values())
    for coleccion, clave in (("clients", "clientId"), ("groups", "name")):
        if parcial.get(coleccion):
            actuales = por_clave(realm.get(coleccion, []), clave)
            actuales.update(por_clave(parcial[coleccion], clave))
            realm[coleccion] = list(actuales.values())
    desconocidas = set(parcial) - {"roles", "clients", "groups"}
    if desconocidas:
        raise SystemExit(f"Una parcial trae {sorted(desconocidas)}, que este script no sabe aplicar como apply-partials.sh.")


def necesita_secreto(cliente):
    """Un cliente confidencial que pide token con su secreto: una cuenta de servicio o un login con secreto.

    Los *-api tambien son confidenciales, pero son resource servers sin ningun flujo: nadie pide un
    token con su secreto, asi que el que genere Keycloak da igual.
    """
    return not cliente.get("publicClient") and (
        cliente.get("serviceAccountsEnabled") or cliente.get("standardFlowEnabled")
    )


def poner_secretos(realm, entorno):
    faltan = []
    for cliente in realm.get("clients", []):
        if not necesita_secreto(cliente):
            continue
        variable = variable_del_secreto(cliente["clientId"])
        secreto = entorno.get(variable)
        if not secreto:
            faltan.append(variable)
            continue
        cliente["secret"] = secreto
    if faltan:
        raise SystemExit("Faltan los secretos de estos clientes (cada uno, una variable de entorno):\n  " + "\n  ".join(faltan))


def cuentas_de_servicio(realm):
    """Los roles que apply-partials.sh concede con conceder_roles_de_servicio, como usuarios del realm."""
    usuarios = {}
    for client_id, cliente_api, roles in ROLES_DE_SERVICIO:
        usuario = usuarios.setdefault(client_id, {
            "username": f"service-account-{client_id}",
            "enabled": True,
            "serviceAccountClientId": client_id,
            "clientRoles": {},
        })
        usuario["clientRoles"].setdefault(cliente_api, [])
        usuario["clientRoles"][cliente_api] = sorted(set(usuario["clientRoles"][cliente_api]) | set(roles))
    declarados = {c["clientId"] for c in realm.get("clients", [])}
    sin_cliente = [c for c in usuarios if c not in declarados]
    if sin_cliente:
        raise SystemExit(f"ROLES_DE_SERVICIO nombra clientes que ningun fichero declara: {sin_cliente}")
    realm["users"] = list(usuarios.values())


def ajustes_del_realm(realm, overrides, entorno):
    """Lo que el entorno cambia del realm (sslRequired, smtpServer...); la contrasena del SMTP, de su variable."""
    for clave, valor in (overrides.get("realm") or {}).items():
        realm[clave] = copy.deepcopy(valor)
    if "smtpServer" in realm and entorno.get("KC_SMTP_PASSWORD"):
        realm["smtpServer"]["password"] = entorno["KC_SMTP_PASSWORD"]


def montar(raiz, overrides, entorno):
    plataforma = raiz / "mto-platform" / "keycloak"
    realm = copy.deepcopy(leer(plataforma / "mto-realm.json"))
    if realm.get("realm") != REALM:
        raise SystemExit(f"mto-realm.json no es el realm '{REALM}'.")
    parciales, _ = ficheros(raiz)
    for ruta in parciales:
        mezclar(realm, leer(ruta))
    realm["clients"] = [con_overrides(cliente, overrides) for cliente in realm.get("clients", [])]
    ajustes_del_realm(realm, overrides, entorno)
    poner_secretos(realm, entorno)
    cuentas_de_servicio(realm)
    return realm


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repos", type=Path, default=Path(__file__).resolve().parent.parent.parent.parent,
                        help="Directorio que contiene los diez repositorios como hermanos.")
    parser.add_argument("--overrides", type=Path, help="Lo que el entorno cambia: {\"clients\": {...}, \"realm\": {...}}.")
    parser.add_argument("--output", type=Path, required=True, help="Fichero JSON que aplicara keycloak-config-cli.")
    args = parser.parse_args()

    overrides = leer(args.overrides) if args.overrides else {}
    realm = montar(args.repos.resolve(), overrides, os.environ)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(realm, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Realm '{REALM}' montado en {args.output}: {len(realm.get('clients', []))} clientes, "
          f"{len(realm['roles'].get('realm', []))} roles de realm, {len(realm['users'])} cuentas de servicio con roles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
