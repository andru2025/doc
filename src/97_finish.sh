
# ============================================================================
# 97_finish.sh - Cortafuegos, deteccion de IP y resumen final
# ============================================================================

PUBLIC_IP=""
LOCAL_IP=""

phase_firewall() {
    step "Fase 10/10 - Cortafuegos"

    if (( ! MANAGE_FIREWALL )); then
        info "Cortafuegos sin tocar (--no-firewall)."
        return 0
    fi
    if [[ "$FIREWALL_KIND" == "none" ]]; then
        hint "No hay firewalld ni ufw activos: los puertos ya estan accesibles."
        return 0
    fi

    local ports=("$PORT_HTTP")
    [[ "$WANT_PMA" == "yes" ]] && ports+=("$PORT_PMA")
    # El puerto de la base solo se abre si el usuario pidio exponerla: si esta
    # atada al loopback, abrirlo en el cortafuegos no serviria de nada.
    [[ "$DB_BIND_ADDR" == "0.0.0.0" ]] && ports+=("$PORT_DB")

    info "Hay que abrir en ${FIREWALL_KIND}: ${ports[*]}"
    if ! confirm "Abrir esos puertos ahora?" yes; then
        warn "Puertos sin abrir: el sitio no sera accesible desde fuera hasta que lo hagas."
        hint "Manualmente: $(firewall_hint "${ports[@]}")"
        return 0
    fi

    local p
    for p in "${ports[@]}"; do
        case "$FIREWALL_KIND" in
            firewalld) run firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null ;;
            ufw)       run ufw allow "${p}/tcp" >/dev/null ;;
        esac
    done
    [[ "$FIREWALL_KIND" == "firewalld" ]] && run firewall-cmd --reload >/dev/null

    ok "Puertos abiertos: ${ports[*]}"

    # Docker inserta sus reglas antes que las de ufw, asi que un puerto
    # publicado suele quedar accesible aunque ufw diga que esta cerrado.
    if [[ "$FIREWALL_KIND" == "ufw" ]]; then
        hint "Recuerda: Docker escribe sus propias reglas en iptables y ufw no las filtra."
    fi
    return 0
}

firewall_hint() {
    case "$FIREWALL_KIND" in
        firewalld) printf 'firewall-cmd --permanent --add-port=%s/tcp; firewall-cmd --reload' "$1" ;;
        ufw)       printf 'ufw allow %s/tcp' "$1" ;;
        *)         printf '(no aplica)' ;;
    esac
}

detect_ips() {
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$LOCAL_IP" ]] || LOCAL_IP="127.0.0.1"

    # Varios servicios por si alguno esta caido o bloqueado desde el VPS.
    local svc
    for svc in "https://ifconfig.me/ip" "https://api.ipify.org" "https://icanhazip.com"; do
        PUBLIC_IP="$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')" || PUBLIC_IP=""
        [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
        PUBLIC_IP=""
    done
    PUBLIC_IP="$LOCAL_IP"
    return 0
}

phase_summary() {
    step "Listo"

    if (( DRY_RUN )); then
        ok "Simulacion terminada: no se ha modificado nada."
        return 0
    fi

    detect_ips
    local summary="${PROJECT_DIR}/RESUMEN.txt"

    {
        printf '========================================================\n'
        printf ' Proyecto %s desplegado\n' "$PROJECT_NAME"
        printf ' %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '========================================================\n\n'

        printf 'ACCESO WEB\n'
        printf '  Publico    http://%s:%s\n' "$PUBLIC_IP" "$PORT_HTTP"
        [[ "$LOCAL_IP" != "$PUBLIC_IP" ]] && printf '  Red local  http://%s:%s\n' "$LOCAL_IP" "$PORT_HTTP"
        if [[ "$WANT_PMA" == "yes" ]]; then
            printf '  phpMyAdmin http://%s:%s\n' "$PUBLIC_IP" "$PORT_PMA"
        fi
        printf '\n'

        printf 'BASE DE DATOS (%s)\n' "$(db_image)"
        printf '  Base       %s\n' "$DB_NAME"
        printf '  Usuario    %s\n' "$DB_USER"
        printf '  Clave      %s\n' "$DB_PASS"
        printf '  Clave root %s\n' "$DB_ROOT_PASS"
        printf '  Desde PHP  host "db", puerto 3306\n'
        if [[ "$DB_BIND_ADDR" == "0.0.0.0" ]]; then
            printf '  Desde fuera %s:%s\n' "$PUBLIC_IP" "$PORT_DB"
        else
            printf '  Desde fuera solo por tunel SSH:\n'
            printf '              ssh -L %s:127.0.0.1:%s usuario@%s\n' "$PORT_DB" "$PORT_DB" "$PUBLIC_IP"
        fi
        printf '\n'

        printf 'STACK\n'
        printf '  Web        %s\n' "$WEB_ENGINE"
        printf '  PHP        %s\n' "$PHP_VERSION"
        printf '  Raiz web   %s\n' "$(container_docroot)"
        [[ -n "$DB_CONFIG_FILE" ]] && printf '  Config PHP %s\n' "${DB_CONFIG_FILE#"$APP_DIR"/}"
        [[ -n "$SQL_IMPORTED" ]] && printf '  SQL        %s\n' "$SQL_IMPORTED"
        printf '\n'

        printf 'ARCHIVOS\n'
        printf '  Proyecto   %s\n' "$PROJECT_DIR"
        printf '  Codigo     %s\n' "$APP_DIR"
        printf '  Compose    %s/docker-compose.yml\n' "$PROJECT_DIR"
        printf '  Volumenes  %s_dbdata (base) y %s_weblogs (logs)\n' "$PROJECT_NAME" "$PROJECT_NAME"
        printf '\n'

        printf 'GESTION\n'
        printf '  %s/manage.sh start | stop | restart | logs | status\n' "$PROJECT_DIR"
        printf '  %s/manage.sh shell | db | backup | restore F | destroy\n' "$PROJECT_DIR"
        printf '\n'
        printf 'Los datos de la base viven en un volumen con nombre: parar o\n'
        printf 'reiniciar los contenedores no los borra. Solo "destroy" lo hace.\n'
    } > "$summary"
    chmod 600 "$summary"

    printf '\n'
    cat "$summary"
    printf '\n'

    ok "Resumen guardado en ${summary} (contiene las claves: permisos 600)."
    [[ -n "${DEPLOYER_LOG_FILE:-}" ]] && hint "Log de la instalacion: ${DEPLOYER_LOG_FILE}"

    ROLLBACK_ARMED=0    # todo salio bien: ya no hay nada que deshacer
    return 0
}
