#!/usr/bin/env python3
"""Valida los docker-compose.yml que genera deployer.

Se ejecuta sobre la salida de tests/gen-artifacts.sh y comprueba tanto que el
YAML sea valido como que diga lo que tiene que decir: servicios correctos,
volumenes con nombre, healthchecks, y sobre todo que la contrasena sobreviva
intacta a las dos capas de escapado (interpolacion de Compose + YAML).

    python3 tests/validate-compose.py [directorio]

Requiere PyYAML. Si no esta instalado, sale con codigo 0 y avisa.
"""
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("PyYAML no instalado: validacion de compose omitida "
          "(pip install pyyaml para activarla)")
    sys.exit(0)

# La contrasena que usa tests/gen-artifacts.sh: espacios, un '$' y una comilla.
EXPECTED_PASS = "cl4ve con espacio $VAR y 'comilla'"


def uninterpolate(value):
    """Deshace lo que hara Docker Compose al leer el archivo.

    Compose sustituye $VAR y ${VAR} por variables de entorno, y convierte '$$'
    en un '$' literal. Para comprobar que la clave llega entera al contenedor
    hay que aplicar esa misma regla aqui.
    """
    if not isinstance(value, str):
        return value
    if re.search(r'(?<!\$)\$(?!\$)', value):
        raise AssertionError(
            f"queda un '$' sin duplicar, Compose lo interpolaria: {value!r}")
    return value.replace('$$', '$')


def check_file(path):
    """Devuelve la lista de problemas encontrados en un compose."""
    label = os.path.basename(os.path.dirname(path))
    problems = []

    def bad(msg):
        problems.append(f"{label}: {msg}")

    try:
        with open(path, encoding='utf-8') as fh:
            doc = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        return [f"{label}: YAML invalido: {exc}"]

    services = doc.get('services', {})
    is_nginx = 'nginx' in label

    expected_services = {'web', 'db', 'pma'} | ({'php'} if is_nginx else set())
    if set(services) != expected_services:
        bad(f"servicios {sorted(services)}, esperaba {sorted(expected_services)}")
        return problems

    env = services['db']['environment']
    try:
        got = uninterpolate(env['MYSQL_PASSWORD'])
    except AssertionError as exc:
        bad(f"MYSQL_PASSWORD: {exc}")
    else:
        if got != EXPECTED_PASS:
            bad(f"MYSQL_PASSWORD llega como {got!r}, esperaba {EXPECTED_PASS!r}")

    for key in ('MYSQL_ROOT_PASSWORD', 'MYSQL_DATABASE', 'MYSQL_USER'):
        if key not in env:
            bad(f"falta {key} en el servicio db")

    # Los datos tienen que vivir en un volumen con nombre, no en el contenedor.
    volumes = doc.get('volumes', {})
    for vol in ('dbdata', 'weblogs'):
        if vol not in volumes or 'name' not in (volumes.get(vol) or {}):
            bad(f"falta el volumen con nombre '{vol}'")
    if services['db'].get('volumes') != ['dbdata:/var/lib/mysql']:
        bad(f"el datadir no usa el volumen: {services['db'].get('volumes')}")

    # La base no debe quedar expuesta a internet por defecto.
    ports = services['db'].get('ports', [])
    if not ports or not str(ports[0]).startswith('127.0.0.1:'):
        bad(f"el puerto de la base no esta atado al loopback: {ports}")

    # Sin la etiqueta :Z, SELinux deja el docroot vacio en AlmaLinux/Rocky.
    for svc in ('web', 'php'):
        if svc not in services:
            continue
        mounts = [str(v) for v in services[svc].get('volumes', [])]
        if not any(m.startswith('./app:/var/www/html:Z') for m in mounts):
            bad(f"{svc}: el codigo no se monta con la etiqueta SELinux: {mounts}")

    if is_nginx:
        conf = [m for m in map(str, services['web']['volumes'])
                if 'default.conf' in m]
        if not conf or not conf[0].endswith(':ro,Z'):
            bad(f"la configuracion de nginx deberia montarse :ro,Z: {conf}")

    # Nada debe arrancar antes de que la base acepte conexiones.
    for svc in expected_services - {'db'}:
        dep = services[svc].get('depends_on', {})
        if 'db' not in dep:
            bad(f"{svc}: no depende de db")
        elif dep['db'].get('condition') != 'service_healthy':
            bad(f"{svc}: espera a db con '{dep['db'].get('condition')}' "
                "en vez de service_healthy")

    for svc in ('web', 'db') + (('php',) if is_nginx else ()):
        hc = services[svc].get('healthcheck')
        if not hc:
            bad(f"{svc}: sin healthcheck")
        elif hc.get('test', [None])[0] != 'CMD-SHELL':
            bad(f"{svc}: healthcheck mal formado: {hc.get('test')}")

    for svc in services:
        if services[svc].get('restart') != 'unless-stopped':
            bad(f"{svc}: deberia reiniciarse solo (restart: unless-stopped)")

    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '/tmp/deployer-artifacts'
    files = sorted(glob.glob(os.path.join(root, '*', 'docker-compose.yml')))

    if not files:
        print(f"No hay compose que validar en {root}. "
              "Ejecuta antes tests/gen-artifacts.sh")
        return 1

    problems = []
    for path in files:
        problems.extend(check_file(path))

    for p in problems:
        print(f"  [FALLO] {p}")

    print(f"  {len(files)} compose validados, {len(problems)} problemas")
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
