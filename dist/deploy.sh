#!/usr/bin/env bash
#
# deployer - Despliegue automatizado de proyectos PHP + MySQL/MariaDB sobre Docker
#
# Levanta en cualquier VPS Linux un ecosistema Docker completo (servidor web +
# base de datos) a partir de un repositorio Git o un ZIP, respetando las
# credenciales que el propio proyecto trae en su archivo de conexion.
#
# Uso:   curl -fsSL https://raw.githubusercontent.com/andru2025/doc/main/dist/deploy.sh -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh
#
# NO EDITAR dist/deploy.sh A MANO: se genera con ./build.sh desde src/*.sh
#
# Generado por build.sh el 2026-08-20 22:39 UTC - no editar
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

# ============================================================================
# 10_ui.sh - Salida por pantalla, logging y preguntas al usuario
# ============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

info()  { printf '%s\n' "${C_BLUE}[*]${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN}[+]${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED}[x]${C_RESET} $*" >&2; }
step()  { printf '\n%s\n' "${C_BOLD}${C_CYAN}==> $*${C_RESET}"; }
hint()  { printf '%s\n' "    ${C_DIM}$*${C_RESET}"; }
die()   { err "$@"; offer_rollback; exit 1; }

# Encabezado de bienvenida.
banner() {
    printf '%s\n' "${C_BOLD}${C_CYAN}"
    cat <<'BANNER'
  ____             _
 |  _ \  ___ _ __ | | ___  _   _  ___ _ __
 | | | |/ _ \ '_ \| |/ _ \| | | |/ _ \ '__|
 | |_| |  __/ |_) | | (_) | |_| |  __/ |
 |____/ \___| .__/|_|\___/ \__, |\___|_|
            |_|            |___/
BANNER
    printf '%s\n\n' "  PHP + MySQL/MariaDB sobre Docker  v${DEPLOYER_VERSION}${C_RESET}"
}

# En --dry-run describimos la accion en vez de ejecutarla.
run() {
    if (( DRY_RUN )); then
        printf '%s\n' "    ${C_DIM}[dry-run] $*${C_RESET}"
        return 0
    fi
    "$@"
}

# --- Entrada del usuario -----------------------------------------------------

# Determina de donde leer. Un `curl | bash` deja stdin ocupado por el pipe, asi
# que en ese caso caemos a /dev/tty; si tampoco existe, no hay interactividad.
detect_input() {
    if [[ -t 0 ]]; then
        TTY_IN=/dev/stdin
    elif [[ -p /dev/stdin ]] && [[ -e /dev/tty ]] && (: >/dev/tty) 2>/dev/null; then
        # Solo el caso 'curl | bash': stdin es una tuberia y el usuario sigue
        # delante del terminal. Si stdin viene de /dev/null o de un fichero la
        # intencion es un despliegue desatendido, y caer a /dev/tty dejaria el
        # script colgado en la primera pregunta esperando a alguien que no esta.
        TTY_IN=/dev/tty
    else
        NONINTERACTIVE=1
        TTY_IN=""
    fi
}

# ask VARIABLE "Pregunta" ["valor por defecto"] ["nombre del flag"]
# Si la variable ya trae valor (viene de un flag) no pregunta nada.
ask() {
    local var=$1 prompt=$2 default=${3:-} flag=${4:-}
    local current=${!var}

    if [[ -n "$current" ]]; then
        return 0
    fi

    if (( NONINTERACTIVE )); then
        if [[ -n "$default" ]]; then
            printf -v "$var" '%s' "$default"
            return 0
        fi
        die "Sin terminal interactiva y falta un valor obligatorio: ${flag:-$var}." \
            "Pasalo por linea de comandos o ejecuta el script desde una sesion con TTY."
    fi

    local answer=""
    if [[ -n "$default" ]]; then
        printf '%s' "    ${prompt} [${C_BOLD}${default}${C_RESET}]: "
    else
        printf '%s' "    ${prompt}: "
    fi
    IFS= read -r answer < "$TTY_IN" || answer=""
    printf -v "$var" '%s' "${answer:-$default}"
}

# Igual que ask, pero sin eco en pantalla (contrasenas).
ask_secret() {
    local var=$1 prompt=$2 default=${3:-}
    [[ -n "${!var}" ]] && return 0
    if (( NONINTERACTIVE )); then
        printf -v "$var" '%s' "$default"
        return 0
    fi
    local answer=""
    printf '%s' "    ${prompt}: "
    IFS= read -rs answer < "$TTY_IN" || answer=""
    printf '\n'
    printf -v "$var" '%s' "${answer:-$default}"
}

# ask_menu VARIABLE "Titulo" "valor|Etiqueta" "valor|Etiqueta" ...
# La primera opcion es la de por defecto.
ask_menu() {
    local var=$1 title=$2; shift 2
    local opts=("$@")
    local default_value="${opts[0]%%|*}"

    if [[ -n "${!var}" ]]; then
        return 0
    fi
    if (( NONINTERACTIVE )); then
        printf -v "$var" '%s' "$default_value"
        return 0
    fi

    printf '\n%s\n' "    ${C_BOLD}${title}${C_RESET}"
    local i=1 o
    for o in "${opts[@]}"; do
        printf '      %s) %s\n' "$i" "${o#*|}"
        i=$((i + 1))
    done

    local choice=""
    while true; do
        printf '%s' "    Opcion [${C_BOLD}1${C_RESET}]: "
        IFS= read -r choice < "$TTY_IN" || choice=""
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#opts[@]} )); then
            printf -v "$var" '%s' "${opts[choice-1]%%|*}"
            return 0
        fi
        warn "Elige un numero entre 1 y ${#opts[@]}."
    done
}

# confirm "Pregunta" [yes|no]  -> 0 si acepta
confirm() {
    local prompt=$1 default=${2:-yes} answer=""
    (( ASSUME_YES )) && return 0
    if (( NONINTERACTIVE )); then
        [[ "$default" == "yes" ]]
        return
    fi
    local hint_str="[S/n]"
    [[ "$default" == "no" ]] && hint_str="[s/N]"
    printf '%s' "    ${prompt} ${hint_str}: "
    IFS= read -r answer < "$TTY_IN" || answer=""
    answer=${answer:-$default}
    [[ "${answer,,}" =~ ^(s|si|y|yes)$ ]]
}

# --- Espera activa -----------------------------------------------------------

# wait_for "descripcion" segundos comando...
# Reintenta el comando hasta que devuelva 0 o se agote el tiempo.
wait_for() {
    local label=$1 timeout=$2; shift 2
    local spin='|/-\' waited=0 frame=0

    (( DRY_RUN )) && { printf '    %s ... [dry-run]\n' "$label"; return 0; }

    while (( waited < timeout )); do
        if "$@" >/dev/null 2>&1; then
            printf '\r    %s ... %sOK%s          \n' "$label" "$C_GREEN" "$C_RESET"
            return 0
        fi
        printf '\r    %s ... %s %ss ' "$label" "${spin:frame%4:1}" "$waited"
        frame=$((frame + 1))
        sleep 2
        waited=$((waited + 2))
    done
    printf '\r    %s ... %sTIMEOUT%s      \n' "$label" "$C_RED" "$C_RESET"
    return 1
}

# --- Rollback ----------------------------------------------------------------

offer_rollback() {
    (( ROLLBACK_ARMED )) || return 0
    (( DRY_RUN )) && return 0
    ROLLBACK_ARMED=0   # evita recursion si la limpieza tambien falla

    warn "El despliegue quedo a medias en ${PROJECT_DIR}."
    if confirm "Deshacer los cambios (borra contenedores, volumenes y archivos de este proyecto)?" no; then
        info "Limpiando..."
        if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
            (cd "$PROJECT_DIR" && docker compose down -v --remove-orphans) >/dev/null 2>&1 || true
        fi
        rm -rf "$PROJECT_DIR"
        ok "Limpieza terminada."
    else
        hint "Puedes limpiar a mano con: cd ${PROJECT_DIR} && docker compose down -v && rm -rf ${PROJECT_DIR}"
    fi
}

# ============================================================================
# 20_os.sh - Deteccion de la distribucion, SELinux y firewall
# ============================================================================

phase_detect_os() {
    step "Fase 1/10 - Reconociendo el sistema"

    [[ -r /etc/os-release ]] || die "No encuentro /etc/os-release: distribucion no soportada."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-desconocido}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    OS_VERSION="${VERSION_ID:-}"
    local id_like="${ID_LIKE:-}"

    # Agrupamos por gestor de paquetes: lo que cambia entre distros de la misma
    # familia (Debian/Ubuntu, RHEL/Alma/Rocky/CentOS) es practicamente nada.
    case " ${OS_ID} ${id_like} " in
        *" debian "*|*" ubuntu "*)
            PKG_FAMILY="debian"
            PKG_INSTALL="apt-get install -y -q"
            ;;
        *" rhel "*|*" fedora "*|*" centos "*)
            PKG_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then
                PKG_INSTALL="dnf install -y -q"
            else
                PKG_INSTALL="yum install -y -q"
            fi
            ;;
        *" suse "*|*" opensuse "*)
            PKG_FAMILY="suse"
            PKG_INSTALL="zypper --non-interactive install"
            ;;
        *" arch "*)
            PKG_FAMILY="arch"
            PKG_INSTALL="pacman -S --noconfirm --needed"
            ;;
        *)
            die "Distribucion no reconocida: ${OS_NAME} (ID=${OS_ID}, ID_LIKE=${id_like})."
            ;;
    esac

    ok "Sistema: ${OS_NAME} (familia ${PKG_FAMILY})"

    detect_selinux
    detect_firewall
    detect_arch_supported
}

detect_arch_supported() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64|aarch64|arm64) hint "Arquitectura: ${arch}" ;;
        *) warn "Arquitectura ${arch}: puede que no existan imagenes Docker oficiales para todos los servicios." ;;
    esac
}

# En RHEL y derivadas SELinux bloquea los bind mounts salvo que se etiqueten.
# Sin el sufijo :Z el contenedor ve el docroot vacio o da "Permission denied",
# que es el fallo mas comun al desplegar esto en AlmaLinux o Rocky.
detect_selinux() {
    MOUNT_SUFFIX=""
    SELINUX_ON=0
    if command -v getenforce >/dev/null 2>&1; then
        if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
            SELINUX_ON=1
            MOUNT_SUFFIX=":Z"
            info "SELinux activo: los volumenes se etiquetaran con ':Z'."
        fi
    fi
}

detect_firewall() {
    FIREWALL_KIND="none"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALL_KIND="firewalld"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        FIREWALL_KIND="ufw"
    fi
    if [[ "$FIREWALL_KIND" != "none" ]]; then
        info "Cortafuegos detectado: ${FIREWALL_KIND}"
    else
        hint "Sin cortafuegos activo en el sistema."
    fi
}

# Instala paquetes solo si faltan; en un VPS recien creado suele faltar todo.
ensure_packages() {
    local missing=() pkg
    for pkg in "$@"; do
        local bin="${pkg%%:*}" name="${pkg##*:}"
        command -v "$bin" >/dev/null 2>&1 || missing+=("$name")
    done
    (( ${#missing[@]} )) || return 0

    info "Instalando paquetes que faltan: ${missing[*]}"
    case "$PKG_FAMILY" in
        debian)
            run env DEBIAN_FRONTEND=noninteractive apt-get update -q
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
            ;;
        rhel|suse|arch)
            # shellcheck disable=SC2086
            run $PKG_INSTALL "${missing[@]}"
            ;;
    esac
}

# Nombres de paquete que no coinciden entre familias.
pkg_name_for() {
    local tool=$1
    case "$tool:$PKG_FAMILY" in
        ss:debian)   echo "iproute2" ;;
        ss:*)        echo "iproute" ;;
        unzip:*)     echo "unzip" ;;
        git:*)       echo "git" ;;
        curl:*)      echo "curl" ;;
        *)           echo "$tool" ;;
    esac
}

ensure_base_tools() {
    local specs=() tool
    for tool in curl git unzip ss; do
        specs+=("${tool}:$(pkg_name_for "$tool")")
    done
    ensure_packages "${specs[@]}"
}

# ============================================================================
# 30_docker.sh - Instalacion y verificacion de Docker + plugin compose
# ============================================================================

docker_alive() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

compose_alive() {
    docker compose version >/dev/null 2>&1
}

phase_setup_docker() {
    step "Fase 1/10 - Docker"

    ensure_base_tools

    if docker_alive; then
        DOCKER_WAS_PRESENT=1
        ok "Docker ya esta instalado y funcionando ($(docker --version 2>/dev/null | head -1)). Se omite la instalacion."
    elif command -v docker >/dev/null 2>&1; then
        # El binario esta pero el demonio no responde: casi siempre es que el
        # servicio no arranco al instalar la imagen del VPS.
        info "Docker esta instalado pero el demonio no responde. Intentando arrancarlo..."
        start_docker_daemon
        (( DRY_RUN )) || docker_alive || die "El demonio de Docker no arranca. Revisa: systemctl status docker"
        DOCKER_WAS_PRESENT=1
        ok "Demonio de Docker arrancado."
    else
        install_docker
        start_docker_daemon
        # En --dry-run no se ha instalado nada, asi que el demonio no puede
        # responder: comprobarlo abortaria el simulacro en la fase 1 y las
        # nueve fases restantes no llegarian a verse nunca.
        (( DRY_RUN )) || docker_alive || die "Docker se instalo pero el demonio no responde. Revisa: systemctl status docker"
        ok "Docker instalado correctamente."
    fi

    if compose_alive; then
        ok "Docker Compose disponible ($(docker compose version --short 2>/dev/null))."
    else
        install_compose_plugin
        (( DRY_RUN )) || compose_alive || die "No se pudo instalar el plugin 'docker compose'."
        ok "Plugin Docker Compose instalado."
    fi
}

install_docker() {
    info "Instalando Docker en ${OS_NAME}..."

    # El instalador oficial cubre Debian, Ubuntu, RHEL, CentOS, Fedora y SLES,
    # y se mantiene al dia con las versiones nuevas de cada distro. Solo si
    # falla o la distro no esta en su lista pasamos al camino manual.
    if [[ "$PKG_FAMILY" != "arch" ]]; then
        if run bash -c 'curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh'; then
            rm -f /tmp/get-docker.sh
            return 0
        fi
        warn "El instalador oficial fallo. Probando con los repositorios de la distribucion."
    fi

    case "$PKG_FAMILY" in
        debian) install_docker_debian ;;
        rhel)   install_docker_rhel ;;
        suse)   run zypper --non-interactive install docker docker-compose ;;
        arch)   run pacman -S --noconfirm --needed docker docker-compose ;;
    esac
}

install_docker_debian() {
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q ca-certificates curl gnupg
    run install -m 0755 -d /etc/apt/keyrings

    local repo_id="$OS_ID"
    # Las derivadas (Linux Mint, Pop!_OS, elementary) no tienen repo propio en
    # download.docker.com: hay que apuntar al de su distribucion base.
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) [[ "${ID_LIKE:-}" == *ubuntu* ]] && repo_id="ubuntu" || repo_id="debian" ;;
    esac

    run bash -c "curl -fsSL https://download.docker.com/linux/${repo_id}/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes"
    run chmod a+r /etc/apt/keyrings/docker.gpg

    local codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "$codename" ]] || die "No puedo determinar el nombre en clave de la distribucion para el repositorio de Docker."

    run bash -c "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${repo_id} ${codename} stable' > /etc/apt/sources.list.d/docker.list"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
    local mgr="dnf"
    command -v dnf >/dev/null 2>&1 || mgr="yum"

    if [[ "$mgr" == "dnf" ]]; then
        run dnf install -y -q dnf-plugins-core
        # AlmaLinux, Rocky y CentOS Stream usan el repositorio de CentOS.
        local repo_distro="centos"
        [[ "$OS_ID" == "fedora" ]] && repo_distro="fedora"
        run dnf config-manager --add-repo "https://download.docker.com/linux/${repo_distro}/docker-ce.repo"
    else
        run yum install -y -q yum-utils
        run yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi

    run "$mgr" install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker_daemon() {
    if command -v systemctl >/dev/null 2>&1; then
        run systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
        run service docker start
    else
        warn "Sin systemd ni service: arranca el demonio de Docker a mano."
        return 0
    fi
    # El socket tarda un momento en aceptar conexiones tras el arranque.
    wait_for "Esperando al demonio de Docker" 60 docker info || return 1
}

# En distros sin docker-compose-plugin empaquetado (o si el paquete no entro),
# el plugin es un unico binario que basta con dejar en el directorio correcto.
install_compose_plugin() {
    info "Instalando el plugin de Docker Compose..."

    case "$PKG_FAMILY" in
        debian) run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-plugin || true ;;
        rhel)   run bash -c "(dnf install -y -q docker-compose-plugin || yum install -y -q docker-compose-plugin) || true" ;;
    esac
    compose_alive && return 0

    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "No hay binario oficial de Docker Compose para la arquitectura ${arch}." ;;
    esac

    local dest=/usr/local/lib/docker/cli-plugins
    run mkdir -p "$dest"
    run bash -c "curl -fsSL 'https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}' -o '${dest}/docker-compose'"
    run chmod +x "${dest}/docker-compose"
}

# ============================================================================
# 40_ports.sh - Puertos ocupados y asignacion consecutiva de puertos libres
# ============================================================================

PORT_HTTP_BASE=8080
PORT_DB_BASE=33060
PORT_PMA_BASE=8180

# Puertos publicados por contenedores Docker, incluidos los parados: un
# contenedor detenido reclama su puerto en cuanto alguien lo arranca, asi que
# ignorarlos provocaria un choque mas adelante.
#
# El '|| true' final no es decorativo: 'grep' devuelve 1 cuando no encuentra
# nada, y con 'set -e' + 'pipefail' eso mata el script en un servidor recien
# instalado, que es justo el caso normal (Docker sin ningun contenedor todavia).
# Aqui "no hay puertos ocupados" es una respuesta valida, no un error.
docker_used_ports() {
    docker_alive || return 0
    docker ps -a --format '{{.Ports}}' 2>/dev/null \
        | tr ',' '\n' \
        | grep -oE '(^|:)[0-9]+->' \
        | grep -oE '[0-9]+' \
        | sort -un || true
}

# Puertos en escucha en el host (servicios nativos: Apache del sistema, MySQL
# instalado a pelo, un panel de control...). Mismo motivo para el '|| true':
# un servidor sin nada escuchando no es un fallo.
host_used_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un || true
    fi
}

# Cache de puertos ocupados: consultar Docker por cada puerto candidato es lento.
USED_PORTS=""
refresh_used_ports() {
    USED_PORTS=$'\n'"$( { docker_used_ports; host_used_ports; } | sort -un || true )"$'\n'
}

port_free() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    [[ "$USED_PORTS" == *$'\n'"$port"$'\n'* ]] && return 1
    return 0
}

# Deja el primer puerto libre a partir de la base en NEXT_PORT (y lo imprime),
# marcandolo como usado para que la siguiente llamada no lo repita.
#
# El resultado va por una variable global y no solo por la salida estandar a
# proposito: dentro de $(...) tanto la marca de "puerto usado" como un die()
# se quedarian encerrados en la subshell y el que llama seguiria como si nada.
NEXT_PORT=""
next_free_port() {
    local port=$1 limit=$(( $1 + 200 ))
    NEXT_PORT=""
    while (( port <= limit )); do
        if port_free "$port"; then
            NEXT_PORT="$port"
            USED_PORTS+="${port}"$'\n'
            printf '%s' "$port"
            return 0
        fi
        port=$((port + 1))
    done
    die "No encuentro un puerto libre entre ${1} y ${limit}."
}

# Valida un puerto forzado por el usuario con --port-* o por teclado.
claim_port() {
    local var=$1 base=$2 label=$3
    local wanted=${!var}

    if [[ -n "$wanted" ]]; then
        if ! [[ "$wanted" =~ ^[0-9]+$ ]] || (( wanted < 1 || wanted > 65535 )); then
            die "Puerto invalido para ${label}: ${wanted}"
        fi
        if ! port_free "$wanted"; then
            die "El puerto ${wanted} (${label}) ya esta ocupado. Elige otro o deja que el script lo asigne."
        fi
        USED_PORTS+="${wanted}"$'\n'
        return 0
    fi

    next_free_port "$base" >/dev/null
    printf -v "$var" '%s' "$NEXT_PORT"
}

phase_assign_ports() {
    step "Fase 4/10 - Puertos"

    refresh_used_ports
    local occupied
    occupied="$(printf '%s' "$USED_PORTS" | grep -cE '^[0-9]+$' || true)"
    info "Puertos ya ocupados en este servidor: ${occupied}"

    claim_port PORT_HTTP "$PORT_HTTP_BASE" "HTTP"
    claim_port PORT_DB   "$PORT_DB_BASE"   "base de datos"
    [[ "$WANT_PMA" == "yes" ]] && claim_port PORT_PMA "$PORT_PMA_BASE" "phpMyAdmin"

    printf '\n'
    ok "HTTP        -> ${C_BOLD}${PORT_HTTP}${C_RESET}"
    ok "${DB_ENGINE}      -> ${C_BOLD}${PORT_DB}${C_RESET}"
    [[ "$WANT_PMA" == "yes" ]] && ok "phpMyAdmin  -> ${C_BOLD}${PORT_PMA}${C_RESET}"
    printf '\n'

    if ! confirm "Usar estos puertos?" yes; then
        PORT_HTTP=""; PORT_DB=""; PORT_PMA=""
        refresh_used_ports
        next_free_port "$PORT_HTTP_BASE" >/dev/null; ask PORT_HTTP "Puerto HTTP" "$NEXT_PORT"
        next_free_port "$PORT_DB_BASE"   >/dev/null; ask PORT_DB   "Puerto de la base de datos" "$NEXT_PORT"
        if [[ "$WANT_PMA" == "yes" ]]; then
            next_free_port "$PORT_PMA_BASE" >/dev/null
            ask PORT_PMA "Puerto de phpMyAdmin" "$NEXT_PORT"
        fi
        local p
        for p in "$PORT_HTTP" "$PORT_DB" ${PORT_PMA:+"$PORT_PMA"}; do
            [[ "$p" =~ ^[0-9]+$ ]] || die "Puerto invalido: ${p}"
            port_free "$p" || warn "El puerto ${p} parece ocupado: el contenedor puede no arrancar."
        done
    fi
    return 0
}

# ============================================================================
# 50_project.sh - Nombre del proyecto, colisiones y directorio de trabajo
# ============================================================================

# El nombre se usa como prefijo de contenedores, red y volumenes, asi que tiene
# que valer como identificador de Docker: minusculas, digitos, guion y guion bajo.
valid_project_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{1,30}$ ]]
}

# Un nombre "libre" tiene que estarlo en los cuatro sitios donde deja rastro un
# despliegue anterior, no solo en la lista de contenedores en marcha.
name_conflicts() {
    local name=$1 conflicts=()

    if docker_alive; then
        local containers
        containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${name}(_|-)" || true)"
        [[ -n "$containers" ]] && conflicts+=("contenedores: $(printf '%s' "$containers" | tr '\n' ' ')")

        local stacks
        stacks="$(docker compose ls -a --format json 2>/dev/null | grep -oE "\"Name\":\"${name}\"" || true)"
        [[ -n "$stacks" ]] && conflicts+=("stack de compose: ${name}")

        local volumes
        volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${name}(_|-)" || true)"
        [[ -n "$volumes" ]] && conflicts+=("volumenes: $(printf '%s' "$volumes" | tr '\n' ' ')")
    fi

    [[ -d "${DEPLOYER_BASE_DIR}/${name}" ]] && conflicts+=("directorio: ${DEPLOYER_BASE_DIR}/${name}")

    (( ${#conflicts[@]} )) || return 1
    printf '%s\n' "${conflicts[@]}"
    return 0
}

# Borra todo rastro del despliegue anterior con ese nombre.
destroy_existing() {
    local name=$1 dir="${DEPLOYER_BASE_DIR}/${name}"
    info "Eliminando el despliegue anterior '${name}'..."

    if [[ -f "${dir}/docker-compose.yml" ]]; then
        run bash -c "cd '${dir}' && docker compose down -v --remove-orphans" || true
    else
        # Sin compose.yml solo queda barrer a mano lo que lleve el prefijo.
        local c
        for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${name}(_|-)" || true); do
            run docker rm -f "$c" || true
        done
        local v
        for v in $(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${name}(_|-)" || true); do
            run docker volume rm -f "$v" || true
        done
    fi
    run rm -rf "$dir"
    ok "Despliegue anterior eliminado."
}

phase_project_name() {
    step "Fase 2/10 - Nombre del proyecto"
    hint "Se usara para los contenedores, la red, los volumenes y el directorio en ${DEPLOYER_BASE_DIR}."

    while true; do
        ask PROJECT_NAME "Nombre del proyecto" "" "--name"

        if ! valid_project_name "$PROJECT_NAME"; then
            err "Nombre invalido: '${PROJECT_NAME}'."
            hint "Entre 2 y 31 caracteres: minusculas, numeros, '-' y '_'. Debe empezar por letra o numero."
            (( NONINTERACTIVE )) && exit 1
            PROJECT_NAME=""
            continue
        fi

        local found
        if ! found="$(name_conflicts "$PROJECT_NAME")"; then
            break
        fi

        warn "Ya existe algo con el nombre '${PROJECT_NAME}':"
        # Sin comillas se partiria tambien por los espacios de cada linea.
        printf '%s\n' "$found" | while IFS= read -r line; do
            [[ -n "$line" ]] && printf '        - %s\n' "$line"
        done

        if (( NONINTERACTIVE )); then
            die "Elige otro nombre con --name, o elimina el despliegue anterior."
        fi

        local action=""
        ask_menu action "Que hacemos?" \
            "otro|Usar otro nombre" \
            "recrear|Borrar el despliegue anterior y volver a crearlo (SE PIERDEN LOS DATOS)" \
            "abortar|Cancelar"

        case "$action" in
            otro)    PROJECT_NAME="" ;;
            abortar) info "Cancelado por el usuario."; exit 0 ;;
            recrear)
                if confirm "Seguro? Se borraran los contenedores, los volumenes y ${DEPLOYER_BASE_DIR}/${PROJECT_NAME}" no; then
                    destroy_existing "$PROJECT_NAME"
                    break
                fi
                PROJECT_NAME=""
                ;;
        esac
    done

    PROJECT_DIR="${DEPLOYER_BASE_DIR}/${PROJECT_NAME}"
    APP_DIR="${PROJECT_DIR}/app"
    run mkdir -p "$APP_DIR"
    ROLLBACK_ARMED=1     # a partir de aqui ya hay algo que limpiar si falla

    ok "Proyecto '${PROJECT_NAME}' en ${PROJECT_DIR}"
}

phase_choose_stack() {
    step "Fase 3/10 - Elige el stack"

    ask_menu WEB_ENGINE "Servidor web" \
        "apache|Apache 2.4 con mod_php (la opcion clasica para proyectos PHP)" \
        "nginx|Nginx con PHP-FPM en un contenedor aparte (mas rapido con ficheros estaticos)"

    ask_menu DB_ENGINE "Base de datos" \
        "mariadb|MariaDB 11 (compatible con MySQL, ligera)" \
        "mysql|MySQL 8.0 (Oracle)"

    ask_menu PHP_VERSION "Version de PHP" \
        "8.3|PHP 8.3 - recomendada" \
        "8.2|PHP 8.2" \
        "7.4|PHP 7.4 - proyectos antiguos" \
        "5.6|PHP 5.6 - proyectos muy antiguos con mysql_*"

    case "$PHP_VERSION" in
        7.4|5.6)
            warn "PHP ${PHP_VERSION} no recibe parches de seguridad desde hace anos."
            hint "Usala solo si el proyecto no arranca en PHP 8."
            ;;
    esac

    if [[ -z "$WANT_PMA" ]]; then
        if confirm "Anadir phpMyAdmin para administrar la base desde el navegador?" yes; then
            WANT_PMA=yes
        else
            WANT_PMA=no
        fi
    fi

    ok "Stack: ${WEB_ENGINE} + PHP ${PHP_VERSION} + ${DB_ENGINE}$( [[ "$WANT_PMA" == "yes" ]] && printf ' + phpMyAdmin' )"
}

# ============================================================================
# 60_source.sh - Descarga del proyecto (Git o ZIP) y deteccion del docroot
# ============================================================================

phase_fetch_source() {
    step "Fase 5/10 - Codigo del proyecto"

    if [[ -z "$SOURCE_REPO" && -z "$SOURCE_ZIP" ]]; then
        local origin=""
        ask_menu origin "De donde sacamos el proyecto?" \
            "git|Repositorio Git publico (https://...)" \
            "zip|Archivo ZIP por URL"
        case "$origin" in
            git) ask SOURCE_REPO "URL del repositorio" "" "--repo" ;;
            zip) ask SOURCE_ZIP  "URL del ZIP"         "" "--zip"  ;;
        esac
    fi

    if [[ -n "$SOURCE_REPO" ]]; then
        fetch_from_git
    else
        fetch_from_zip
    fi

    flatten_single_dir
    detect_docroot

    # Solo es un dato informativo: si 'find' tropieza con un directorio sin
    # permisos no tiene sentido abortar un despliegue que ya ha ido bien.
    local files
    files="$(find "$APP_DIR" -type f 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
    ok "Proyecto descargado: ${files:-0} archivos en ${APP_DIR}"
}

fetch_from_git() {
    [[ "$SOURCE_REPO" =~ ^(https?|git):// || "$SOURCE_REPO" =~ ^git@ ]] \
        || die "URL de repositorio no valida: ${SOURCE_REPO}"

    info "Clonando ${SOURCE_REPO}..."
    local tmp="${PROJECT_DIR}/.clone-tmp"
    run rm -rf "$tmp"

    # --depth 1: solo nos interesa el codigo, no la historia. Y sin prompts de
    # credenciales: si el repo es privado preferimos fallar rapido a colgarnos.
    if ! run env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
            git clone --depth 1 --quiet "$SOURCE_REPO" "$tmp"; then
        die "No pude clonar ${SOURCE_REPO}. Comprueba la URL y que el repositorio sea publico."
    fi

    (( DRY_RUN )) && return 0

    rm -rf "${tmp}/.git"
    rm -rf "$APP_DIR"
    mv "$tmp" "$APP_DIR"
}

fetch_from_zip() {
    [[ "$SOURCE_ZIP" =~ ^https?:// ]] || die "URL de ZIP no valida: ${SOURCE_ZIP}"

    info "Descargando ${SOURCE_ZIP}..."
    local zip="${PROJECT_DIR}/.source.zip" tmp="${PROJECT_DIR}/.zip-tmp"
    run rm -rf "$tmp"; run mkdir -p "$tmp"

    run curl -fsSL --retry 3 --max-time 600 -o "$zip" "$SOURCE_ZIP" \
        || die "No pude descargar ${SOURCE_ZIP}"

    run unzip -q -o "$zip" -d "$tmp" || die "El archivo descargado no es un ZIP valido."

    (( DRY_RUN )) && return 0

    rm -f "$zip"
    rm -rf "$APP_DIR"
    mv "$tmp" "$APP_DIR"
}

# Los ZIP de GitHub (y casi cualquier "exportar proyecto") traen todo dentro de
# una unica carpeta. Si la dejamos, el docroot apuntaria a un directorio vacio.
flatten_single_dir() {
    (( DRY_RUN )) && return 0

    local entries
    mapfile -t entries < <(find "$APP_DIR" -mindepth 1 -maxdepth 1)
    if (( ${#entries[@]} == 1 )) && [[ -d "${entries[0]}" ]]; then
        local inner="${entries[0]}"
        info "El proyecto venia dentro de '$(basename "$inner")': subiendo su contenido un nivel."
        local tmp="${PROJECT_DIR}/.flatten-tmp"
        rm -rf "$tmp"
        mv "$inner" "$tmp"
        rmdir "$APP_DIR" 2>/dev/null || rm -rf "$APP_DIR"
        mv "$tmp" "$APP_DIR"
    fi
}

# La raiz publica no siempre es la raiz del repositorio: muchos proyectos meten
# el codigo accesible en public/ o htdocs/ y dejan fuera includes y vendor.
detect_docroot() {
    (( DRY_RUN )) && return 0

    if [[ -n "$DOCROOT" ]]; then
        [[ -d "${APP_DIR}/${DOCROOT}" ]] || die "El docroot indicado no existe: ${APP_DIR}/${DOCROOT}"
        ok "Raiz publica (indicada): ${DOCROOT}"
        return 0
    fi

    if [[ -f "${APP_DIR}/index.php" || -f "${APP_DIR}/index.html" ]]; then
        DOCROOT=""
        ok "Raiz publica: la raiz del proyecto (encontre index.php/index.html)."
        return 0
    fi

    # Buscamos index.php a poca profundidad; mas abajo suele ser codigo interno
    # de librerias o de vendor, no la portada del sitio.
    local candidates=() dir
    while IFS= read -r f; do
        dir="$(dirname "${f#"$APP_DIR"/}")"
        [[ "$dir" == "." ]] && continue
        [[ "$dir" =~ (^|/)(vendor|node_modules|tests?|\.git)(/|$) ]] && continue
        candidates+=("$dir")
    done < <(find "$APP_DIR" -mindepth 2 -maxdepth 3 -name 'index.php' -type f 2>/dev/null | sort)

    # Con el array vacio 'grep -v' no encuentra nada y devuelve 1: no es un
    # error, solo significa que no hay ningun candidato que deduplicar.
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]:-}" | grep -v '^$' | awk '!seen[$0]++' || true)

    if (( ${#candidates[@]} == 0 )); then
        warn "No encontre ningun index.php. Se servira la raiz del proyecto."
        DOCROOT=""
        return 0
    fi

    if (( ${#candidates[@]} == 1 )); then
        DOCROOT="${candidates[0]}"
        ok "Raiz publica detectada: ${DOCROOT}"
        return 0
    fi

    local opts=() c
    for c in "${candidates[@]}"; do
        opts+=("${c}|${c}/index.php")
    done
    opts+=(".|La raiz del proyecto")
    ask_menu DOCROOT "He encontrado varios index.php. Cual es la raiz publica del sitio?" "${opts[@]}"
    [[ "$DOCROOT" == "." ]] && DOCROOT=""
    ok "Raiz publica: ${DOCROOT:-(raiz del proyecto)}"
}

# Se monta el proyecto entero en /var/www/html y el servidor web apunta al
# subdirectorio publico. Montar solo el subdirectorio romperia los proyectos que
# hacen require('../includes/config.php') desde su raiz publica.
container_docroot() {
    if [[ -n "$DOCROOT" ]]; then
        printf '/var/www/html/%s' "$DOCROOT"
    else
        printf '/var/www/html'
    fi
}

# ============================================================================
# 70_dbconfig.sh - Deteccion del archivo de conexion PHP y credenciales
# ============================================================================
#
# La idea: respetar lo que el proyecto ya trae. En vez de imponer credenciales
# nuevas y obligar al usuario a editar su codigo, leemos su archivo de conexion
# y creamos en el motor exactamente ese usuario, esa clave y esa base. Lo unico
# que reescribimos es el host, porque 'localhost' no existe dentro de la red de
# Docker: alli el servicio se llama 'db'.

DB_SERVICE_HOST="db"
DB_HOST_RAW=""

# Ficheros donde suele vivir la configuracion, ordenados por probabilidad.
CONFIG_NAME_PRIORITY="config.php conexion.php connection.php db.php database.php dbconnect.php conectar.php config.inc.php settings.php .env wp-config.php"

phase_db_config() {
    step "Fase 6/10 - Conexion a la base de datos"

    if (( DRY_RUN )); then
        DB_NAME="${DB_NAME:-app_db}"
        DB_USER="${DB_USER:-app_user}"
        DB_PASS="${DB_PASS:-secreto}"
        DB_ROOT_PASS="$(gen_password)"
        hint "[dry-run] Se usarian credenciales de ejemplo."
        return 0
    fi

    local candidates=()
    mapfile -t candidates < <(find_config_candidates)

    if (( ${#candidates[@]} == 0 )); then
        warn "No encontre ningun archivo de conexion dentro del proyecto."
        ask_db_credentials_manually
    else
        choose_config_file "${candidates[@]}"
        parse_config_file "$DB_CONFIG_FILE"
        review_detected_credentials
    fi

    [[ -n "$DB_NAME" && -n "$DB_USER" ]] || die "Faltan datos de conexion a la base de datos."
    DB_ROOT_PASS="$(gen_password)"

    ok "Base '${DB_NAME}', usuario '${DB_USER}', host interno '${DB_SERVICE_HOST}'."
}

gen_password() {
    # openssl esta en practicamente cualquier VPS; /dev/urandom es el respaldo.
    local pw=""
    if command -v openssl >/dev/null 2>&1; then
        # 32 bytes en vez de 24: al quitar '/', '+' y '=' se pierden caracteres
        # y con 24 el resultado podia quedarse corto.
        pw="$(openssl rand -base64 32 2>/dev/null | tr -d '/+=\n' | cut -c1-24 || true)"
    fi
    if (( ${#pw} < 16 )); then
        # 'head -c' cierra la tuberia en cuanto tiene sus 24 bytes y 'tr' muere
        # con SIGPIPE; con pipefail eso cuenta como fallo del script, de ahi el
        # '|| true'. La contrasena ya se ha emitido cuando eso ocurre.
        pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24 || true)"
    fi
    printf '%s' "$pw"
}

# Busca archivos que contengan patrones de conexion a MySQL. Se limita a los
# tipos que pueden llevar credenciales para no recorrer vendor ni imagenes.
find_config_candidates() {
    local hits
    hits="$(grep -rlEi \
        -e 'DB_(HOST|NAME|USER|PASS|PASSWORD|DATABASE)' \
        -e 'mysqli_connect|new[[:space:]]+mysqli|new[[:space:]]+PDO|mysql_connect' \
        --include='*.php' --include='*.inc' --include='*.ini' --include='.env' \
        --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.git \
        "$APP_DIR" 2>/dev/null || true)"

    [[ -n "$hits" ]] || return 0

    # Puntuamos: un nombre conocido pesa mas que el numero de coincidencias, y
    # un archivo poco profundo pesa mas que otro enterrado en subdirectorios.
    local f base score prio matches depth known
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        score=0
        prio=0
        for known in $CONFIG_NAME_PRIORITY; do
            prio=$((prio + 1))
            if [[ "${base,,}" == "$known" ]]; then
                score=$((score + 1000 - prio * 10))
                break
            fi
        done
        # Ojo: 'grep -c' imprime 0 Y devuelve 1 cuando no hay coincidencias, asi
        # que un '|| echo 0' anadiria un segundo cero y romperia la aritmetica.
        matches="$(grep -ciE 'DB_(HOST|NAME|USER|PASS)|mysqli_connect|new[[:space:]]+PDO|mysql_connect' "$f" 2>/dev/null || true)"
        matches="${matches:-0}"
        depth="$(printf '%s' "${f#"$APP_DIR"/}" | tr -cd '/' | wc -c | tr -d '[:space:]')"
        depth="${depth:-0}"
        score=$((score + matches * 5 - depth * 3))
        printf '%s\t%s\n' "$score" "$f"
    done <<< "$hits" | sort -rn -k1,1 | cut -f2- | head -20 || true
}

choose_config_file() {
    local candidates=("$@")

    if (( ${#candidates[@]} == 1 )); then
        DB_CONFIG_FILE="${candidates[0]}"
        ok "Archivo de conexion: ${DB_CONFIG_FILE#"$APP_DIR"/}"
        return 0
    fi

    info "Encontre ${#candidates[@]} archivos que parecen configurar la base de datos."
    local opts=() c
    for c in "${candidates[@]}"; do
        opts+=("${c}|${c#"$APP_DIR"/}")
    done
    ask_menu DB_CONFIG_FILE "Cual es el archivo de conexion del proyecto?" "${opts[@]}"
    ok "Archivo de conexion: ${DB_CONFIG_FILE#"$APP_DIR"/}"
}

# Extrae el valor asociado a una lista de claves probando los cuatro formatos
# que se ven en la practica: define(), variable suelta, clave de array y .env.
extract_value() {
    local file=$1
    shift
    local keys=("$@")
    local key value

    # Cada busqueda lleva '|| true' porque lo habitual es que la clave NO este
    # en ese formato concreto: grep devuelve 1, y sin el guarda 'set -e' daria
    # el proyecto por fallido en vez de probar el formato siguiente.
    for key in "${keys[@]}"; do
        # define('DB_USER', 'valor');
        value="$(grep -ioE "define[[:space:]]*\([[:space:]]*['\"]${key}['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"]" "$file" 2>/dev/null | head -1 | sed -E "s/.*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/" || true)"
        [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }

        # $db_user = 'valor';
        value="$(grep -ioE "[$]${key}[[:space:]]*=[[:space:]]*['\"][^'\"]*['\"]" "$file" 2>/dev/null | head -1 | sed -E "s/.*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/" || true)"
        [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }

        # 'username' => 'valor'
        value="$(grep -ioE "['\"]${key}['\"][[:space:]]*=>[[:space:]]*['\"][^'\"]*['\"]" "$file" 2>/dev/null | head -1 | sed -E "s/.*=>[[:space:]]*['\"]([^'\"]*)['\"].*/\1/" || true)"
        [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }

        # DB_USER=valor   (formato .env, con o sin comillas)
        value="$(grep -iE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1 | sed -E "s/^[^=]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"][[:space:]]*$//" || true)"
        [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
    done
    return 0
}

# Proyectos sencillos conectan con argumentos posicionales, sin nombres de clave.
extract_from_function_call() {
    local file=$1
    local call args

    call="$(grep -oE "(mysqli_connect|new[[:space:]]+mysqli)[[:space:]]*\([^)]*\)" "$file" 2>/dev/null | head -1 || true)"
    if [[ -n "$call" ]]; then
        mapfile -t args < <(printf '%s' "$call" | grep -oE "['\"][^'\"]*['\"]" | sed -E "s/^['\"]//; s/['\"]$//" || true)
        [[ -z "$DB_HOST_RAW" && -n "${args[0]:-}" ]] && DB_HOST_RAW="${args[0]}"
        [[ -z "$DB_USER"     && -n "${args[1]:-}" ]] && DB_USER="${args[1]}"
        [[ -z "$DB_PASS"     && -n "${args[2]:-}" ]] && DB_PASS="${args[2]}"
        [[ -z "$DB_NAME"     && -n "${args[3]:-}" ]] && DB_NAME="${args[3]}"
    fi

    # new PDO("mysql:host=X;dbname=Y", "usuario", "clave"): el DSN va primero y
    # el usuario y la clave detras, tambien posicionales.
    local pdo
    pdo="$(grep -oE "new[[:space:]]+PDO[[:space:]]*\([^)]*\)" "$file" 2>/dev/null | head -1 || true)"
    if [[ -n "$pdo" ]]; then
        mapfile -t args < <(printf '%s' "$pdo" | grep -oE "['\"][^'\"]*['\"]" | sed -E "s/^['\"]//; s/['\"]$//" || true)
        [[ -z "$DB_USER" && -n "${args[1]:-}" ]] && DB_USER="${args[1]}"
        [[ -z "$DB_PASS" && -n "${args[2]:-}" ]] && DB_PASS="${args[2]}"
    fi

    local dsn
    dsn="$(grep -oE "mysql:host=[^'\"]*" "$file" 2>/dev/null | head -1 || true)"
    if [[ -n "$dsn" ]]; then
        [[ -z "$DB_HOST_RAW" ]] && DB_HOST_RAW="$(printf '%s' "$dsn" | sed -E 's/^mysql:host=([^;]*).*/\1/')"
        if [[ -z "$DB_NAME" && "$dsn" == *dbname=* ]]; then
            DB_NAME="$(printf '%s' "$dsn" | sed -E 's/.*dbname=([^;]*).*/\1/')"
        fi
    fi
    return 0
}

parse_config_file() {
    local file=$1
    DB_HOST_RAW=""; DB_NAME=""; DB_USER=""; DB_PASS=""

    DB_HOST_RAW="$(extract_value "$file" DB_HOST DB_SERVER DBHOST db_host dbhost servername hostname host)"
    DB_NAME="$(extract_value "$file"     DB_NAME DB_DATABASE DBNAME db_name dbname database)"
    DB_USER="$(extract_value "$file"     DB_USER DB_USERNAME DBUSER db_user dbuser username user)"
    DB_PASS="$(extract_value "$file"     DB_PASS DB_PASSWORD DBPASS db_pass dbpass password passwd pass)"

    # Si las claves con nombre no dieron nada, probamos las llamadas posicionales.
    extract_from_function_call "$file"
}

mask() {
    local v=$1
    [[ -z "$v" ]] && { printf '(vacia)'; return 0; }
    printf '%s' "${v:0:1}"
    printf '%*s' $(( ${#v} - 1 )) '' | tr ' ' '*'
}

host_is_local() {
    # Se descarta un posible ":3306" pegado al host.
    local h="${1%%:*}"
    # Sin host detectado asumimos local: es lo que hace PHP por defecto.
    [[ -z "$h" ]] && return 0
    # Ojo: una alternativa vacia dentro de (...) no compila en la regex de
    # bash, por eso el caso vacio se resuelve arriba y no dentro del patron.
    [[ "$h" =~ ^(localhost|127\.0\.0\.1|::1)$ ]]
}

review_detected_credentials() {
    printf '\n    %sDatos leidos de %s%s\n' "$C_BOLD" "${DB_CONFIG_FILE#"$APP_DIR"/}" "$C_RESET"
    printf '      DB_HOST = %s' "${DB_HOST_RAW:-(no encontrado)}"
    if host_is_local "$DB_HOST_RAW"; then
        printf '   %s-> se reescribira a "%s"%s' "$C_DIM" "$DB_SERVICE_HOST" "$C_RESET"
    fi
    printf '\n'
    printf '      DB_NAME = %s\n' "${DB_NAME:-(no encontrado)}"
    printf '      DB_USER = %s\n' "${DB_USER:-(no encontrado)}"
    printf '      DB_PASS = %s\n\n' "$(mask "$DB_PASS")"

    if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
        warn "Faltan datos obligatorios en el archivo: hay que completarlos a mano."
        ask_db_credentials_manually
        return 0
    fi

    if (( ASSUME_YES )) || (( NONINTERACTIVE )); then
        rewrite_config_host
        return 0
    fi

    local action=""
    ask_menu action "Que hacemos con estos datos?" \
        "confirmar|Correcto: crear esta base y este usuario en ${DB_ENGINE}" \
        "editar|Corregir los valores a mano" \
        "saltar|No tocar el archivo y escribir yo los datos de la base"

    case "$action" in
        confirmar)
            rewrite_config_host
            ;;
        editar)
            DB_NAME=""; DB_USER=""; DB_PASS=""
            ask DB_NAME "Nombre de la base de datos"
            ask DB_USER "Usuario"
            ask_secret DB_PASS "Contrasena (enter = generar una)"
            [[ -z "$DB_PASS" ]] && { DB_PASS="$(gen_password)"; info "Contrasena generada."; }
            write_credentials_into_config
            ;;
        saltar)
            DB_CONFIG_FILE=""
            ask_db_credentials_manually
            ;;
    esac
    return 0
}

ask_db_credentials_manually() {
    hint "Estos datos deben coincidir con los que use tu codigo PHP para conectar."
    DB_NAME=""; DB_USER=""; DB_PASS=""
    ask DB_NAME "Nombre de la base de datos" "${PROJECT_NAME}_db"
    ask DB_USER "Usuario de la base de datos" "${PROJECT_NAME}_user"
    ask_secret DB_PASS "Contrasena (enter = generar una)"
    if [[ -z "$DB_PASS" ]]; then
        DB_PASS="$(gen_password)"
        info "Contrasena generada automaticamente (aparecera en el resumen final)."
    fi
    [[ -n "$DB_CONFIG_FILE" ]] && write_credentials_into_config
    return 0
}

backup_config() {
    local f=$1
    [[ -f "${f}.deployer.bak" ]] || cp -p "$f" "${f}.deployer.bak"
}

# Reescritura minima: solo el host. Usuario, clave y nombre de la base se
# respetan tal cual y se crean en el motor con esos mismos valores.
rewrite_config_host() {
    [[ -n "$DB_CONFIG_FILE" && -f "$DB_CONFIG_FILE" ]] || return 0

    if ! host_is_local "$DB_HOST_RAW"; then
        info "El host de la configuracion (${DB_HOST_RAW}) no es local: se deja como esta."
        return 0
    fi

    backup_config "$DB_CONFIG_FILE"
    local h="${DB_HOST_RAW:-localhost}"

    sed -i -E \
        -e "s/(define[[:space:]]*\([[:space:]]*['\"](DB_HOST|DB_SERVER|DBHOST)['\"][[:space:]]*,[[:space:]]*['\"])[^'\"]*(['\"])/\1${DB_SERVICE_HOST}\3/Ig" \
        -e "s/([$](db_host|dbhost|host|servername|hostname)[[:space:]]*=[[:space:]]*['\"])[^'\"]*(['\"])/\1${DB_SERVICE_HOST}\3/Ig" \
        -e "s/(['\"](host|hostname|db_host)['\"][[:space:]]*=>[[:space:]]*['\"])[^'\"]*(['\"])/\1${DB_SERVICE_HOST}\3/Ig" \
        -e "s/(mysql:host=)[^;'\"]*/\1${DB_SERVICE_HOST}/Ig" \
        -e "s/^([[:space:]]*DB_HOST[[:space:]]*=[[:space:]]*)[^#]*$/\1${DB_SERVICE_HOST}/Ig" \
        "$DB_CONFIG_FILE"

    # mysqli_connect("localhost", ...) es posicional: no lleva nombre de clave.
    sed -i -E \
        -e "s/((mysqli_connect|new[[:space:]]+mysqli)[[:space:]]*\([[:space:]]*['\"])(localhost|127\.0\.0\.1)(['\"])/\1${DB_SERVICE_HOST}\4/Ig" \
        "$DB_CONFIG_FILE"

    ok "Host reescrito de '${h}' a '${DB_SERVICE_HOST}' (copia en ${DB_CONFIG_FILE##*/}.deployer.bak)."
}

# Cuando el usuario cambia las credenciales a mano hay que llevarlas tambien al
# archivo del proyecto, o el codigo seguiria intentando entrar con las viejas.
write_credentials_into_config() {
    [[ -n "$DB_CONFIG_FILE" && -f "$DB_CONFIG_FILE" ]] || return 0

    if ! confirm "Escribir estos datos en ${DB_CONFIG_FILE#"$APP_DIR"/}?" yes; then
        warn "El archivo no se toca: recuerda ajustarlo tu para que la conexion funcione."
        return 0
    fi

    backup_config "$DB_CONFIG_FILE"
    # Escapamos las barras porque van dentro de una sustitucion de sed.
    local n="${DB_NAME//\//\\/}" u="${DB_USER//\//\\/}" p="${DB_PASS//\//\\/}"

    sed -i -E \
        -e "s/(define[[:space:]]*\([[:space:]]*['\"](DB_NAME|DB_DATABASE|DBNAME)['\"][[:space:]]*,[[:space:]]*['\"])[^'\"]*(['\"])/\1${n}\3/Ig" \
        -e "s/(define[[:space:]]*\([[:space:]]*['\"](DB_USER|DB_USERNAME|DBUSER)['\"][[:space:]]*,[[:space:]]*['\"])[^'\"]*(['\"])/\1${u}\3/Ig" \
        -e "s/(define[[:space:]]*\([[:space:]]*['\"](DB_PASS|DB_PASSWORD|DBPASS)['\"][[:space:]]*,[[:space:]]*['\"])[^'\"]*(['\"])/\1${p}\3/Ig" \
        -e "s/([$](db_name|dbname|database)[[:space:]]*=[[:space:]]*['\"])[^'\"]*(['\"])/\1${n}\3/Ig" \
        -e "s/([$](db_user|dbuser|username|user)[[:space:]]*=[[:space:]]*['\"])[^'\"]*(['\"])/\1${u}\3/Ig" \
        -e "s/([$](db_pass|dbpass|password|passwd|pass)[[:space:]]*=[[:space:]]*['\"])[^'\"]*(['\"])/\1${p}\3/Ig" \
        "$DB_CONFIG_FILE"

    rewrite_config_host
    ok "Credenciales escritas en ${DB_CONFIG_FILE#"$APP_DIR"/}."
}

# ============================================================================
# 80_templates.sh - Generacion de docker-compose.yml, Dockerfile y configs
# ============================================================================

DB_BIND_ADDR="127.0.0.1"

db_image() {
    case "$DB_ENGINE" in
        mysql)   printf 'mysql:8.0' ;;
        mariadb) printf 'mariadb:11' ;;
    esac
}

# El cliente de linea de comandos cambia de nombre entre motores y versiones.
db_ping_cmd() {
    case "$DB_ENGINE" in
        mysql)   printf 'mysqladmin ping -h 127.0.0.1 -u root -p"$$MYSQL_ROOT_PASSWORD"' ;;
        mariadb) printf 'healthcheck.sh --connect --innodb_initialized' ;;
    esac
}

# Escapa un valor para meterlo en un docker-compose.yml. Hacen falta dos cosas,
# y olvidar cualquiera de ellas corrompe claves perfectamente validas:
#
#   1. Compose interpola $VAR y ${VAR} en el archivo ANTES de parsear el YAML,
#      asi que un '$' literal tiene que escribirse '$$'. Las comillas simples de
#      YAML no protegen de esto, porque la interpolacion ocurre antes.
#   2. Dentro de un escalar entrecomillado simple, una comilla se duplica.
yaml_quote() {
    local v=$1
    v="${v//\$/\$\$}"
    v="${v//\'/\'\'}"
    printf "'%s'" "$v"
}

phase_generate_files() {
    step "Fase 7/10 - Generando la configuracion de Docker"

    if [[ "$WEB_ENGINE" == "nginx" ]] || [[ "$WANT_PMA" == "yes" ]]; then
        run mkdir -p "${PROJECT_DIR}/nginx"
    fi

    ask_db_exposure
    write_env_file
    write_dockerfile
    [[ "$WEB_ENGINE" == "nginx" ]] && write_nginx_conf
    write_compose_file
    write_manage_script

    ok "Configuracion generada en ${PROJECT_DIR}"
}

# Publicar MySQL en 0.0.0.0 deja la base expuesta a todo internet. Por defecto
# la atamos al loopback: el contenedor web entra por la red interna de Docker,
# que no pasa por el puerto publicado.
ask_db_exposure() {
    if (( NONINTERACTIVE )) || (( ASSUME_YES )); then
        DB_BIND_ADDR="127.0.0.1"
        return 0
    fi
    printf '\n'
    hint "El contenedor web conecta con la base por la red interna de Docker."
    hint "Publicar el puerto ${PORT_DB} hacia fuera solo hace falta para conectar"
    hint "con un cliente externo (Workbench, HeidiSQL, DBeaver...)."
    if confirm "Permitir conexiones a la base desde fuera del servidor?" no; then
        DB_BIND_ADDR="0.0.0.0"
        warn "La base quedara accesible desde internet en el puerto ${PORT_DB}."
    else
        DB_BIND_ADDR="127.0.0.1"
        hint "La base solo escuchara en 127.0.0.1:${PORT_DB} (accesible por tunel SSH)."
    fi
}

write_env_file() {
    local f="${PROJECT_DIR}/.env"
    (( DRY_RUN )) && { hint "[dry-run] Se escribiria ${f}"; return 0; }

    # Solo para manage.sh y para consulta: el compose lleva los valores
    # literales, asi no dependemos de como interprete .env los caracteres raros.
    {
        printf '# Generado por deployer v%s el %s\n' "$DEPLOYER_VERSION" "$(date -u '+%Y-%m-%d %H:%M UTC')"
        printf '# Contiene credenciales: no lo subas a ningun repositorio.\n'
        printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT_NAME"
        printf 'PROJECT_NAME=%s\n'   "$PROJECT_NAME"
        printf 'WEB_ENGINE=%s\n'     "$WEB_ENGINE"
        printf 'DB_ENGINE=%s\n'      "$DB_ENGINE"
        printf 'PHP_VERSION=%s\n'    "$PHP_VERSION"
        printf 'DOCROOT=%s\n'        "$DOCROOT"
        printf 'PORT_HTTP=%s\n'      "$PORT_HTTP"
        printf 'PORT_DB=%s\n'        "$PORT_DB"
        printf 'PORT_PMA=%s\n'       "${PORT_PMA:-}"
        printf 'DB_NAME=%q\n'        "$DB_NAME"
        printf 'DB_USER=%q\n'        "$DB_USER"
        printf 'DB_PASS=%q\n'        "$DB_PASS"
        printf 'DB_ROOT_PASS=%q\n'   "$DB_ROOT_PASS"
    } > "$f"
    chmod 600 "$f"
}

# --- Dockerfile del contenedor web ------------------------------------------

# Las imagenes de PHP 7.4 y 5.6 estan sobre versiones de Debian ya archivadas:
# su apt-get update falla porque los repositorios se movieron a archive.debian.org.
php_needs_archive_repos() {
    [[ "$PHP_VERSION" == "7.4" || "$PHP_VERSION" == "5.6" ]]
}

# Los paquetes de desarrollo y los flags de gd cambiaron en PHP 7.4.
# La imagen de PHP 5.6 esta sobre Debian 9 (stretch), no sobre jessie: alli el
# paquete de png ya es libpng-dev (libpng16), y libpng12-dev no existe.
php_build_deps() {
    if [[ "$PHP_VERSION" == "5.6" ]]; then
        printf 'libpng-dev libjpeg-dev libfreetype6-dev zlib1g-dev'
    else
        printf 'libpng-dev libjpeg-dev libfreetype6-dev libzip-dev libicu-dev libonig-dev'
    fi
}

# En Debian 9 (stretch), la base de la imagen de PHP 5.6, el cliente se sigue
# llamando mysql-client; default-mysql-client llego despues.
php_mysql_client_pkg() {
    if [[ "$PHP_VERSION" == "5.6" ]]; then
        printf 'mysql-client'
    else
        printf 'default-mysql-client'
    fi
}

php_gd_configure() {
    if [[ "$PHP_VERSION" == "5.6" ]]; then
        printf 'docker-php-ext-configure gd --with-freetype-dir=/usr/include/ --with-jpeg-dir=/usr/include/'
    else
        printf 'docker-php-ext-configure gd --with-freetype --with-jpeg'
    fi
}

php_extensions() {
    if [[ "$PHP_VERSION" == "5.6" ]]; then
        # mysql_* solo existe hasta PHP 5.6, y es justo el motivo de elegirla.
        printf 'mysql mysqli pdo_mysql gd zip mbstring'
    else
        printf 'mysqli pdo_mysql gd zip intl mbstring opcache'
    fi
}

write_dockerfile() {
    local f="${PROJECT_DIR}/Dockerfile"
    (( DRY_RUN )) && { hint "[dry-run] Se escribiria ${f}"; return 0; }

    local base_tag="apache"
    [[ "$WEB_ENGINE" == "nginx" ]] && base_tag="fpm"

    {
        printf '# Generado por deployer: imagen web del proyecto %s\n' "$PROJECT_NAME"
        printf 'FROM php:%s-%s\n\n' "$PHP_VERSION" "$base_tag"

        if php_needs_archive_repos; then
            printf '# Repositorios de una version de Debian que puede estar ya archivada.\n'
            printf '# No se da por hecho: se prueba el original y solo si falla se cambia a\n'
            printf '# archive.debian.org. Bullseye (PHP 7.4) todavia responde hoy y dejara de\n'
            printf '# hacerlo mas adelante; asi la imagen sigue construyendose igual.\n'
            printf 'RUN set -eux; \\\n'
            printf '    if ! apt-get update -q; then \\\n'
            printf '        sed -i -e "s|deb.debian.org|archive.debian.org|g" \\\n'
            printf '               -e "s|security.debian.org|archive.debian.org|g" \\\n'
            printf '               -e "/stretch-updates/d" -e "/buster-updates/d" \\\n'
            printf '               -e "/jessie-updates/d" -e "/bullseye-updates/d" \\\n'
            printf '               -e "s|^deb |deb [trusted=yes] |" \\\n'
            printf '               /etc/apt/sources.list; \\\n'
            printf '        echo "Acquire::Check-Valid-Until false;" > /etc/apt/apt.conf.d/99no-check-valid; \\\n'
            printf '        apt-get update; \\\n'
            printf '    fi\n\n'
        fi

        printf '# Dependencias de compilacion de las extensiones de PHP.\n'
        printf 'RUN set -eux; \\\n'
        printf '    apt-get update; \\\n'
        printf '    apt-get install -y --no-install-recommends %s %s unzip; \\\n' "$(php_build_deps)" "$(php_mysql_client_pkg)"
        printf '    %s; \\\n' "$(php_gd_configure)"
        printf '    docker-php-ext-install -j"$(nproc)" %s; \\\n' "$(php_extensions)"
        printf '    rm -rf /var/lib/apt/lists/*\n\n'

        if [[ "$WEB_ENGINE" == "apache" ]]; then
            printf '# .htaccess y URLs amigables: sin esto casi ningun framework enruta.\n'
            printf 'RUN a2enmod rewrite headers\n\n'
            printf 'ENV APACHE_DOCUMENT_ROOT=%s\n' "$(container_docroot)"
            printf 'RUN set -eux; \\\n'
            printf '    sed -ri -e "s!/var/www/html!${APACHE_DOCUMENT_ROOT}!g" /etc/apache2/sites-available/*.conf; \\\n'
            printf '    sed -ri -e "s!/var/www/!${APACHE_DOCUMENT_ROOT}!g" /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf; \\\n'
            printf '    printf "<Directory %%s>\\\\n    AllowOverride All\\\\n    Require all granted\\\\n</Directory>\\\\n" "${APACHE_DOCUMENT_ROOT}" > /etc/apache2/conf-available/docroot.conf; \\\n'
            printf '    a2enconf docroot\n\n'
        fi

        printf '# Subidas de archivos con un limite util para importar o subir imagenes.\n'
        printf 'RUN { \\\n'
        printf '      echo "upload_max_filesize=64M"; \\\n'
        printf '      echo "post_max_size=64M"; \\\n'
        printf '      echo "memory_limit=256M"; \\\n'
        printf '      echo "max_execution_time=300"; \\\n'
        printf '    } > /usr/local/etc/php/conf.d/zz-deployer.ini\n\n'

        printf 'WORKDIR /var/www/html\n'
    } > "$f"
}

write_nginx_conf() {
    local f="${PROJECT_DIR}/nginx/default.conf"
    (( DRY_RUN )) && { hint "[dry-run] Se escribiria ${f}"; return 0; }
    local root; root="$(container_docroot)"

    cat > "$f" <<NGINXCONF
# Generado por deployer para el proyecto ${PROJECT_NAME}
server {
    listen 80;
    server_name _;
    root ${root};
    index index.php index.html index.htm;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        # 'php' es el nombre del servicio de PHP-FPM en el docker-compose.
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout 300;
    }

    # Los archivos de configuracion y los volcados no deben servirse nunca.
    location ~* \.(sql|sql\.gz|env|bak|deployer\.bak|log)\$ {
        deny all;
        return 404;
    }
    location ~ /\.(?!well-known) {
        deny all;
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}
NGINXCONF
}

# --- docker-compose.yml ------------------------------------------------------

write_compose_file() {
    local f="${PROJECT_DIR}/docker-compose.yml"
    (( DRY_RUN )) && { hint "[dry-run] Se escribiria ${f}"; return 0; }

    local m="$MOUNT_SUFFIX"          # ":Z" bajo SELinux, vacio en el resto
    local img; img="$(db_image)"
    local qname qusr qpass qroot
    qname="$(yaml_quote "$DB_NAME")"
    qusr="$(yaml_quote "$DB_USER")"
    qpass="$(yaml_quote "$DB_PASS")"
    qroot="$(yaml_quote "$DB_ROOT_PASS")"

    {
        printf '# Generado por deployer v%s - proyecto %s\n' "$DEPLOYER_VERSION" "$PROJECT_NAME"
        printf '# Regenerar con deploy.sh; los cambios a mano se pierden al redesplegar.\n\n'
        printf 'name: %s\n\n' "$PROJECT_NAME"
        printf 'services:\n\n'

        # --- servicio web ---
        printf '  web:\n'
        if [[ "$WEB_ENGINE" == "apache" ]]; then
            printf '    build:\n      context: .\n      dockerfile: Dockerfile\n'
            printf '    image: %s-web:latest\n' "$PROJECT_NAME"
            printf '    container_name: %s_web\n' "$PROJECT_NAME"
            printf '    restart: unless-stopped\n'
            printf '    ports:\n      - "%s:80"\n' "$PORT_HTTP"
            printf '    volumes:\n'
            printf '      - ./app:/var/www/html%s\n' "$m"
            printf '      - weblogs:/var/log/apache2\n'
            printf '    depends_on:\n      db:\n        condition: service_healthy\n'
            printf '    healthcheck:\n'
            printf '      test:\n        - CMD-SHELL\n        - apache2ctl -t >/dev/null 2>&1 || exit 1\n'
            printf '      interval: 10s\n      timeout: 5s\n      retries: 10\n      start_period: 20s\n'
            printf '    networks: [appnet]\n\n'
        else
            printf '    image: nginx:alpine\n'
            printf '    container_name: %s_web\n' "$PROJECT_NAME"
            printf '    restart: unless-stopped\n'
            printf '    ports:\n      - "%s:80"\n' "$PORT_HTTP"
            printf '    volumes:\n'
            # Nginx sirve los estaticos, asi que necesita ver los mismos
            # archivos que PHP-FPM: el bind se monta en los dos contenedores.
            printf '      - ./app:/var/www/html%s\n' "$m"
            printf '      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro%s\n' "${m/:Z/,Z}"
            printf '      - weblogs:/var/log/nginx\n'
            printf '    depends_on:\n      php:\n        condition: service_started\n      db:\n        condition: service_healthy\n'
            printf '    healthcheck:\n'
            printf '      test:\n        - CMD-SHELL\n        - nginx -t >/dev/null 2>&1 || exit 1\n'
            printf '      interval: 10s\n      timeout: 5s\n      retries: 10\n      start_period: 15s\n'
            printf '    networks: [appnet]\n\n'

            # --- servicio php-fpm (solo con nginx) ---
            printf '  php:\n'
            printf '    build:\n      context: .\n      dockerfile: Dockerfile\n'
            printf '    image: %s-php:latest\n' "$PROJECT_NAME"
            printf '    container_name: %s_php\n' "$PROJECT_NAME"
            printf '    restart: unless-stopped\n'
            printf '    volumes:\n      - ./app:/var/www/html%s\n' "$m"
            printf '    depends_on:\n      db:\n        condition: service_healthy\n'
            printf '    healthcheck:\n'
            printf '      test:\n        - CMD-SHELL\n        - php -v >/dev/null 2>&1 || exit 1\n'
            printf '      interval: 10s\n      timeout: 5s\n      retries: 10\n      start_period: 15s\n'
            printf '    networks: [appnet]\n\n'
        fi

        # --- servicio de base de datos ---
        printf '  db:\n'
        printf '    image: %s\n' "$img"
        printf '    container_name: %s_db\n' "$PROJECT_NAME"
        printf '    restart: unless-stopped\n'
        printf '    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci\n'
        printf '    environment:\n'
        printf '      MYSQL_ROOT_PASSWORD: %s\n' "$qroot"
        printf '      MYSQL_DATABASE: %s\n'      "$qname"
        printf '      MYSQL_USER: %s\n'          "$qusr"
        printf '      MYSQL_PASSWORD: %s\n'      "$qpass"
        printf '    ports:\n      - "%s:%s:3306"\n' "$DB_BIND_ADDR" "$PORT_DB"
        printf '    volumes:\n'
        printf '      - dbdata:/var/lib/mysql\n'
        printf '    healthcheck:\n'
        printf '      test:\n        - CMD-SHELL\n        - %s\n' "$(db_ping_cmd)"
        printf '      interval: 10s\n      timeout: 5s\n      retries: 20\n      start_period: 40s\n'
        printf '    networks: [appnet]\n\n'

        # --- phpMyAdmin ---
        if [[ "$WANT_PMA" == "yes" ]]; then
            printf '  pma:\n'
            printf '    image: phpmyadmin:latest\n'
            printf '    container_name: %s_pma\n' "$PROJECT_NAME"
            printf '    restart: unless-stopped\n'
            printf '    environment:\n'
            printf '      PMA_HOST: db\n'
            printf '      PMA_PORT: "3306"\n'
            printf '      UPLOAD_LIMIT: 256M\n'
            printf '    ports:\n      - "%s:80"\n' "$PORT_PMA"
            printf '    depends_on:\n      db:\n        condition: service_healthy\n'
            printf '    networks: [appnet]\n\n'
        fi

        # Volumenes con nombre: sobreviven a docker compose down y a un reinicio
        # del servidor, que es justo lo que hace falta para no perder la base.
        printf 'volumes:\n'
        printf '  dbdata:\n    name: %s_dbdata\n' "$PROJECT_NAME"
        printf '  weblogs:\n    name: %s_weblogs\n\n' "$PROJECT_NAME"

        printf 'networks:\n'
        printf '  appnet:\n    name: %s_net\n' "$PROJECT_NAME"
    } > "$f"
    chmod 600 "$f"
}

# --- manage.sh ---------------------------------------------------------------

write_manage_script() {
    local f="${PROJECT_DIR}/manage.sh"
    (( DRY_RUN )) && { hint "[dry-run] Se escribiria ${f}"; return 0; }

    cat > "$f" <<'MANAGE'
#!/usr/bin/env bash
# Gestion del despliegue. Generado por deployer: se puede editar sin problema.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1091
source ./.env

usage() {
    cat <<USAGE
Uso: ./manage.sh <comando>

  start      Levantar los contenedores
  stop       Pararlos (los datos se conservan en los volumenes)
  restart    Pararlos y volver a levantarlos
  rebuild    Reconstruir la imagen web y levantar
  status     Estado de los contenedores
  logs [srv] Ver logs en vivo (web, php, db, pma)
  shell      Abrir una shell en el contenedor web
  db         Abrir el cliente de la base de datos como root
  backup     Volcar la base a ./backups/
  restore F  Restaurar un volcado sobre la base
  urls       Mostrar las direcciones de acceso
  destroy    Borrar contenedores Y VOLUMENES (se pierden los datos)
USAGE
}

php_service() { [[ "$WEB_ENGINE" == "nginx" ]] && echo php || echo web; }

case "${1:-}" in
    start)   docker compose up -d ;;
    stop)    docker compose stop ;;
    restart) docker compose restart ;;
    rebuild) docker compose up -d --build ;;
    status)  docker compose ps ;;
    logs)    docker compose logs -f --tail 100 ${2:+"$2"} ;;
    shell)   docker compose exec "$(php_service)" bash ;;
    db)      docker compose exec db sh -c 'exec "$(command -v mariadb || command -v mysql)" -uroot -p"$MYSQL_ROOT_PASSWORD"' ;;
    backup)
        mkdir -p backups
        out="backups/${DB_NAME}-$(date +%Y%m%d-%H%M%S).sql.gz"
        docker compose exec -T db sh -c \
            "exec \"\$(command -v mariadb-dump || command -v mysqldump)\" -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --routines '${DB_NAME}'" \
            | gzip > "$out"
        echo "Copia guardada en $out"
        ;;
    restore)
        file="${2:?Indica el archivo a restaurar}"
        [[ -f "$file" ]] || { echo "No existe: $file" >&2; exit 1; }
        read -rp "Esto sobrescribe la base '${DB_NAME}'. Continuar? [s/N]: " a
        [[ "${a,,}" == "s" ]] || exit 0
        if [[ "$file" == *.gz ]]; then
            gunzip -c "$file" | docker compose exec -T db sh -c "exec \"\$(command -v mariadb || command -v mysql)\" -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '${DB_NAME}'"
        else
            docker compose exec -T db sh -c "exec \"\$(command -v mariadb || command -v mysql)\" -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '${DB_NAME}'" < "$file"
        fi
        echo "Restaurado."
        ;;
    urls)    [[ -f RESUMEN.txt ]] && cat RESUMEN.txt || echo "http://localhost:${PORT_HTTP}" ;;
    destroy)
        read -rp "Se borraran los contenedores y TODOS LOS DATOS. Escribe el nombre del proyecto para confirmar: " a
        [[ "$a" == "$PROJECT_NAME" ]] || { echo "Cancelado."; exit 0; }
        docker compose down -v --remove-orphans
        echo "Eliminado. El codigo sigue en ./app"
        ;;
    *) usage; exit 1 ;;
esac
MANAGE
    chmod +x "$f"
}

# ============================================================================
# 90_verify.sh - Arranque de los contenedores y verificacion de los servicios
# ============================================================================

# Atajo para no repetir el cambio de directorio en cada llamada a compose.
dc() {
    (cd "$PROJECT_DIR" && docker compose "$@")
}

# Ejecuta un comando dentro de un servicio, sin TTY (para poder capturar salida).
dexec() {
    local svc=$1; shift
    # Sin '< /dev/null' el comando de dentro se queda con la entrada estandar.
    # En un 'curl | bash' esa entrada es el propio script todavia sin leer.
    dc exec -T "$svc" "$@" < /dev/null
}

# Comprueba que un proceso corre dentro de un servicio SIN depender de lo que
# traiga la imagen: 'docker top' lee la tabla de procesos desde el host. En las
# imagenes oficiales no se puede contar con 'pgrep': php:*-fpm no lo incluye, y
# el de busybox (nginx:alpine) compara con la linea de comandos completa, asi
# que 'pgrep -x nginx' no encuentra 'nginx: master process ...'.
service_process() {
    local svc=$1 pattern=$2 cid out
    cid="$(dc ps -q "$svc" 2>/dev/null)" || return 1
    [[ -n "$cid" ]] || return 1
    # La tabla se guarda entera en vez de filtrarla con una tuberia: 'grep -q'
    # cierra la salida en cuanto encuentra la linea, 'docker top' muere con
    # SIGPIPE y con 'pipefail' la comprobacion falla a ratos aunque el proceso
    # este perfectamente vivo.
    out="$(docker top "$cid" 2>/dev/null)" || return 1
    [[ "$out" == *"$pattern"* ]]
}

php_service_name() {
    [[ "$WEB_ENGINE" == "nginx" ]] && printf 'php' || printf 'web'
}

phase_start_and_verify() {
    step "Fase 8/10 - Levantando el ecosistema"

    if (( DRY_RUN )); then
        hint "[dry-run] Se ejecutaria: docker compose up -d --build"
        return 0
    fi

    info "Construyendo la imagen de PHP ${PHP_VERSION} y descargando ${DB_ENGINE}."
    hint "La primera vez tarda unos minutos: se bajan las imagenes base."

    if ! dc up -d --build; then
        err "Fallo al levantar los contenedores. Ultimas lineas del log:"
        dc logs --tail 40 || true
        die "Revisa el error de arriba. El proyecto esta en ${PROJECT_DIR}."
    fi

    wait_for_healthy
    verify_services
}

# Esperamos al estado 'healthy' que declara el compose, no a un sleep fijo:
# la base tarda mucho mas la primera vez porque inicializa el datadir.
wait_for_healthy() {
    local svc
    local services=(db)
    [[ "$WEB_ENGINE" == "nginx" ]] && services+=(php)
    services+=(web)

    for svc in "${services[@]}"; do
        if ! wait_for "Esperando a que '${svc}' este listo" 180 service_healthy "$svc"; then
            err "El servicio '${svc}' no llego a estar operativo."
            dc logs --tail 40 "$svc" || true
            die "El despliegue no puede continuar."
        fi
    done
}

service_healthy() {
    local svc=$1 cid state health
    cid="$(dc ps -q "$svc" 2>/dev/null)" || return 1
    [[ -n "$cid" ]] || return 1

    state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" || return 1
    [[ "$state" == "running" ]] || return 1

    # Sin healthcheck definido nos conformamos con que este corriendo.
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)" || return 1
    [[ "$health" == "healthy" || "$health" == "none" ]]
}

# El healthcheck dice que el contenedor arranco; esto comprueba que el servicio
# de dentro responde de verdad, que es lo que pidio el usuario.
verify_services() {
    step "Comprobando los servicios dentro de los contenedores"
    local failed=0

    case "$WEB_ENGINE" in
        apache)
            check "Configuracion de Apache" dexec web apache2ctl -t || failed=1
            check "Proceso apache2 en marcha" service_process web apache2 || failed=1
            check "PHP ${PHP_VERSION} operativo" dexec web php -v || failed=1
            ;;
        nginx)
            check "Configuracion de Nginx" dexec web nginx -t || failed=1
            check "Proceso nginx en marcha" service_process web nginx || failed=1
            check "Proceso php-fpm en marcha" service_process php php-fpm || failed=1
            check "PHP ${PHP_VERSION} operativo" dexec php php -v || failed=1
            ;;
    esac

    check "Base de datos respondiendo" db_query "SELECT 1" || failed=1

    if [[ "$WANT_PMA" == "yes" ]]; then
        check "phpMyAdmin en marcha" service_healthy pma || warn "phpMyAdmin no responde todavia."
    fi

    # Que mysqli este cargada es lo que decide si el proyecto PHP conectara.
    if ! dexec "$(php_service_name)" php -m 2>/dev/null | grep -qi '^mysqli$'; then
        warn "La extension mysqli no aparece cargada: revisa el Dockerfile."
        failed=1
    fi

    (( failed == 0 )) || die "Hay servicios que no estan operativos. Revisa: cd ${PROJECT_DIR} && docker compose logs"
    ok "Todos los servicios responden."
}

check() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then
        printf '    %s[ok]%s   %s\n' "$C_GREEN" "$C_RESET" "$label"
        return 0
    fi
    printf '    %s[fallo]%s %s\n' "$C_RED" "$C_RESET" "$label"
    return 1
}

# Consulta como root. Dos detalles importantes:
#  - la clave nunca aparece en la linea de comandos: se lee de la variable de
#    entorno que ya vive dentro del contenedor, asi no queda en 'ps' del host;
#  - la consulta entra por la entrada estandar, no con -e, de modo que las
#    comillas del SQL no tienen que sobrevivir a dos niveles de shell.
db_query() {
    local sql=$1 database=${2:-}
    printf '%s\n' "$sql" | dc exec -T -e DEPLOYER_DB="$database" db sh -c \
        'exec "$(command -v mariadb || command -v mysql)" -uroot -p"$MYSQL_ROOT_PASSWORD" ${DEPLOYER_DB:+"$DEPLOYER_DB"} -N -B'
}

# Escapa un valor para meterlo entre comillas simples en una sentencia SQL. Las
# claves salen del proyecto del usuario y pueden traer comillas o barras.
sql_quote() {
    local v=$1
    v="${v//\\/\\\\}"
    v="${v//\'/\\\'}"
    printf "'%s'" "$v"
}

# Identificador (nombre de base o de tabla) entre acentos graves.
sql_ident() {
    printf '`%s`' "${1//\`/\`\`}"
}

# ============================================================================
# 95_sqlimport.sh - Seleccion e importacion del volcado SQL
# ============================================================================

SQL_IMPORTED=""
SQL_FILES=()
SQL_CHOSEN=()

phase_import_sql() {
    step "Fase 9/10 - Base de datos"

    if (( DRY_RUN )); then
        hint "[dry-run] Se buscarian archivos .sql en el proyecto y se importaria el elegido."
        return 0
    fi

    grant_project_user

    [[ "$SQL_CHOICE" == "none" ]] && { info "Importacion de SQL omitida (--sql none)."; return 0; }

    SQL_FILES=()
    mapfile -t SQL_FILES < <(find_sql_files)

    if (( ${#SQL_FILES[@]} == 0 )); then
        info "El proyecto no trae ningun archivo .sql: la base queda vacia."
        return 0
    fi

    select_sql_files
    (( ${#SQL_CHOSEN[@]} )) || { info "No se importara ningun volcado."; return 0; }

    local f
    for f in "${SQL_CHOSEN[@]}"; do
        import_sql_file "$f"
    done

    verify_import
}

# El usuario del proyecto lo crea la propia imagen con MYSQL_USER, pero solo con
# permisos sobre MYSQL_DATABASE. Si el volcado crea otras bases o el codigo
# necesita mas margen, esto lo deja resuelto de una vez.
grant_project_user() {
    info "Asegurando permisos de '${DB_USER}' sobre '${DB_NAME}'..."
    local db usr pass
    db="$(sql_ident "$DB_NAME")"
    usr="$(sql_quote "$DB_USER")"
    pass="$(sql_quote "$DB_PASS")"

    db_query "CREATE DATABASE IF NOT EXISTS ${db} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" >/dev/null
    db_query "CREATE USER IF NOT EXISTS ${usr}@'%' IDENTIFIED BY ${pass}" >/dev/null
    # Por si el usuario ya existia de un despliegue anterior con otra clave.
    db_query "ALTER USER ${usr}@'%' IDENTIFIED BY ${pass}" >/dev/null
    db_query "GRANT ALL PRIVILEGES ON ${db}.* TO ${usr}@'%'" >/dev/null
    db_query "FLUSH PRIVILEGES" >/dev/null
    ok "Usuario '${DB_USER}' con permisos sobre '${DB_NAME}'."
}

# Ordenados por tamano: el volcado bueno casi siempre es el mas grande, y los
# pequenos suelen ser migraciones sueltas o esquemas parciales.
find_sql_files() {
    # Que no haya volcados (o que 'find' se queje de un directorio) no es un
    # fallo del despliegue: quien llama ya trata la lista vacia.
    find "$APP_DIR" -type f \( -iname '*.sql' -o -iname '*.sql.gz' \) \
        -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' \
        -printf '%s\t%p\n' 2>/dev/null | sort -rn -k1,1 | cut -f2- || true
}

human_size() {
    local bytes=$1
    if (( bytes < 1024 )); then printf '%s B' "$bytes"
    elif (( bytes < 1048576 )); then printf '%s KB' "$(( bytes / 1024 ))"
    else printf '%s MB' "$(( bytes / 1048576 ))"
    fi
}

# Lee SQL_FILES y deja el resultado en SQL_CHOSEN. Se usan variables globales
# en vez de 'local -n' porque los nameref necesitan bash 4.3 y CentOS 7 trae 4.2.
select_sql_files() {
    local total=${#SQL_FILES[@]}
    SQL_CHOSEN=()

    # --sql con una ruta concreta: modo desatendido.
    if [[ -n "$SQL_CHOICE" && "$SQL_CHOICE" != "auto" ]]; then
        local target="$SQL_CHOICE"
        [[ -f "$target" ]] || target="${APP_DIR}/${SQL_CHOICE#/}"
        [[ -f "$target" ]] || die "No encuentro el volcado indicado: ${SQL_CHOICE}"
        SQL_CHOSEN=("$target")
        return 0
    fi

    if [[ "$SQL_CHOICE" == "auto" ]] || (( NONINTERACTIVE )); then
        SQL_CHOSEN=("${SQL_FILES[0]}")
        info "Volcado elegido automaticamente: ${SQL_CHOSEN[0]#"$APP_DIR"/}"
        return 0
    fi

    printf '\n    %sVolcados SQL encontrados en el proyecto:%s\n' "$C_BOLD" "$C_RESET"
    local i=1 f size
    for f in "${SQL_FILES[@]}"; do
        size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
        printf '      %2s) %-52s %s\n' "$i" "${f#"$APP_DIR"/}" "$(human_size "$size")"
        i=$((i + 1))
    done
    printf '      %2s) %s\n' "0" "No importar nada"
    printf '       %s) %s\n' "a" "Importar todos, en el orden mostrado"
    printf '\n'

    local choice=""
    while true; do
        printf '    Cual importamos? [%s1%s]: ' "$C_BOLD" "$C_RESET"
        IFS= read -r choice < "$TTY_IN" || choice=""
        choice="${choice:-1}"

        case "$choice" in
            0)   return 0 ;;
            a|A) SQL_CHOSEN=("${SQL_FILES[@]}"); return 0 ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
                    SQL_CHOSEN=("${SQL_FILES[choice-1]}")
                    return 0
                fi
                warn "Elige un numero entre 0 y ${total}, o 'a' para todos."
                ;;
        esac
    done
}

# La importacion es bloqueante: el script no sigue hasta que mysql termina de
# procesar el volcado, por grande que sea.
import_sql_file() {
    local file=$1
    local rel="${file#"$APP_DIR"/}"
    local size; size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"

    info "Importando ${rel} ($(human_size "$size")) en la base '${DB_NAME}'..."
    hint "Un volcado grande puede tardar varios minutos. No interrumpas el proceso."

    # El nombre de la base viaja como variable de entorno del contenedor: asi no
    # hay que hacerlo sobrevivir al entrecomillado del shell intermedio.
    local rc=0
    local -a mysql_run=(dc exec -T -e DEPLOYER_DB="$DB_NAME" db sh -c
        'exec "$(command -v mariadb || command -v mysql)" -uroot -p"$MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 "$DEPLOYER_DB"')

    if [[ "$file" == *.gz ]]; then
        gunzip -c "$file" | "${mysql_run[@]}" || rc=$?
    else
        "${mysql_run[@]}" < "$file" || rc=$?
    fi

    if (( rc != 0 )); then
        err "La importacion de ${rel} fallo (codigo ${rc})."
        hint "Causas habituales: el volcado trae 'CREATE DATABASE' de otra base,"
        hint "o usa una sintaxis que este motor no admite."
        die "Revisa el volcado y vuelve a importarlo con: ${PROJECT_DIR}/manage.sh restore ${file}"
    fi

    SQL_IMPORTED="${SQL_IMPORTED}${rel} "
    ok "Importado ${rel}."
}

# Comprobamos que el volcado realmente dejo tablas: un archivo que se procesa
# sin error pero no crea nada es un fallo silencioso muy facil de pasar por alto.
verify_import() {
    local tables rows
    local schema; schema="$(sql_quote "$DB_NAME")"
    # Esto es una comprobacion, no un paso del despliegue: si la consulta falla
    # se avisa, pero no se tira abajo una importacion que ya termino bien.
    tables="$(db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=${schema}" 2>/dev/null | tr -d '[:space:]' || true)"

    if [[ -z "$tables" || "$tables" == "0" ]]; then
        warn "La importacion termino sin errores pero la base '${DB_NAME}' no tiene ninguna tabla."
        hint "Es probable que el volcado apunte a otra base con su propio USE/CREATE DATABASE."
        return 0
    fi

    ok "Base '${DB_NAME}': ${tables} tablas creadas."

    # Un vistazo a las tablas mas pobladas confirma que hay datos y no solo esquema.
    rows="$(db_query "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema=${schema} AND table_rows > 0 ORDER BY table_rows DESC LIMIT 5" 2>/dev/null || true)"
    if [[ -n "$rows" ]]; then
        hint "Tablas con mas registros:"
        printf '%s\n' "$rows" | while IFS=$'\t' read -r t n; do
            [[ -n "$t" ]] && printf '        %-32s ~%s filas\n' "$t" "$n"
        done
    fi
    return 0
}

# ============================================================================
# 97_finish.sh - Cortafuegos, deteccion de IP y resumen final
# ============================================================================

PUBLIC_IP=""
LOCAL_IP=""

phase_firewall() {
    step "Fase 10/10 - Cortafuegos"

    if (( ! MANAGE_FIREWALL )); then
        info "Cortafuegos sin tocar (--no-firewall)."
        return 0
    fi
    if [[ "$FIREWALL_KIND" == "none" ]]; then
        hint "No hay firewalld ni ufw activos: los puertos ya estan accesibles."
        return 0
    fi

    local ports=("$PORT_HTTP")
    [[ "$WANT_PMA" == "yes" ]] && ports+=("$PORT_PMA")
    # El puerto de la base solo se abre si el usuario pidio exponerla: si esta
    # atada al loopback, abrirlo en el cortafuegos no serviria de nada.
    [[ "$DB_BIND_ADDR" == "0.0.0.0" ]] && ports+=("$PORT_DB")

    info "Hay que abrir en ${FIREWALL_KIND}: ${ports[*]}"
    if ! confirm "Abrir esos puertos ahora?" yes; then
        warn "Puertos sin abrir: el sitio no sera accesible desde fuera hasta que lo hagas."
        hint "Manualmente: $(firewall_hint "${ports[@]}")"
        return 0
    fi

    local p
    for p in "${ports[@]}"; do
        case "$FIREWALL_KIND" in
            firewalld) run firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null ;;
            ufw)       run ufw allow "${p}/tcp" >/dev/null ;;
        esac
    done
    [[ "$FIREWALL_KIND" == "firewalld" ]] && run firewall-cmd --reload >/dev/null

    ok "Puertos abiertos: ${ports[*]}"

    # Docker inserta sus reglas antes que las de ufw, asi que un puerto
    # publicado suele quedar accesible aunque ufw diga que esta cerrado.
    if [[ "$FIREWALL_KIND" == "ufw" ]]; then
        hint "Recuerda: Docker escribe sus propias reglas en iptables y ufw no las filtra."
    fi
    return 0
}

firewall_hint() {
    case "$FIREWALL_KIND" in
        firewalld) printf 'firewall-cmd --permanent --add-port=%s/tcp; firewall-cmd --reload' "$1" ;;
        ufw)       printf 'ufw allow %s/tcp' "$1" ;;
        *)         printf '(no aplica)' ;;
    esac
}

detect_ips() {
    # 'hostname -I' no existe en todas las imagenes minimas: si falta, el
    # respaldo de la linea siguiente ya deja 127.0.0.1.
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$LOCAL_IP" ]] || LOCAL_IP="127.0.0.1"

    # Varios servicios por si alguno esta caido o bloqueado desde el VPS.
    local svc
    for svc in "https://ifconfig.me/ip" "https://api.ipify.org" "https://icanhazip.com"; do
        PUBLIC_IP="$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')" || PUBLIC_IP=""
        [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
        PUBLIC_IP=""
    done
    PUBLIC_IP="$LOCAL_IP"
    return 0
}

phase_summary() {
    step "Listo"

    if (( DRY_RUN )); then
        ok "Simulacion terminada: no se ha modificado nada."
        return 0
    fi

    detect_ips
    local summary="${PROJECT_DIR}/RESUMEN.txt"

    {
        printf '========================================================\n'
        printf ' Proyecto %s desplegado\n' "$PROJECT_NAME"
        printf ' %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '========================================================\n\n'

        printf 'ACCESO WEB\n'
        printf '  Publico    http://%s:%s\n' "$PUBLIC_IP" "$PORT_HTTP"
        [[ "$LOCAL_IP" != "$PUBLIC_IP" ]] && printf '  Red local  http://%s:%s\n' "$LOCAL_IP" "$PORT_HTTP"
        if [[ "$WANT_PMA" == "yes" ]]; then
            printf '  phpMyAdmin http://%s:%s\n' "$PUBLIC_IP" "$PORT_PMA"
        fi
        printf '\n'

        printf 'BASE DE DATOS (%s)\n' "$(db_image)"
        printf '  Base       %s\n' "$DB_NAME"
        printf '  Usuario    %s\n' "$DB_USER"
        printf '  Clave      %s\n' "$DB_PASS"
        printf '  Clave root %s\n' "$DB_ROOT_PASS"
        printf '  Desde PHP  host "db", puerto 3306\n'
        if [[ "$DB_BIND_ADDR" == "0.0.0.0" ]]; then
            printf '  Desde fuera %s:%s\n' "$PUBLIC_IP" "$PORT_DB"
        else
            printf '  Desde fuera solo por tunel SSH:\n'
            printf '              ssh -L %s:127.0.0.1:%s usuario@%s\n' "$PORT_DB" "$PORT_DB" "$PUBLIC_IP"
        fi
        printf '\n'

        printf 'STACK\n'
        printf '  Web        %s\n' "$WEB_ENGINE"
        printf '  PHP        %s\n' "$PHP_VERSION"
        printf '  Raiz web   %s\n' "$(container_docroot)"
        [[ -n "$DB_CONFIG_FILE" ]] && printf '  Config PHP %s\n' "${DB_CONFIG_FILE#"$APP_DIR"/}"
        [[ -n "$SQL_IMPORTED" ]] && printf '  SQL        %s\n' "$SQL_IMPORTED"
        printf '\n'

        printf 'ARCHIVOS\n'
        printf '  Proyecto   %s\n' "$PROJECT_DIR"
        printf '  Codigo     %s\n' "$APP_DIR"
        printf '  Compose    %s/docker-compose.yml\n' "$PROJECT_DIR"
        printf '  Volumenes  %s_dbdata (base) y %s_weblogs (logs)\n' "$PROJECT_NAME" "$PROJECT_NAME"
        printf '\n'

        printf 'GESTION\n'
        printf '  %s/manage.sh start | stop | restart | logs | status\n' "$PROJECT_DIR"
        printf '  %s/manage.sh shell | db | backup | restore F | destroy\n' "$PROJECT_DIR"
        printf '\n'
        printf 'Los datos de la base viven en un volumen con nombre: parar o\n'
        printf 'reiniciar los contenedores no los borra. Solo "destroy" lo hace.\n'
    } > "$summary"
    chmod 600 "$summary"

    printf '\n'
    cat "$summary"
    printf '\n'

    ok "Resumen guardado en ${summary} (contiene las claves: permisos 600)."
    [[ -n "${DEPLOYER_LOG_FILE:-}" ]] && hint "Log de la instalacion: ${DEPLOYER_LOG_FILE}"

    ROLLBACK_ARMED=0    # todo salio bien: ya no hay nada que deshacer
    return 0
}

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
