
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
