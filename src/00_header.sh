#!/usr/bin/env bash
#
# deployer - Despliegue automatizado de proyectos PHP + MySQL/MariaDB sobre Docker
#
# Levanta en cualquier VPS Linux un ecosistema Docker completo (servidor web +
# base de datos) a partir de un repositorio Git o un ZIP, respetando las
# credenciales que el propio proyecto trae en su archivo de conexion.
#
# Uso:   curl -fsSL __RAW_URL__/deploy.sh -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh
#
# NO EDITAR dist/deploy.sh A MANO: se genera con ./build.sh desde src/*.sh
#
set -Eeuo pipefail

DEPLOYER_VERSION="1.0.0"
DEPLOYER_BASE_DIR="/opt/deployer"
DEPLOYER_LOG_DIR="/var/log/deployer"

# --- Estado global -----------------------------------------------------------
# Rellenado por los flags de la linea de comandos o por las preguntas al usuario.
PROJECT_NAME=""
WEB_ENGINE=""          # apache | nginx
DB_ENGINE=""           # mysql | mariadb
PHP_VERSION=""         # 8.3 | 8.2 | 7.4 | 5.6
SOURCE_REPO=""         # URL git
SOURCE_ZIP=""          # URL zip
DOCROOT=""             # subdirectorio publico dentro del proyecto ("" = raiz)
SQL_CHOICE=""          # ruta relativa | auto | none
WANT_PMA=""            # yes | no
PORT_HTTP=""
PORT_DB=""
PORT_PMA=""
ASSUME_YES=0
DRY_RUN=0
NONINTERACTIVE=0
MANAGE_FIREWALL=1
TTY_IN=""

# Credenciales de la base de datos (Fase 6)
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_ROOT_PASS=""
DB_CONFIG_FILE=""      # archivo de conexion detectado dentro del proyecto

# Rutas de trabajo (Fase 2)
PROJECT_DIR=""
APP_DIR=""

# Datos del entorno (Fase 1)
OS_ID=""
OS_NAME=""
OS_VERSION=""
PKG_FAMILY=""          # debian | rhel | suse | arch
PKG_INSTALL=""
FIREWALL_KIND=""       # firewalld | ufw | none
SELINUX_ON=0
MOUNT_SUFFIX=""        # ":Z" cuando SELinux esta en Enforcing
DOCKER_WAS_PRESENT=0

# Control de rollback: se activa cuando ya hemos creado algo que limpiar.
ROLLBACK_ARMED=0

# --- Manejo de errores -------------------------------------------------------
on_error() {
    local exit_code=$1 line=$2 cmd=$3
    printf '\n' >&2
    err "El despliegue fallo en la linea ${line} (codigo ${exit_code})."
    err "Comando: ${cmd}"
    [[ -n "${DEPLOYER_LOG_FILE:-}" ]] && err "Log completo: ${DEPLOYER_LOG_FILE}"
    offer_rollback
    exit "$exit_code"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
