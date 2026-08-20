
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
