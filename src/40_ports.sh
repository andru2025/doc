
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
