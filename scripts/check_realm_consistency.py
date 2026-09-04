#!/usr/bin/env python3
"""Comprueba que las piezas del realm 'mto' repartidas por los cuatro repositorios encajan.

Los ficheros de keycloak/ no los compila nadie: un error en ellos no se descubre hasta que alguien
levanta el stack o, peor, hasta que se importa en un entorno. Y desde que el realm se ensambla a
partir de un fichero base mas una importacion parcial por servicio, hay una forma nueva de
romperlo: que una parcial nombre algo que todavia no existe cuando le toca aplicarse.

Sustituye a RealmDefinitionsTest, que vivia en mto-configuration y solo veia los ficheros de ese
repositorio. Solo libreria estandar: este es un repositorio de composes y no se le mete Maven.

Uso:
    python3 scripts/check_realm_consistency.py [--repos DIR]

DIR es el directorio que contiene los cuatro repositorios como hermanos (por defecto, el padre de
este repositorio).
"""

import argparse
import json
import sys
from pathlib import Path

# Los clientes de API del dominio. mto-frontend tiene que poder emitir tokens dirigidos a los tres.
CLIENTES_API = ("mto-configuration-api", "mto-stock-api", "mto-gateway-api")

# Lo unico en lo que el realm local puede apartarse del base. Cualquier otra diferencia significa
# que alguien toco uno y no el otro, y el stack local estaria probando algo distinto de lo que se
# despliega.
DELTAS_LOCALES_PERMITIDOS = {
    # En local no hay TLS delante y auth.mto.local no es loopback, asi que 'external' cerraria el
    # acceso.
    "sslRequired": ("external", "none"),
    "displayName": ("MTO", "MTO (local)"),
}


class Problemas:
    """Acumula los fallos para poder informarlos todos de una vez."""

    def __init__(self):
        self.mensajes = []

    def error(self, comprobacion, detalle):
        self.mensajes.append((comprobacion, detalle))

    def informe(self):
        for comprobacion, detalle in self.mensajes:
            print(f"\n[FALLO] {comprobacion}\n{detalle}", file=sys.stderr)
        return 1 if self.mensajes else 0


def leer(ruta):
    if not ruta.is_file():
        raise SystemExit(
            f"No se encuentra {ruta}.\n"
            "Los cuatro repositorios tienen que estar como hermanos en el mismo directorio; "
            "usese --repos para indicar otro."
        )
    with ruta.open(encoding="utf-8") as f:
        return json.load(f)


def clientes_de(doc):
    return {c["clientId"]: c for c in doc.get("clients", [])}


def roles_de_cliente(doc):
    """{clientId: {nombre de rol}} a partir de roles.client."""
    return {
        cliente: {r["name"] for r in roles}
        for cliente, roles in doc.get("roles", {}).get("client", {}).items()
    }


def perfiles_de(doc):
    """{nombre de perfil: {cliente: [roles]}} a partir de roles.realm."""
    return {
        p["name"]: p.get("composites", {}).get("client", {})
        for p in doc.get("roles", {}).get("realm", [])
    }


def audiencias_de(cliente):
    """Los clientes a los que un cliente emite audiencia mediante audience mapper."""
    return {
        m.get("config", {}).get("included.client.audience")
        for m in cliente.get("protocolMappers", [])
        if m.get("protocolMapper") == "oidc-audience-mapper"
    }


# --- Las comprobaciones -------------------------------------------------------------------------


def ningun_compuesto_nombra_un_cliente_que_aun_no_existe(orden, problemas):
    """Un compuesto solo puede nombrar roles de clientes que YA esten en el realm.

    Keycloak resuelve los roles de cliente de un compuesto contra el realm que esta importando; si
    el cliente no esta, aborta con "App doesn't exist in role definitions" y no aplica nada. Como
    el realm se ensambla en varios pasos, lo que vale no es "definido en este fichero" sino
    "definido en este fichero o en uno anterior": es exactamente el orden de apply-partials.sh, y
    es la razon por la que mto-ops-cross-service.json va detras de las tres parciales de servicio.

    Lo mismo vale para los ROLES que nombra: un compuesto que agrupe 'mto-stock-api.stock-read'
    necesita que ese rol exista, no solo el cliente.

    Los audience mapper quedan fuera a proposito: su destino se resuelve al emitir el token, no al
    importar, asi que si pueden nombrar un cliente que aun no existe.
    """
    disponibles = {}
    for nombre, doc in orden:
        propios = roles_de_cliente(doc)
        for cliente in clientes_de(doc):
            propios.setdefault(cliente, set())

        for perfil, por_cliente in perfiles_de(doc).items():
            for cliente, roles in por_cliente.items():
                conocidos = disponibles.get(cliente)
                if conocidos is None and cliente not in propios:
                    problemas.error(
                        "un compuesto nombra un cliente que todavia no existe",
                        f"  {nombre}: el perfil '{perfil}' agrupa roles de '{cliente}', que ni\n"
                        f"  define ese fichero ni ha creado ningun paso anterior.\n"
                        f"  Keycloak aborta con \"App doesn't exist in role definitions\" y no aplica\n"
                        f"  nada. Lo que cruza servicios va en una parcial aplicada DESPUES de las que\n"
                        f"  crean los clientes; vease el orden en keycloak/apply-partials.sh.",
                    )
                    continue

                declarados = (conocidos or set()) | propios.get(cliente, set())
                huerfanos = [r for r in roles if r not in declarados]
                if huerfanos:
                    problemas.error(
                        "un compuesto nombra un rol que no existe",
                        f"  {nombre}: el perfil '{perfil}' agrupa {huerfanos} de '{cliente}', que\n"
                        f"  ningun fichero declara hasta este punto. El rol no llega a asignarse y\n"
                        f"  quien tenga ese perfil se queda sin ese permiso.",
                    )

        for cliente, roles in propios.items():
            disponibles.setdefault(cliente, set()).update(roles)


def base_y_local_no_se_separan(base, local, problemas):
    """mto-realm-local.json es mto-realm.json con los ajustes propios del entorno local.

    Quien anada algo tocando solo uno deja el stack local probando una autorizacion distinta de la
    que se despliega, y eso no da error en ninguna parte.
    """
    if clientes_de(base).keys() != clientes_de(local).keys():
        problemas.error(
            "el realm base y el local no declaran los mismos clientes",
            f"  base:  {sorted(clientes_de(base))}\n  local: {sorted(clientes_de(local))}",
        )

    if roles_de_cliente(base) != roles_de_cliente(local):
        problemas.error(
            "el realm base y el local no declaran los mismos permisos",
            f"  base:  {roles_de_cliente(base)}\n  local: {roles_de_cliente(local)}",
        )

    if perfiles_de(base) != perfiles_de(local):
        problemas.error(
            "el realm base y el local no declaran los mismos perfiles",
            f"  base:  {perfiles_de(base)}\n  local: {perfiles_de(local)}",
        )

    for clave in set(base) | set(local):
        if clave in ("clients", "roles", "users"):
            continue
        if base.get(clave) == local.get(clave):
            continue
        permitido = DELTAS_LOCALES_PERMITIDOS.get(clave)
        if permitido and (base.get(clave), local.get(clave)) == permitido:
            continue
        problemas.error(
            "el realm local se aparta del base en algo que no esta justificado",
            f"  '{clave}': base={base.get(clave)!r}, local={local.get(clave)!r}\n"
            f"  Si la diferencia es deliberada, anadase a DELTAS_LOCALES_PERMITIDOS con el motivo.",
        )


def el_base_no_trae_usuarios_ni_secretos(base, problemas):
    """mto-realm.json es la definicion que se lleva a un entorno desplegado."""
    if "users" in base:
        problemas.error(
            "el realm base ha ganado usuarios",
            "  mto-realm.json es lo que se lleva a un entorno desplegado y no debe traer ninguno.\n"
            "  Los de desarrollo los aporta cada servicio en su mto-<servicio>-dev.json.",
        )

    for cliente in base.get("clients", []):
        if "secret" in cliente:
            problemas.error(
                "el realm base trae un secreto de cliente",
                f"  El cliente '{cliente['clientId']}' de mto-realm.json trae un secreto. Los de un\n"
                f"  entorno desplegado los genera Keycloak al importar y se leen de su consola;\n"
                f"  versionar uno lo publica en el repositorio.",
            )


def el_frontal_emite_audiencia_para_los_tres(base, problemas):
    """Sin el mapper, un token del navegador puede llegar a un servicio sin su clientId en 'aud'.

    No es lo unico que pone la audiencia -el mapper 'audience resolve' del scope 'roles' ya anade
    todo cliente en el que el usuario tenga algun rol-, pero el explicito es la garantia: el
    resolutor se cae si se acota el scope del token o el full scope del cliente.
    """
    frontal = clientes_de(base).get("mto-frontend")
    if frontal is None:
        problemas.error(
            "el realm base no define mto-frontend",
            "  Es el cliente del navegador y lo unico comun a los tres servicios que vive en el base.",
        )
        return

    faltan = [c for c in CLIENTES_API if c not in audiencias_de(frontal)]
    if faltan:
        problemas.error(
            "mto-frontend no emite audiencia para todos los API",
            f"  Faltan los audience mapper hacia: {faltan}\n"
            f"  Un token del navegador llegaria a ese servicio sin su clientId en 'aud', y la\n"
            f"  falta de permisos se veria como un 401 'invalid token' en vez de un 403.",
        )


def ningun_cliente_se_declara_dos_veces_distinto(orden, problemas):
    """El mismo clientId en dos ficheros con contenido distinto: gana el ultimo, en silencio."""
    vistos = {}
    for nombre, doc in orden:
        for client_id, cliente in clientes_de(doc).items():
            # Un fichero de desarrollo puede reabrir un cliente solo para ponerle el secreto local.
            if set(cliente) <= {"clientId", "secret"}:
                continue
            anterior = vistos.get(client_id)
            if anterior and anterior[1] != cliente:
                problemas.error(
                    "un cliente se declara dos veces con contenido distinto",
                    f"  '{client_id}' esta en {anterior[0]} y en {nombre}, y no coinciden.\n"
                    f"  Al aplicarse con OVERWRITE gana el ultimo y el otro deja de valer, sin aviso.",
                )
            vistos.setdefault(client_id, (nombre, cliente))


def el_perfil_de_explotacion_cubre_los_tres(orden, cruzado, problemas):
    """mto-ops solo lo define mto-ops-cross-service.json, y tiene que cubrir a los tres.

    Los permisos son roles de CLIENTE y cada aplicacion lee los del suyo: 'ops-metrics' existe tres
    veces, una por servicio. Un mto-ops al que le falte uno recibe un 403 en el Actuator de ese
    servicio. Ademas una parcial reescribe el rol entero, asi que este fichero tiene que repetir
    todo lo que el perfil debe tener: lo que no este aqui, no esta.
    """
    perfil = perfiles_de(cruzado).get("mto-ops")
    if perfil is None:
        problemas.error(
            "mto-ops-cross-service.json no define mto-ops",
            "  Es el unico sitio donde se define el perfil de explotacion.",
        )
        return

    for nombre, doc in orden:
        for cliente, roles in roles_de_cliente(doc).items():
            for rol in ("ops-metrics", "ops-write"):
                if rol in roles and rol not in perfil.get(cliente, []):
                    problemas.error(
                        "el perfil de explotacion no cubre un servicio",
                        f"  {nombre} declara '{cliente}.{rol}', pero mto-ops no lo agrupa.\n"
                        f"  Quien tenga el perfil mto-ops recibiria un 403 en el Actuator de ese\n"
                        f"  servicio. Anadase a mto-ops-cross-service.json.",
                    )

    otros = [p for nombre, doc in orden for p in perfiles_de(doc) if p == "mto-ops"]
    if otros:
        problemas.error(
            "mto-ops se define en mas de un sitio",
            "  Una parcial reescribe el rol entero, asi que dos definiciones significan que la\n"
            "  ultima en aplicarse borra a la otra. mto-ops vive solo en mto-ops-cross-service.json.",
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--repos",
        type=Path,
        default=Path(__file__).resolve().parent.parent.parent,
        help="Directorio que contiene los cuatro repositorios como hermanos.",
    )
    args = parser.parse_args()

    raiz = args.repos.resolve()
    plataforma = raiz / "mto-platform" / "keycloak"

    base = leer(plataforma / "mto-realm.json")
    local = leer(plataforma / "mto-realm-local.json")
    cruzado = leer(plataforma / "mto-ops-cross-service.json")

    # El mismo orden en el que apply-partials.sh los aplica. Si cambia alli, cambia aqui.
    orden = [
        ("mto-realm-local.json (--import-realm)", local),
        ("mto-configuration-partial-import.json", leer(raiz / "mto-configuration" / "keycloak" / "mto-configuration-partial-import.json")),
        ("mto-stock-partial-import.json", leer(raiz / "mto-stock" / "keycloak" / "mto-stock-partial-import.json")),
        ("mto-gateway-partial-import.json", leer(raiz / "mto-gateway" / "keycloak" / "mto-gateway-partial-import.json")),
        ("mto-ops-cross-service.json", cruzado),
        ("mto-configuration-dev.json", leer(raiz / "mto-configuration" / "keycloak" / "mto-configuration-dev.json")),
        ("mto-stock-dev.json", leer(raiz / "mto-stock" / "keycloak" / "mto-stock-dev.json")),
    ]

    problemas = Problemas()
    ningun_compuesto_nombra_un_cliente_que_aun_no_existe(orden, problemas)
    base_y_local_no_se_separan(base, local, problemas)
    el_base_no_trae_usuarios_ni_secretos(base, problemas)
    el_frontal_emite_audiencia_para_los_tres(base, problemas)
    ningun_cliente_se_declara_dos_veces_distinto(orden, problemas)
    el_perfil_de_explotacion_cubre_los_tres(orden[:-3], cruzado, problemas)

    codigo = problemas.informe()
    if codigo == 0:
        print(f"Realm consistente: {len(orden)} ficheros comprobados en el orden de aplicacion.")
    return codigo


if __name__ == "__main__":
    sys.exit(main())
