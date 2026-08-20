
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
