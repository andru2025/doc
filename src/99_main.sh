
# ============================================================================
# 99_main.sh - Parseo de argumentos y orquestacion de las fases
# ============================================================================

usage() {
    cat <<USAGE
${C_BOLD}deployer v${DEPLOYER_VERSION}${C_RESET} - despliegue automatizado PHP + MySQL/MariaDB sobre Docker

${C_BOLD}USO${C_RESET}
    sudo bash deploy.sh [opciones]

Sin opciones el script pregunta todo por pantalla. Si no hay terminal
interactiva (por ejemplo dentro de cloud-init o de un pipeline), hay que pasar
al menos --name, --web, --db y el origen del proyecto.

${C_BOLD}OPCIONES${C_RESET}
    --name NOMBRE         Nombre del proyecto (letras minusculas, numeros, - y _)
    --web apache|nginx    Servidor web
    --db mysql|mariadb    Motor de base de datos
    --php 8.3|8.2|7.4|5.6 Version de PHP (por defecto 8.3)
    --repo URL            Repositorio Git publico a clonar
    --zip URL             Archivo ZIP a descargar (alternativa a --repo)
    --docroot RUTA        Subdirectorio publico dentro del proyecto (ej: public)
    --sql RUTA|auto|none  Volcado a importar. auto = el .sql mas grande
    --pma                 Anadir phpMyAdmin
    --no-pma              No anadir phpMyAdmin
    --port-http PUERTO    Forzar el puerto HTTP
    --port-db PUERTO      Forzar el puerto de la base de datos
    --port-pma PUERTO     Forzar el puerto de phpMyAdmin
    --no-firewall         No tocar firewalld/ufw
    -y, --yes             Responder que si a todas las confirmaciones
    --dry-run             Mostrar lo que se haria sin tocar el sistema
    -h, --help            Esta ayuda
    -v, --version         Version

${C_BOLD}EJEMPLOS${C_RESET}
    # Interactivo
    sudo bash deploy.sh

    # Desatendido
    sudo bash deploy.sh --name tienda --web nginx --db mariadb --php 8.3 \
        --repo https://github.com/usuario/tienda.git --sql auto --pma -y
USAGE
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --name)        PROJECT_NAME=${2:-}; shift 2 ;;
            --web)         WEB_ENGINE=${2:-};   shift 2 ;;
            --db)          DB_ENGINE=${2:-};    shift 2 ;;
            --php)         PHP_VERSION=${2:-};  shift 2 ;;
            --repo)        SOURCE_REPO=${2:-};  shift 2 ;;
            --zip)         SOURCE_ZIP=${2:-};   shift 2 ;;
            --docroot)     DOCROOT=${2:-};      shift 2 ;;
            --sql)         SQL_CHOICE=${2:-};   shift 2 ;;
            --pma)         WANT_PMA=yes;        shift ;;
            --no-pma)      WANT_PMA=no;         shift ;;
            --port-http)   PORT_HTTP=${2:-};    shift 2 ;;
            --port-db)     PORT_DB=${2:-};      shift 2 ;;
            --port-pma)    PORT_PMA=${2:-};     shift 2 ;;
            --no-firewall) MANAGE_FIREWALL=0;   shift ;;
            -y|--yes)      ASSUME_YES=1;        shift ;;
            --dry-run)     DRY_RUN=1;           shift ;;
            -h|--help)     usage; exit 0 ;;
            -v|--version)  printf '%s\n' "$DEPLOYER_VERSION"; exit 0 ;;
            *)             err "Opcion desconocida: $1"; printf '\n'; usage; exit 2 ;;
        esac
    done

    # Validacion temprana: mejor fallar aqui que a mitad del despliegue.
    [[ -n "$WEB_ENGINE"  && ! "$WEB_ENGINE"  =~ ^(apache|nginx)$ ]] && \
        die "--web debe ser 'apache' o 'nginx' (recibido: $WEB_ENGINE)"
    [[ -n "$DB_ENGINE"   && ! "$DB_ENGINE"   =~ ^(mysql|mariadb)$ ]] && \
        die "--db debe ser 'mysql' o 'mariadb' (recibido: $DB_ENGINE)"
    [[ -n "$PHP_VERSION" && ! "$PHP_VERSION" =~ ^(8\.3|8\.2|7\.4|5\.6)$ ]] && \
        die "--php debe ser 8.3, 8.2, 7.4 o 5.6 (recibido: $PHP_VERSION)"
    [[ -n "$SOURCE_REPO" && -n "$SOURCE_ZIP" ]] && \
        die "--repo y --zip son excluyentes: elige un solo origen."
    return 0
}

require_root() {
    (( DRY_RUN )) && return 0
    if (( EUID != 0 )); then
        die "Este script necesita privilegios de root (instala Docker y abre puertos)." \
            "Vuelve a ejecutarlo con: sudo bash $0 $*"
    fi
}

# Todo lo que se imprime queda tambien en un log, util cuando algo falla en un
# VPS al que se entra por SSH y la pantalla se pierde.
start_logging() {
    (( DRY_RUN )) && return 0
    mkdir -p "$DEPLOYER_LOG_DIR"
    DEPLOYER_LOG_FILE="${DEPLOYER_LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$DEPLOYER_LOG_FILE") 2>&1
}

main() {
    parse_args "$@"
    detect_input
    require_root "$@"
    start_logging
    banner

    if (( DRY_RUN )); then
        warn "Modo --dry-run: no se modificara nada en el sistema."
    fi
    if (( NONINTERACTIVE )); then
        warn "Sin terminal interactiva: se usaran los valores de los flags y los de por defecto."
    fi

    phase_detect_os          # 1
    phase_setup_docker       # 1
    phase_project_name       # 2
    phase_choose_stack       # 3
    phase_assign_ports       # 4
    phase_fetch_source       # 5
    phase_db_config          # 6
    phase_generate_files     # 7
    phase_start_and_verify   # 8
    phase_import_sql         # 9
    phase_firewall           # 10
    phase_summary            # 10

    trap - ERR
    exit 0
}

# Con DEPLOYER_SOURCE_ONLY=1 el archivo se puede cargar con 'source' para
# probar sus funciones sin desplegar nada (ver tests/).
[[ -n "${DEPLOYER_SOURCE_ONLY:-}" ]] || main "$@"
