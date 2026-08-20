
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
    dc exec -T "$svc" "$@"
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
            check "Proceso apache2 en marcha" dexec web pgrep -x apache2 || failed=1
            check "PHP ${PHP_VERSION} operativo" dexec web php -v || failed=1
            ;;
        nginx)
            check "Configuracion de Nginx" dexec web nginx -t || failed=1
            check "Proceso nginx en marcha" dexec web pgrep -x nginx || failed=1
            check "Proceso php-fpm en marcha" dexec php pgrep -f php-fpm || failed=1
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
        'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ${DEPLOYER_DB:+"$DEPLOYER_DB"} -N -B'
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
