#!/usr/bin/env bash
#
# Comprobaciones que se pueden hacer sin Docker y sin un VPS.
# No sustituyen a la prueba real en una maquina Linux (ver tests/vms.md).
#
#   bash tests/smoke.sh
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0
FAIL=0

# Los ayudantes llevan prefijo t_ porque mas abajo se carga deploy.sh entero y
# este define sus propias funciones check(), ok(), info(), run()...
t_pass() { printf '  [ok]    %s\n' "$1"; PASS=$((PASS + 1)); }
t_fail() { printf '  [FALLO] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# t_ok LABEL cmd...  -> el comando debe devolver 0
t_ok() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then t_pass "$label"; else t_fail "$label"; fi
}

# t_no LABEL cmd...  -> el comando debe fallar.
# Se ejecuta en el shell actual a proposito: con `bash -c` la funcion no
# existiria, el subshell fallaria con 127 y la prueba pasaria sin comprobar nada.
t_no() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then t_fail "${label} (deberia haber fallado)"; else t_pass "$label"; fi
}

# Ejecuta el comando en una subshell. Necesario para probar rutas que terminan
# en die(), que llama a exit y se llevaria por delante el propio test.
t_sub() { ( "$@" ); }

# t_out LABEL TEXTO_ESPERADO cmd...
t_out() {
    local label=$1 expected=$2; shift 2
    local out
    out="$("$@" 2>&1 || true)"
    if [[ "$out" == *"$expected"* ]]; then
        t_pass "$label"
    else
        t_fail "$label"
        printf '          esperaba: %s\n' "$expected"
        printf '          obtuve:   %s\n' "${out:0:120}"
    fi
}

echo "== Construccion =="
t_ok "build.sh genera dist/deploy.sh" bash build.sh
t_ok "dist/deploy.sh no esta vacio"   test -s dist/deploy.sh
t_no "no quedan finales de linea CRLF" grep -qU $'\r' dist/deploy.sh
t_no "no queda ningun marcador __RAW_URL__ sin sustituir" grep -q __RAW_URL__ dist/deploy.sh
t_ok "el one-liner apunta al servidor real" \
    grep -q 'https://raw.githubusercontent.com/andru2025/doc/main/dist/deploy.sh' dist/deploy.sh
t_ok "RAW_URL se puede sobrescribir al construir" \
    bash -c 'RAW_URL=https://ejemplo.test/x bash build.sh >/dev/null \
             && grep -q "https://ejemplo.test/x/deploy.sh" dist/deploy.sh'
t_ok "una RAW_URL con barra final no genera una doble barra" \
    bash -c 'RAW_URL=https://ejemplo.test/x/ bash build.sh >/dev/null \
             && ! grep -q "ejemplo.test/x//deploy.sh" dist/deploy.sh'
bash build.sh >/dev/null   # se reconstruye con la URL de produccion

echo
echo "== Sintaxis =="
for f in src/*.sh build.sh tests/*.sh dist/deploy.sh; do
    t_ok "bash -n $f" bash -n "$f"
done

echo
echo "== Interfaz de linea de comandos =="
t_out "--version imprime la version"        "1."           bash dist/deploy.sh --version
t_out "--help documenta --name"             "--name"       bash dist/deploy.sh --help
t_out "--web invalido se rechaza"           "apache"       bash dist/deploy.sh --web tomcat
t_out "--db invalido se rechaza"            "mysql"        bash dist/deploy.sh --db postgres
t_out "--php invalido se rechaza"           "8.3"          bash dist/deploy.sh --php 9.9
t_out "--repo y --zip son excluyentes"      "excluyentes"  bash dist/deploy.sh --repo a --zip b
t_out "una opcion desconocida se rechaza"   "desconocida"  bash dist/deploy.sh --inventada

echo
echo "== Funciones internas =="
export DEPLOYER_SOURCE_ONLY=1
# shellcheck disable=SC1091
source dist/deploy.sh
trap - ERR
set +e

t_ok "valid_project_name acepta 'mi-web1'"     valid_project_name "mi-web1"
t_ok "valid_project_name acepta 'tienda_2'"    valid_project_name "tienda_2"
t_no "valid_project_name rechaza 'Mi Web'"     valid_project_name "Mi Web"
t_no "valid_project_name rechaza mayusculas"   valid_project_name "MiWeb"
t_no "valid_project_name rechaza vacio"        valid_project_name ""
t_no "valid_project_name rechaza '-inicio'"    valid_project_name "-inicio"
t_no "valid_project_name rechaza un solo caracter" valid_project_name "a"

t_ok "host_is_local reconoce localhost"       host_is_local "localhost"
t_ok "host_is_local reconoce 127.0.0.1"       host_is_local "127.0.0.1"
t_ok "host_is_local reconoce ::1"             host_is_local "::1"
t_ok "host_is_local reconoce el valor vacio"  host_is_local ""
t_ok "host_is_local ignora el puerto"         host_is_local "localhost:3306"
t_no "host_is_local rechaza un host remoto"   host_is_local "db.midominio.com"
t_no "host_is_local rechaza otra IP"          host_is_local "10.0.0.5"

WEB_ENGINE=apache; DOCROOT=""
t_out "container_docroot en la raiz"            "/var/www/html"        container_docroot
DOCROOT="public"
t_out "container_docroot con subdirectorio"     "/var/www/html/public" container_docroot
DOCROOT=""

PHP_VERSION=5.6
t_out "PHP 5.6 usa mysql-client"                "mysql-client"   php_mysql_client_pkg
t_out "PHP 5.6 instala la extension mysql"      "mysql "         php_extensions
t_out "PHP 5.6 usa los flags viejos de gd"      "--with-freetype-dir" php_gd_configure
t_ok  "PHP 5.6 necesita repositorios de archivo" php_needs_archive_repos
PHP_VERSION=7.4
t_ok  "PHP 7.4 necesita repositorios de archivo" php_needs_archive_repos
PHP_VERSION=8.3
t_out "PHP 8.3 usa default-mysql-client"        "default-mysql-client" php_mysql_client_pkg
t_out "PHP 8.3 usa los flags nuevos de gd"      "--with-freetype "     php_gd_configure
t_no  "PHP 8.3 no necesita repos de archivo"    php_needs_archive_repos

t_out "yaml_quote escapa comillas simples"      "'a''b'"    yaml_quote "a'b"
# Compose interpola \$VAR antes de parsear el YAML: hay que duplicar el dolar.
t_out "yaml_quote duplica el signo dolar"       "'a\$\$b'"  yaml_quote 'a$b'
t_out "yaml_quote duplica \${VAR} entero"       "'\$\${HOME}'" yaml_quote '${HOME}'

USED_PORTS=$'\n8080\n8081\n3306\n'
t_no  "port_free rechaza un puerto ocupado"     port_free 8080
t_ok  "port_free acepta un puerto libre"        port_free 8082
t_no  "port_free rechaza un puerto fuera de rango" port_free 99999
t_no  "port_free rechaza un valor no numerico"  port_free "abc"
t_out "next_free_port salta los ocupados"       "8082"    next_free_port 8080

# Regresion: next_free_port debe marcar el puerto como usado en el shell actual.
# Si la marca se pierde (por ejemplo dentro de $(...)), dos servicios seguidos
# se llevarian el mismo puerto y el segundo contenedor no arrancaria.
USED_PORTS=$'\n8080\n'
PORT_UNO=""; PORT_DOS=""
claim_port PORT_UNO 8080 "primero"
claim_port PORT_DOS 8080 "segundo"
if [[ "$PORT_UNO" == "8081" && "$PORT_DOS" == "8082" ]]; then
    t_pass "dos claim_port seguidos no repiten puerto"
else
    t_fail "dos claim_port seguidos no repiten puerto (obtuve $PORT_UNO y $PORT_DOS)"
fi

# Un puerto forzado que ya esta ocupado debe abortar, no colarse.
USED_PORTS=$'\n8080\n'
PORT_FORZADO=8080
t_no "claim_port rechaza un puerto forzado que esta ocupado" t_sub claim_port PORT_FORZADO 8080 "forzado"

DB_ENGINE=mysql
t_out "imagen de MySQL"                         "mysql:8.0"    db_image
t_out "healthcheck de MySQL usa mysqladmin"     "mysqladmin"   db_ping_cmd
DB_ENGINE=mariadb
t_out "imagen de MariaDB"                       "mariadb:11"   db_image
t_out "healthcheck de MariaDB usa healthcheck.sh" "healthcheck.sh" db_ping_cmd

t_out "human_size en bytes" "512 B"  human_size 512
t_out "human_size en KB"    "2 KB"   human_size 2048
t_out "human_size en MB"    "5 MB"   human_size 5242880

t_out "mask oculta la contrasena"  "s******"  mask "secreto"
t_out "mask avisa si esta vacia"   "(vacia)"  mask ""

echo
echo "== Parseo de configuraciones PHP =="
FIXTURES="$(mktemp -d)"
APP_DIR="$FIXTURES"
cat > "$FIXTURES/config.php" <<'PHPEOF'
<?php
define('DB_HOST', 'localhost');
define('DB_NAME', 'tienda');
define('DB_USER', 'tienda_user');
define('DB_PASS', 'Cl4v3');
PHPEOF
cat > "$FIXTURES/conexion.php" <<'PHPEOF'
<?php
$servername = "localhost";
$username = "root";
$password = "toor";
$dbname = "inventario";
$conn = new mysqli($servername, $username, $password, $dbname);
PHPEOF
cat > "$FIXTURES/legacy.php" <<'PHPEOF'
<?php
$conn = mysqli_connect("127.0.0.1", "app", "p@ss", "escuela");
PHPEOF
cat > "$FIXTURES/pdo.php" <<'PHPEOF'
<?php
$pdo = new PDO("mysql:host=localhost;dbname=ventas", "vuser", "vpass");
PHPEOF
cat > "$FIXTURES/.env" <<'PHPEOF'
DB_HOST=localhost
DB_DATABASE=laravel_app
DB_USERNAME=laravel
DB_PASSWORD=secret
PHPEOF

t_parse() {
    local file=$1 label=$2 want_name=$3 want_user=$4 want_pass=$5
    parse_config_file "$FIXTURES/$file"
    if [[ "$DB_NAME" == "$want_name" && "$DB_USER" == "$want_user" && "$DB_PASS" == "$want_pass" ]]; then
        t_pass "$label"
    else
        t_fail "$label"
        printf '          esperaba: %s / %s / %s\n' "$want_name" "$want_user" "$want_pass"
        printf '          obtuve:   %s / %s / %s\n' "$DB_NAME" "$DB_USER" "$DB_PASS"
    fi
}

t_parse config.php   "define() se lee bien"           tienda      tienda_user Cl4v3
t_parse conexion.php "variables sueltas se leen bien" inventario  root        toor
t_parse legacy.php   "mysqli_connect posicional"      escuela     app         'p@ss'
t_parse pdo.php      "new PDO posicional"             ventas      vuser       vpass
t_parse .env         "formato .env"                   laravel_app laravel     secret

# El host debe acabar apuntando al servicio 'db' en los cinco formatos.
t_rewrite() {
    local file=$1 label=$2
    local work; work="$(mktemp -d)"
    cp "$FIXTURES/$file" "$work/"
    DB_CONFIG_FILE="$work/$file"
    parse_config_file "$DB_CONFIG_FILE"
    rewrite_config_host >/dev/null 2>&1
    # 'db' puede quedar tras un '=', un '=>', una coma o el parentesis de
    # apertura de mysqli_connect, ademas del DSN de PDO y del formato .env.
    if grep -qE "(=|=>|,|\()[[:space:]]*['\"]db['\"]|host=db|^DB_HOST=db" "$DB_CONFIG_FILE"; then
        t_pass "$label"
    else
        t_fail "$label"
        printf '          resultado: %s\n' "$(grep -nE "db|host|servername" "$DB_CONFIG_FILE" | head -2 | tr '\n' ' ')"
    fi
    t_no "${label}: no queda 'localhost'" grep -q "localhost" "$DB_CONFIG_FILE"
    rm -rf "$work"
}

t_rewrite config.php   "reescribe el host en define()"
t_rewrite conexion.php "reescribe el host en \$servername"
t_rewrite legacy.php   "reescribe el host en mysqli_connect"
t_rewrite pdo.php      "reescribe el host en el DSN de PDO"
t_rewrite .env         "reescribe el host en .env"

# La copia de seguridad es lo que permite deshacer si algo sale mal.
work="$(mktemp -d)"; cp "$FIXTURES/config.php" "$work/"
DB_CONFIG_FILE="$work/config.php"
parse_config_file "$DB_CONFIG_FILE"
rewrite_config_host >/dev/null 2>&1
t_ok "se guarda copia .deployer.bak antes de tocar el archivo" test -f "$work/config.php.deployer.bak"
t_ok "la copia conserva el host original" grep -q "localhost" "$work/config.php.deployer.bak"
rm -rf "$work"

# Un host que ya apunta fuera no se debe tocar.
work="$(mktemp -d)"
printf "<?php\ndefine('DB_HOST', 'db.remoto.com');\n" > "$work/config.php"
DB_CONFIG_FILE="$work/config.php"
parse_config_file "$DB_CONFIG_FILE"
rewrite_config_host >/dev/null 2>&1
t_ok "un host remoto se deja intacto" grep -q "db.remoto.com" "$work/config.php"
rm -rf "$work"

# Se prefiere config.php frente a un archivo cualquiera con credenciales.
mkdir -p "$FIXTURES/includes"
printf "<?php // DB_USER suelto\n\$db_user='x';\n" > "$FIXTURES/includes/otro.php"
mapfile -t cands < <(find_config_candidates)
t_out "config.php encabeza la lista de candidatos" "config.php" printf '%s' "${cands[0]:-}"

rm -rf "$FIXTURES"

echo
echo "== Generacion de artefactos =="
ARTIFACTS="$(mktemp -d)"
t_ok "las 24 combinaciones de stack se generan" bash tests/gen-artifacts.sh "$ARTIFACTS"

# Rutas al estilo Windows para el python nativo cuando se corre bajo Git Bash.
ART_FOR_PY="$ARTIFACTS"
command -v cygpath >/dev/null 2>&1 && ART_FOR_PY="$(cygpath -m "$ARTIFACTS")"

# No basta con que el binario exista: en Windows 'python3' suele ser el atajo a
# la Store, que no ejecuta nada. Se comprueba que de verdad arranca.
PY=""
for candidate in python3 python; do
    if "$candidate" -c 'import sys' >/dev/null 2>&1; then
        PY="$candidate"
        break
    fi
done

if [[ -n "$PY" ]]; then
    if out="$("$PY" tests/validate-compose.py "$ART_FOR_PY" 2>&1)"; then
        t_pass "los 24 docker-compose.yml son validos y correctos"
        printf '%s\n' "$out" | sed 's/^/  /'
    else
        t_fail "los 24 docker-compose.yml son validos y correctos"
        printf '%s\n' "$out"
    fi
else
    printf '  [--]    validacion de compose omitida (no hay python)\n'
fi
rm -rf "$ARTIFACTS"

echo
printf '%s correctas, %s fallos\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
