
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
