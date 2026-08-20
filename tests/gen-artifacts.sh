#!/usr/bin/env bash
#
# Genera los artefactos (compose, Dockerfile, nginx.conf, .env, manage.sh) para
# todas las combinaciones de stack, sin necesidad de Docker ni de un VPS.
# Sirve para revisar a ojo lo que se va a desplegar y para validar el YAML.
#
#   bash tests/gen-artifacts.sh [directorio_de_salida]
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUT="${1:-/tmp/deployer-artifacts}"
rm -rf "$OUT"
mkdir -p "$OUT"

# Se carga el script sin ejecutarlo y se llaman solo las funciones de plantilla.
export DEPLOYER_SOURCE_ONLY=1
# shellcheck disable=SC1091
source dist/deploy.sh
trap - ERR
set +e

# Una clave con espacios, comillas y '$' es justo lo que rompe un YAML mal
# escapado o un .env que no cite los valores.
DB_PASS="cl4ve con espacio \$VAR y 'comilla'"

generate_one() {
    PROJECT_NAME="demo"
    PROJECT_DIR="$1"
    APP_DIR="$1/app"
    WEB_ENGINE="$2"
    DB_ENGINE="$3"
    PHP_VERSION="$4"
    DOCROOT="$5"
    WANT_PMA="yes"
    PORT_HTTP=8080; PORT_DB=33060; PORT_PMA=8180
    DB_NAME="tienda"; DB_USER="tienda_user"
    DB_ROOT_PASS="R00tP4ss"
    DB_CONFIG_FILE=""
    MOUNT_SUFFIX=":Z"
    DB_BIND_ADDR="127.0.0.1"
    DRY_RUN=0

    mkdir -p "$PROJECT_DIR/nginx" "$APP_DIR"
    write_env_file
    write_dockerfile
    [[ "$WEB_ENGINE" == "nginx" ]] && write_nginx_conf
    write_compose_file
    write_manage_script
    return 0
}

count=0
for web in apache nginx; do
    for db in mysql mariadb; do
        for php in 8.3 7.4 5.6; do
            for docroot in "" "public"; do
                label="${web}-${db}-php${php}"
                [[ -n "$docroot" ]] && label="${label}-public"
                generate_one "${OUT}/${label}" "$web" "$db" "$php" "$docroot"
                count=$((count + 1))
                printf 'generado %s\n' "$label"
            done
        done
    done
done

printf '\n%s combinaciones generadas en %s\n' "$count" "$OUT"
