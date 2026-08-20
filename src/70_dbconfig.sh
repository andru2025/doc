
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
