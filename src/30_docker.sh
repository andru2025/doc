
# ============================================================================
# 30_docker.sh - Instalacion y verificacion de Docker + plugin compose
# ============================================================================

docker_alive() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

compose_alive() {
    docker compose version >/dev/null 2>&1
}

phase_setup_docker() {
    step "Fase 1/10 - Docker"

    ensure_base_tools

    if docker_alive; then
        DOCKER_WAS_PRESENT=1
        ok "Docker ya esta instalado y funcionando ($(docker --version 2>/dev/null | head -1)). Se omite la instalacion."
    elif command -v docker >/dev/null 2>&1; then
        # El binario esta pero el demonio no responde: casi siempre es que el
        # servicio no arranco al instalar la imagen del VPS.
        info "Docker esta instalado pero el demonio no responde. Intentando arrancarlo..."
        start_docker_daemon
        docker_alive || die "El demonio de Docker no arranca. Revisa: systemctl status docker"
        DOCKER_WAS_PRESENT=1
        ok "Demonio de Docker arrancado."
    else
        install_docker
        start_docker_daemon
        docker_alive || die "Docker se instalo pero el demonio no responde. Revisa: systemctl status docker"
        ok "Docker instalado correctamente."
    fi

    if compose_alive; then
        ok "Docker Compose disponible ($(docker compose version --short 2>/dev/null))."
    else
        install_compose_plugin
        compose_alive || die "No se pudo instalar el plugin 'docker compose'."
        ok "Plugin Docker Compose instalado."
    fi
}

install_docker() {
    info "Instalando Docker en ${OS_NAME}..."

    # El instalador oficial cubre Debian, Ubuntu, RHEL, CentOS, Fedora y SLES,
    # y se mantiene al dia con las versiones nuevas de cada distro. Solo si
    # falla o la distro no esta en su lista pasamos al camino manual.
    if [[ "$PKG_FAMILY" != "arch" ]]; then
        if run bash -c 'curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh'; then
            rm -f /tmp/get-docker.sh
            return 0
        fi
        warn "El instalador oficial fallo. Probando con los repositorios de la distribucion."
    fi

    case "$PKG_FAMILY" in
        debian) install_docker_debian ;;
        rhel)   install_docker_rhel ;;
        suse)   run zypper --non-interactive install docker docker-compose ;;
        arch)   run pacman -S --noconfirm --needed docker docker-compose ;;
    esac
}

install_docker_debian() {
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q ca-certificates curl gnupg
    run install -m 0755 -d /etc/apt/keyrings

    local repo_id="$OS_ID"
    # Las derivadas (Linux Mint, Pop!_OS, elementary) no tienen repo propio en
    # download.docker.com: hay que apuntar al de su distribucion base.
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) [[ "${ID_LIKE:-}" == *ubuntu* ]] && repo_id="ubuntu" || repo_id="debian" ;;
    esac

    run bash -c "curl -fsSL https://download.docker.com/linux/${repo_id}/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes"
    run chmod a+r /etc/apt/keyrings/docker.gpg

    local codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "$codename" ]] || die "No puedo determinar el nombre en clave de la distribucion para el repositorio de Docker."

    run bash -c "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${repo_id} ${codename} stable' > /etc/apt/sources.list.d/docker.list"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
    local mgr="dnf"
    command -v dnf >/dev/null 2>&1 || mgr="yum"

    if [[ "$mgr" == "dnf" ]]; then
        run dnf install -y -q dnf-plugins-core
        # AlmaLinux, Rocky y CentOS Stream usan el repositorio de CentOS.
        local repo_distro="centos"
        [[ "$OS_ID" == "fedora" ]] && repo_distro="fedora"
        run dnf config-manager --add-repo "https://download.docker.com/linux/${repo_distro}/docker-ce.repo"
    else
        run yum install -y -q yum-utils
        run yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi

    run "$mgr" install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker_daemon() {
    if command -v systemctl >/dev/null 2>&1; then
        run systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
        run service docker start
    else
        warn "Sin systemd ni service: arranca el demonio de Docker a mano."
        return 0
    fi
    # El socket tarda un momento en aceptar conexiones tras el arranque.
    wait_for "Esperando al demonio de Docker" 60 docker info || return 1
}

# En distros sin docker-compose-plugin empaquetado (o si el paquete no entro),
# el plugin es un unico binario que basta con dejar en el directorio correcto.
install_compose_plugin() {
    info "Instalando el plugin de Docker Compose..."

    case "$PKG_FAMILY" in
        debian) run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-plugin || true ;;
        rhel)   run bash -c "(dnf install -y -q docker-compose-plugin || yum install -y -q docker-compose-plugin) || true" ;;
    esac
    compose_alive && return 0

    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "No hay binario oficial de Docker Compose para la arquitectura ${arch}." ;;
    esac

    local dest=/usr/local/lib/docker/cli-plugins
    run mkdir -p "$dest"
    run bash -c "curl -fsSL 'https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}' -o '${dest}/docker-compose'"
    run chmod +x "${dest}/docker-compose"
}
