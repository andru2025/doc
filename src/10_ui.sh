
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
