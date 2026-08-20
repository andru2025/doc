#!/usr/bin/env bash
#
# Compila los modulos de src/ en un unico dist/deploy.sh autocontenido.
# El one-liner de curl debe descargar un solo archivo, por eso no partimos el
# script en tiempo de ejecucion: se concatena aqui, en tiempo de construccion.
#
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SRC_DIR="src"
OUT_DIR="dist"
OUT="${OUT_DIR}/deploy.sh"

# Directorio publico desde el que se sirve deploy.sh. El marcador __RAW_URL__
# que hay en src/ se sustituye por este valor, asi que el mensaje --help del
# script generado siempre muestra la direccion real.
# Se puede cambiar puntualmente:  RAW_URL=https://otro/sitio bash build.sh
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/andru2025/doc/main/dist}"
# Sin la barra final, para que al pegarle "/deploy.sh" no salga una doble barra.
RAW_URL="${RAW_URL%/}"

mkdir -p "$OUT_DIR"

mapfile -t modules < <(find "$SRC_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
(( ${#modules[@]} )) || { echo "No hay modulos en ${SRC_DIR}/" >&2; exit 1; }

# 00_header.sh aporta el shebang; el resto se pega tal cual detras.
{
    for m in "${modules[@]}"; do
        cat "$m"
    done
} > "$OUT.tmp"

# Sello de construccion y URL real, insertados sobre el artefacto final.
sed -i "s|__RAW_URL__|${RAW_URL}|g" "$OUT.tmp"
sed -i "0,/^set -Eeuo pipefail$/s||# Generado por build.sh el $(date -u '+%Y-%m-%d %H:%M UTC') - no editar\nset -Eeuo pipefail|" "$OUT.tmp"

# El artefacto va al VPS por curl: los finales de linea CRLF romperian bash.
if command -v dos2unix >/dev/null 2>&1; then
    dos2unix -q "$OUT.tmp"
else
    sed -i 's/\r$//' "$OUT.tmp"
fi

bash -n "$OUT.tmp" || { echo "Error de sintaxis en el script generado" >&2; rm -f "$OUT.tmp"; exit 1; }

mv "$OUT.tmp" "$OUT"
chmod +x "$OUT"

printf 'Generado %s (%s lineas, %s modulos)\n' \
    "$OUT" "$(wc -l < "$OUT")" "${#modules[@]}"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$OUT" && echo "shellcheck: sin avisos"
else
    echo "shellcheck no instalado, omitido"
fi
