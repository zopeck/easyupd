#!/usr/bin/env bash
# /usr/local/bin/sysupd-daemon_lab.sh
# Servicio residente (Backend Root) para EasyUpd.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Validaciones de entorno
# shellcheck source=/usr/local/bin/easyupd/bash_colors
source /usr/local/bin/easyupd/bash_colors
bash_colors

# shellcheck source=/usr/local/bin/easyupd/check_os_family
source /usr/local/bin/easyupd/check_os_family
if ! check_os_family; then
    sleep 3
    exit 1
fi

INICIO="$(cat /proc/1/comm)"
[ "$INICIO" != "systemd" ] && { echo "El sistema no es compatible con systemd, saliendo..."; sleep 3; exit 1; }

[ -f /usr/local/bin/easyupd/check_internet ] && source /usr/local/bin/easyupd/check_internet
[ -f /usr/local/bin/easyupd/check_apt_lock ] && source /usr/local/bin/easyupd/check_apt_lock
[ -f /usr/local/bin/easyupd/sleep_time ] && source /usr/local/bin/easyupd/sleep_time

SLEEP_TIME=${SLEEP_TIME:-10800}

# =====================================================================
# 1. DIRECTORIO DE CACHÉ GLOBAL Y CONTROL DE PERMISOS
# =====================================================================
CACHE_DIR="/var/cache/easyupd_lab"

if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
fi
chown root:easyupd "$CACHE_DIR" 2>/dev/null || true
chmod 2775 "$CACHE_DIR"

CACHE_AUTO_MODE="${CACHE_DIR}/auto_mode"
if [ ! -f "$CACHE_AUTO_MODE" ]; then
    echo "0" > "$CACHE_AUTO_MODE"
fi
chown root:easyupd "$CACHE_AUTO_MODE" 2>/dev/null || true
chmod 664 "$CACHE_AUTO_MODE"

CACHE_PENDING_COUNT="${CACHE_DIR}/pending_count"
CACHE_PENDING_LIST="${CACHE_DIR}/pending_list"
CACHE_STATUS="${CACHE_DIR}/status"
CACHE_NEXT_CHECK="${CACHE_DIR}/next_check"
CACHE_LAST_APT="${CACHE_DIR}/last_apt_update"
CACHE_AUTO_REASON="${CACHE_DIR}/auto_reason"
LOG_HISTORICO="/var/log/easyupd_lab.log"

for f in "$CACHE_PENDING_COUNT" "$CACHE_PENDING_LIST" "$CACHE_STATUS" "$CACHE_NEXT_CHECK" "$CACHE_LAST_APT"; do
    [ ! -f "$f" ] && touch "$f"
    chown root:easyupd "$f" 2>/dev/null || true
    chmod 664 "$f" 2>/dev/null || true
done

if [ ! -f "$CACHE_NEXT_CHECK" ] || [ ! -s "$CACHE_NEXT_CHECK" ]; then
    AHORA=$(date +%s)
    PROXIMA_RUN=$(( AHORA + SLEEP_TIME ))
    echo "$PROXIMA_RUN" > "$CACHE_NEXT_CHECK"
fi

# Saneamiento preventivo tras reinicio
if [ -f "$CACHE_STATUS" ]; then
    PREV_STATUS=$(cat "$CACHE_STATUS" 2>/dev/null)
    if [ "$PREV_STATUS" = "UPDATING" ]; then
        if ! pgrep -x "apt-get" >/dev/null && ! pgrep -x "dpkg" >/dev/null; then
            echo "RED" > "$CACHE_STATUS"
            rm -f "$CACHE_AUTO_REASON" 2>/dev/null
        fi
    fi
fi

sleep 5

# =====================================================================
# 2. MANEJO DE SEÑALES (IPC)
# =====================================================================
DESPIERTA_YA=0
RAZON_DESPERTAR=""

capturar_forzado() {
    DESPIERTA_YA=1
    RAZON_DESPERTAR="FORZADO_MANUAL"
}
trap 'capturar_forzado' SIGUSR1

capturar_resume() {
    DESPIERTA_YA=1
    RAZON_DESPERTAR="RESUME_SUSPENSION"
}
trap 'capturar_resume' SIGUSR2

sleep_interrumpible() {
    local target_epoch=$1
    DESPIERTA_YA=0
    while [ "$(date +%s)" -lt "$target_epoch" ] && [ "$DESPIERTA_YA" -eq 0 ]; do
        sleep 2
    done
}

sleep 3

registrar_log_auto() {
    local mensaje="$1"
    local estado="$2"
    local origen="${3:-MODO AUTOMATICO}"
    [ ! -f "$LOG_HISTORICO" ] && { touch "$LOG_HISTORICO"; chmod 664 "$LOG_HISTORICO"; chown root:easyupd "$LOG_HISTORICO" 2>/dev/null || true; }
    {
        echo ""
        echo ">>> ACTUALIZACIÓN EASYUPD: $(date +'%Y-%m-%d %H:%M:%S') <<< - $origen"
        printf '%b\n' "$mensaje"
        echo "Estatus de salida: $estado"
        echo "-------------------------------------------------------"
    } >> "$LOG_HISTORICO"
}

# =====================================================================
# 3. BUCLE PRINCIPAL DE MONITOREO
# =====================================================================
while true; do
    if [ -f /usr/local/bin/easyupd/sleep_time ]; then
		source /usr/local/bin/easyupd/sleep_time
	 fi
    SLEEP_TIME=${SLEEP_TIME:-10800}
    AHORA=$(date +%s)

    if [ -f "$CACHE_NEXT_CHECK" ]; then
        PROXIMA_PROGRAMADA=$(cat "$CACHE_NEXT_CHECK" 2>/dev/null || echo 0)
        if [ "$AHORA" -lt "$PROXIMA_PROGRAMADA" ] && [ "$DESPIERTA_YA" -eq 0 ]; then
            sleep_interrumpible "$PROXIMA_PROGRAMADA"
            AHORA=$(date +%s)
            if [ "$AHORA" -lt "$PROXIMA_PROGRAMADA" ] && [ "$DESPIERTA_YA" -eq 0 ]; then
                continue
            fi
        fi
    fi

    case "$RAZON_DESPERTAR" in
        "FORZADO_MANUAL")     MODO_EJECUCION="MODO FORZADO MANUAL" ;;
        "RESUME_SUSPENSION") MODO_EJECUCION="MODO REANUDACIÓN TRAS SUSPENSIÓN" ;;
        *)                   MODO_EJECUCION="MODO AUTOMATICO" ;;
    esac

    DESPIERTA_YA=0
    RAZON_DESPERTAR=""

    if type check_internet &>/dev/null && ! check_internet; then
        REINTENTOS=0
        CONEXION_OK=0
        while [ $REINTENTOS -lt 3 ]; do
            sleep 60
            if check_internet; then CONEXION_OK=1; break; fi
            ((REINTENTOS++))
        done

        if [ $CONEXION_OK -eq 0 ]; then
            echo "OFFLINE" > "$CACHE_STATUS"
            AHORA=$(date +%s)
            PROXIMA_RUN=$(( AHORA + SLEEP_TIME ))
            echo "$PROXIMA_RUN" > "$CACHE_NEXT_CHECK"
            sleep_interrumpible "$PROXIMA_RUN"
            continue
        fi
    fi

    if type check_apt_lock &>/dev/null && ! check_apt_lock; then
        sleep 30
        continue
    fi

    # apt-get update -qq

	if type check_apt_lock &>/dev/null && ! check_apt_lock; then
        # APT está ocupado por Synaptic, dpkg u otra terminal.
        # Esperamos un lapso corto y reintentamos en la siguiente iteración sin alterar el next_check.
        sleep 30
        continue
    fi
     
    # 1. Refresco silencioso de la base de datos de repositorios (Root):
    APT_UPDATE_LOG=$(mktemp /tmp/easyupd_apt_update.XXXXXX)
    
    if apt-get update -qq 2> "$APT_UPDATE_LOG"; then
        # Verificar si hubo advertencias de sockets caídos a pesar del éxito parcial
        if grep -qE "(Could not wait for server fd|Recurso no disponible temporalmente)" "$APT_UPDATE_LOG"; then
            registrar_log_auto "AVISO: El refresco de APT completó con advertencias de red/espejos (EAGAIN/Timeout en sockets)." "ADVERTENCIA DE RED" "$MODO_EJECUCION"
        fi
    else
        registrar_log_auto "AVISO: Falló la sincronización periódica de APT con los repositorios remotos." "ERROR DE RED" "$MODO_EJECUCION"
    fi
    rm -f "$APT_UPDATE_LOG"

    # 2. Cálculo de deltas y paquetes actualizables:
    apt-get -s dist-upgrade | awk '/^Inst/ {print $2}' > "$CACHE_PENDING_LIST"

    LC_ALL=C apt-get -s dist-upgrade | awk '/^Inst/ {print $2}' > "$CACHE_PENDING_LIST"

    COUNT=$(grep -c '[^[:space:]]' "$CACHE_PENDING_LIST" 2>/dev/null)
    COUNT=${COUNT:-0}
    printf "%d" "$COUNT" > "$CACHE_PENDING_COUNT"

    AHORA=$(date +%s)
    PROXIMA_RUN=$(( AHORA + SLEEP_TIME ))
    echo "$PROXIMA_RUN" > "$CACHE_NEXT_CHECK"

    touch "$CACHE_LAST_APT"

    AUTO_STATE=$(tr -cd '0-1' 2>/dev/null < "$CACHE_AUTO_MODE")
    AUTO_STATE=${AUTO_STATE:-0}

    if [ "$COUNT" -gt 0 ]; then
        if [ "$AUTO_STATE" -eq 1 ]; then
            SIMULACION=$(LC_ALL=C apt-get -s dist-upgrade 2>&1)

            IF_STRUCTURAL=0
            if echo "$SIMULACION" | grep -qiE "NEW packages|REMOVED|DOWNGRADED"; then
                IF_STRUCTURAL=1
            fi

            if [ "$IF_STRUCTURAL" -eq 1 ]; then
                echo "0" > "$CACHE_AUTO_MODE"
                echo "STRUCTURAL" > "$CACHE_AUTO_REASON"
                echo "RED" > "$CACHE_STATUS"

                registrar_log_auto "AVISO: Se detectaron paquetes que requieren instalación de nuevas dependencias, eliminación o downgrade.\nAcción: Modo Automático suspendido. Se requiere snapshot preventivo en disco externo e intervención manual." "Revisar el sistema, se requiere intervencion manual" "$MODO_EJECUCION"
            else
                echo "UPDATING" > "$CACHE_STATUS"
                
                TRAY_PID=$(pgrep -f "easyupd-tray_lab.sh" | head -n 1)
                [ -n "$TRAY_PID" ] && kill -SIGUSR2 "$TRAY_PID" 2>/dev/null

                DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
                  -o Dpkg::Options::="--force-confdef" \
                  -o Dpkg::Options::="--force-confold" > /var/log/easyupd_auto_exec.log 2>&1

                EXIT_CODE=$?
                dpkg --audit > /dev/null 2>&1
                AUDIT_CODE=$?

                if [ "$EXIT_CODE" -eq 0 ] && [ "$AUDIT_CODE" -eq 0 ]; then
                    printf "0" > "$CACHE_PENDING_COUNT"
                    true > "$CACHE_PENDING_LIST"
                    rm -f "$CACHE_AUTO_REASON"
                    echo "GREEN" > "$CACHE_STATUS"
                    registrar_log_auto "CHEQUEO: Cambios realizados exitosamente. No quedo nada pendiente." "OK" "$MODO_EJECUCION"

                    PAQS_INSTALADOS=$(grep "Upgrade:" /var/log/apt/history.log 2>/dev/null | tail -n 1 | sed 's/Upgrade: //g')
                    [ -z "$PAQS_INSTALADOS" ] && PAQS_INSTALADOS="Paquetes actualizados correctamente."

                    registrar_log_auto "Paquetes procesados en segundo plano:\n  • $PAQS_INSTALADOS" "Actualizacion OK"
                else
                    echo "EXEC_ERROR" > "$CACHE_AUTO_REASON"
                    echo "RED" > "$CACHE_STATUS"
                    registrar_log_auto "ERROR CRÍTICO: La actualización automática no finalizó correctamente.\nRevisar /var/log/easyupd_auto_exec.log y los logs del sistema." "Revisar el sistema, ocurrieron errores" "$MODO_EJECUCION"
                fi
            fi
        else
            ALERTA_CRITICA=0
            if [ -f "$CACHE_LAST_APT" ]; then
                ULTIMA_VEZ=$(stat -c %Y "$CACHE_LAST_APT")
                if (( AHORA - ULTIMA_VEZ > 15 * 86400 )); then
                    ALERTA_CRITICA=1
                fi
            fi

            rm -f "$CACHE_AUTO_REASON" 2>/dev/null

            if [ "$ALERTA_CRITICA" -eq 1 ]; then
                echo "CRITICAL" > "$CACHE_STATUS"
            else
                echo "RED" > "$CACHE_STATUS"
            fi
        fi
    else
        rm -f "$CACHE_AUTO_REASON" 2>/dev/null
        echo "GREEN" > "$CACHE_STATUS"
        registrar_log_auto "CHEQUEO: Sistema al día. No hay paquetes pendientes." "OK" "$MODO_EJECUCION"
    fi

    AHORA=$(date +%s)
    PROXIMA_GUARDADA=$(cat "$CACHE_NEXT_CHECK" 2>/dev/null || echo 0)

    if [ "$RAZON_DESPERTAR" != "FORZADO_MANUAL" ] && (( PROXIMA_GUARDADA > AHORA )); then
        PROXIMA_RUN="$PROXIMA_GUARDADA"
    else
        PROXIMA_RUN=$(( AHORA + SLEEP_TIME ))
        echo "$PROXIMA_RUN" > "$CACHE_NEXT_CHECK"
    fi

    touch "$CACHE_LAST_APT"
    sleep_interrumpible "$PROXIMA_RUN"
done

# CONCEPTOS CLAVE DE GESTION GNU/LINUX UTILIZADOS EN ESTA SOLUCION:
# -----------------------------------------------------------------
# Gestión de Señales POSIX (trap & SIGUSR1):
#		La técnica utilizada en sleep_interrumpible evita el consumo innecesario de ciclos de CPU (polling
#		activo) mientras mantiene una respuesta instantánea frente a eventos del usuario.

# IPC mediante Sistema de Archivos (/var/cache/easyupd_lab):
#		Es el patrón decoupled (desacoplado) clásico en UNIX: el demonio (Backend de fondo) escribe estados
#		simples en archivos de texto plano y las aplicaciones de usuario (Frontend Tray) los leen sin depender
#		de sockets complejos o D-Bus.

# Manejo Desatendido de APT (DEBIAN_FRONTEND=noninteractive):
#		Indispensable para automatizaciones en entornos de servidores o servicios de fondo, evitando que la
#		instalación se congelen esperando una confirmación por teclado (dpkg-reconfigure).


