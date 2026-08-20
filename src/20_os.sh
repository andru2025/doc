
# ============================================================================
# 20_os.sh - Deteccion de la distribucion, SELinux y firewall
# ============================================================================

phase_detect_os() {
    step "Fase 1/10 - Reconociendo el sistema"

    [[ -r /etc/os-release ]] || die "No encuentro /etc/os-release: distribucion no soportada."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-desconocido}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    OS_VERSION="${VERSION_ID:-}"
    local id_like="${ID_LIKE:-}"

    # Agrupamos por gestor de paquetes: lo que cambia entre distros de la misma
    # familia (Debian/Ubuntu, RHEL/Alma/Rocky/CentOS) es practicamente nada.
    case " ${OS_ID} ${id_like} " in
        *" debian "*|*" ubuntu "*)
            PKG_FAMILY="debian"
            PKG_INSTALL="apt-get install -y -q"
            ;;
        *" rhel "*|*" fedora "*|*" centos "*)
            PKG_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then
                PKG_INSTALL="dnf install -y -q"
            else
                PKG_INSTALL="yum install -y -q"
            fi
            ;;
        *" suse "*|*" opensuse "*)
            PKG_FAMILY="suse"
            PKG_INSTALL="zypper --non-interactive install"
            ;;
        *" arch "*)
            PKG_FAMILY="arch"
            PKG_INSTALL="pacman -S --noconfirm --needed"
            ;;
        *)
            die "Distribucion no reconocida: ${OS_NAME} (ID=${OS_ID}, ID_LIKE=${id_like})."
            ;;
    esac

    ok "Sistema: ${OS_NAME} (familia ${PKG_FAMILY})"

    detect_selinux
    detect_firewall
    detect_arch_supported
}

detect_arch_supported() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64|aarch64|arm64) hint "Arquitectura: ${arch}" ;;
        *) warn "Arquitectura ${arch}: puede que no existan imagenes Docker oficiales para todos los servicios." ;;
    esac
}

# En RHEL y derivadas SELinux bloquea los bind mounts salvo que se etiqueten.
# Sin el sufijo :Z el contenedor ve el docroot vacio o da "Permission denied",
# que es el fallo mas comun al desplegar esto en AlmaLinux o Rocky.
detect_selinux() {
    MOUNT_SUFFIX=""
    SELINUX_ON=0
    if command -v getenforce >/dev/null 2>&1; then
        if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
            SELINUX_ON=1
            MOUNT_SUFFIX=":Z"
            info "SELinux activo: los volumenes se etiquetaran con ':Z'."
        fi
    fi
}

detect_firewall() {
    FIREWALL_KIND="none"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALL_KIND="firewalld"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        FIREWALL_KIND="ufw"
    fi
    if [[ "$FIREWALL_KIND" != "none" ]]; then
        info "Cortafuegos detectado: ${FIREWALL_KIND}"
    else
        hint "Sin cortafuegos activo en el sistema."
    fi
}

# Instala paquetes solo si faltan; en un VPS recien creado suele faltar todo.
ensure_packages() {
    local missing=() pkg
    for pkg in "$@"; do
        local bin="${pkg%%:*}" name="${pkg##*:}"
        command -v "$bin" >/dev/null 2>&1 || missing+=("$name")
    done
    (( ${#missing[@]} )) || return 0

    info "Instalando paquetes que faltan: ${missing[*]}"
    case "$PKG_FAMILY" in
        debian)
            run env DEBIAN_FRONTEND=noninteractive apt-get update -q
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
            ;;
        rhel|suse|arch)
            # shellcheck disable=SC2086
            run $PKG_INSTALL "${missing[@]}"
            ;;
    esac
}

# Nombres de paquete que no coinciden entre familias.
pkg_name_for() {
    local tool=$1
    case "$tool:$PKG_FAMILY" in
        ss:debian)   echo "iproute2" ;;
        ss:*)        echo "iproute" ;;
        unzip:*)     echo "unzip" ;;
        git:*)       echo "git" ;;
        curl:*)      echo "curl" ;;
        *)           echo "$tool" ;;
    esac
}

ensure_base_tools() {
    local specs=() tool
    for tool in curl git unzip ss; do
        specs+=("${tool}:$(pkg_name_for "$tool")")
    done
    ensure_packages "${specs[@]}"
}
