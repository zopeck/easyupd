#!/usr/bin/env bash
# /usr/local/bin/easyupd-tray_lab.sh
# Frontend de usuario para EasyUpd (Residente en sesión XFCE)

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SUDO_ASKPASS="/usr/bin/ssh-askpass"
export NO_AT_BRIDGE=1

CACHE_DIR="/var/cache/easyupd_lab"
PIPE_YAD="/tmp/easyupd_yad_lab_${USER}.fifo"
SLEEP_TIME_FILE="/usr/local/bin/easyupd/sleep_time"

# Lectura tolerante de la caché: archivo ausente, vacío o a medio escribir => valor por defecto.
leer_num()  { local v; v=$(tr -cd '0-9' 2>/dev/null < "$1"); echo "${v:-${2:-0}}"; }
leer_flag() { local v; v=$(tr -cd '0-1' 2>/dev/null < "$1"); echo "${v:-0}"; }

# =====================================================================
# 1. CONTROL DE INSTANCIA ÚNICA, PID Y LANZADORES
# =====================================================================
TMP_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PID_FILE="${TMP_DIR}/easyupd-tray_${USER}.pid"

if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        exit 0
    fi
fi

echo $$ > "$PID_FILE"

SCRIPT_INTERNO=$(mktemp -p "$TMP_DIR" easyupd_launch.XXXXXX)
cat << 'EOF' > "$SCRIPT_INTERNO"
#!/usr/bin/env bash
/usr/local/bin/easyupd_yad_lab.sh
EOF
chmod +x "$SCRIPT_INTERNO"

SCRIPT_AVISO_VERDE=$(mktemp -p "$TMP_DIR" easyupd_aviso.XXXXXX)
cat << 'EOF' > "$SCRIPT_AVISO_VERDE"
#!/usr/bin/env bash
GTK_CSSPROVIDER=$(mktemp)
echo "window { border-radius: 12px; background-color: @theme_bg_color; }" > "$GTK_CSSPROVIDER"

if ! pgrep -f "Aviso del Sistema EasyUpd" > /dev/null 2>&1; then
	GTK_CUSTOM_CSS="$GTK_CSSPROVIDER" yad --title='Aviso del Sistema EasyUpd' \
	--text='<span font="Ubuntu Mono 24" weight="bold">\n¡Felicidades!</span>\n<span font="Ubuntu Mono 18">Tu sistema está al día.</span>\n' \
	--text-align=center --geometry=300x40+900+680 --undecorated --no-buttons --timeout=10 --skip-taskbar 2>/dev/null
fi
rm -f "$GTK_CSSPROVIDER"
EOF
chmod +x "$SCRIPT_AVISO_VERDE"

# Script Auxiliar para el Toggle del Modo Automático
SCRIPT_TOGGLE_AUTO=$(mktemp -p "$TMP_DIR" easyupd_toggle_auto.XXXXXX)
cat << 'EOF' > "$SCRIPT_TOGGLE_AUTO"
#!/usr/bin/env bash
TMP_DIR="${XDG_RUNTIME_DIR:-/tmp}"
CACHE_AUTO="/var/cache/easyupd_lab/auto_mode"
TRAY_PID_FILE="${TMP_DIR}/easyupd-tray_${USER}.pid"

CUR_STATE=$(tr -cd '0-1' 2>/dev/null < "$CACHE_AUTO")
CUR_STATE=${CUR_STATE:-0}

if [ "$CUR_STATE" -eq 1 ]; then
    printf "0" > "$CACHE_AUTO"
    notify-send -i system-run "EasyUpd" "Modo Automático: DESACTIVADO"
else
    printf "1" > "$CACHE_AUTO"
    notify-send -i system-run "EasyUpd" "Modo Automático: ACTIVADO"
fi

# Notificar al demonio backend de forma directa
DAEMON_PID=$(pgrep -u "$USER" -f "/usr/local/bin/sysupd-daemon_lab.sh" | head -n 1)
[ -n "$DAEMON_PID" ] && kill -SIGUSR1 "$DAEMON_PID" 2>/dev/null

# Notificar exclusivamente al PID del notificador para actualizar Tooltip
if [ -f "$TRAY_PID_FILE" ]; then
    TRAY_PID=$(cat "$TRAY_PID_FILE" 2>/dev/null)
    [ -n "$TRAY_PID" ] && kill -SIGUSR2 "$TRAY_PID" 2>/dev/null
fi
EOF
chmod +x "$SCRIPT_TOGGLE_AUTO"

cleanup() {
    rm -f "$PIPE_YAD" "$SCRIPT_INTERNO" "$SCRIPT_AVISO_VERDE" "$SCRIPT_TOGGLE_AUTO" "$PID_FILE"
    pkill -P $$ yad 2>/dev/null
}
# INT/TERM deben terminar el script (y recién ahí corre cleanup vía EXIT);
# sin 'exit' el script seguía vivo hasta 10 s tras "Cerrar Notificador".
trap cleanup EXIT
trap 'exit 0' INT TERM

# =====================================================================
# 2. CREACIÓN DE TUBERÍA PARA YAD
# =====================================================================
rm -f "$PIPE_YAD"
mkfifo "$PIPE_YAD"

# =====================================================================
# 3. FUNCIÓN DE GENERACIÓN DE MENÚ CONTEXTUAL
# =====================================================================
generar_menu() {
    local CUR_STATUS
    CUR_STATUS=$(cat "${CACHE_DIR}/status" 2>/dev/null || echo GREEN)

    if [ "$CUR_STATUS" = "UPDATING" ]; then
        local O_BLOQUEADO="Proceso de actualización en curso...!notify-send -i dialog-warning 'EasyUpd' 'Operación no permitida mientras hay una actualización en curso.'!dialog-warning"
        local O_LOGS_RECIENTES="Ver Últimos Registros!sh -c '/usr/local/bin/easyupd-logview_lab.sh ultimos'!utilities-terminal"
        local O_LOGS_COMPLETO="Ver Histórico Completo!sh -c '/usr/local/bin/easyupd-logview_lab.sh completo'!document-open-recent"
        local O_EXIT="Cerrar Notificador!kill $$!application-exit"

        echo "${O_BLOQUEADO}|----------------------------|${O_LOGS_RECIENTES}|${O_LOGS_COMPLETO}|----------------------------|${O_EXIT}"
    else
        local O_FORZAR="Forzar Chequeo Ahora!sakura -c 120 -r 20 -f 'Ubuntu Mono Regular 14' -t 'EasyUpd - Chequeo Forzado' -e bash -c 'sudo /usr/local/bin/easyupd_yad_lab.sh -f'!view-refresh"
        local O_LOGS_RECIENTES="Ver Últimos Registros!sh -c '/usr/local/bin/easyupd-logview_lab.sh ultimos'!utilities-terminal"
        local O_LOGS_COMPLETO="Ver Histórico Completo!sh -c '/usr/local/bin/easyupd-logview_lab.sh completo'!document-open-recent"
        
		local O_TS_ULTIMO="Crear Snapshot Preventivo (Último disco)!sakura -c 120 -r 20 -f 'Ubuntu Mono Regular 14' -t 'EasyUpd - Timeshift' -e bash -c 'sudo /usr/local/bin/easyupd-timeshift.sh --ultimo'!document-save"
		local O_TS_CAMBIAR="Cambiar disco de respaldo (partición 'timeshift')!sakura -c 120 -r 20 -f 'Ubuntu Mono Regular 14' -t 'EasyUpd - Timeshift (Cambiar Disco)' -e bash -c 'sudo /usr/local/bin/easyupd-timeshift.sh --cambiar'!drive-multidisk"

        local O_SLEEP="Ajustar Frecuencia Chequeo (Root)!sudo -A /usr/local/bin/easyupd-set-sleep.sh!preferences-system-time"
        local O_RESTART="Reiniciar Servicio (Root)!sudo -A /usr/local/bin/easyupd-restart_lab.sh!view-refresh"

		# --- DETECCIÓN DINÁMICA DEL ESTADO DEL SERVICIO ---
        local TEXTO_TOGGLE
        if pgrep -f "sysupd-daemon_lab.sh" >/dev/null 2>&1; then
            TEXTO_TOGGLE="Detener Servicio (Root)"
        else
            TEXTO_TOGGLE="Iniciar Servicio (Root)"
        fi
        local O_TOGGLE="${TEXTO_TOGGLE}!sudo -A /usr/local/bin/easyupd-toggle_lab.sh!system-run"
        
        local CUR_AUTO
        CUR_AUTO=$(leer_flag "${CACHE_DIR}/auto_mode")

        local TEXTO_AUTO
        if [ "$CUR_AUTO" -eq 1 ]; then
            TEXTO_AUTO="Conmutar Modo Automático a \"[OFF]\""
        else
            TEXTO_AUTO="Conmutar Modo Automático a \"[ON]\""
        fi
        local O_AUTO="${TEXTO_AUTO}!$SCRIPT_TOGGLE_AUTO!system-run"

        local O_EXIT="Cerrar Notificador!kill $$!application-exit"

        echo "${O_FORZAR}|${O_LOGS_RECIENTES}|${O_LOGS_COMPLETO}|${O_TS_ULTIMO}|${O_TS_CAMBIAR}|----------------------------|${O_SLEEP}|${O_RESTART}|${O_TOGGLE}|----------------------------|${O_AUTO}|----------------------------|${O_EXIT}"
    fi
}

COMP_MENU=$(generar_menu)

# =====================================================================
# 4. TRAP Y SLEEP INTERRUMPIBLE PARA INSTANT REFRESH (SIGUSR2)
# =====================================================================
FORZAR_REFRESCO_GUI=0
capturar_refresco_gui() {
    FORZAR_REFRESCO_GUI=1
}
trap 'capturar_refresco_gui' SIGUSR2

sleep_interrumpible() {
    local segundos_totales=$1
    local transcurridos=0
    while [ "$transcurridos" -lt "$segundos_totales" ] && [ "$FORZAR_REFRESCO_GUI" -eq 0 ]; do
        sleep 1
        ((transcurridos++))
    done
}

# Función auxiliar para leer el último snapshot exitoso
obtener_info_ultimo_snapshot() {
    local snap_file="${CACHE_DIR}/easyupd_last_snapshot"
    if [ -f "$snap_file" ]; then
        local u d
        u=$(grep '^UUID=' "$snap_file" | cut -d= -f2)
        d=$(grep '^DATE=' "$snap_file" | cut -d= -f2)
        if [ -n "$u" ] && [ -n "$d" ]; then
            echo "Snapshot UUID disco: $u, fecha: $d"
        fi
    fi
}

# =====================================================================
# 5. LECTURA ESTÁTICA DE COMPATIBILIDAD Y LANZAMIENTO DE YAD
# =====================================================================
exec 3<> "$PIPE_YAD"

INIT_COUNT=$(leer_num "${CACHE_DIR}/pending_count")
INIT_STATUS=$(cat "${CACHE_DIR}/status" 2>/dev/null)
INIT_STATUS=${INIT_STATUS:-GREEN}
INIT_REASON=$(cat "${CACHE_DIR}/auto_reason" 2>/dev/null || echo "")
INIT_AUTO=$(leer_flag "${CACHE_DIR}/auto_mode")
INIT_SLEEP=$(grep -Eo '[0-9]+' "$SLEEP_TIME_FILE" 2>/dev/null || echo 10800)
INIT_NEXT_RUN=$(leer_num "${CACHE_DIR}/next_check")

[ "$INIT_AUTO" -eq 1 ] && AUTO_TAG="[ON]" || AUTO_TAG="[OFF]"

if [ "$INIT_COUNT" -gt 0 ] && [ "$INIT_STATUS" = "GREEN" ]; then
    INIT_STATUS="RED"
fi

NOW=$(date +%s)
if [ -n "$INIT_NEXT_RUN" ] && [ "$INIT_NEXT_RUN" -gt 0 ]; then
    if [ "$NOW" -gt "$INIT_NEXT_RUN" ]; then
        INIT_HORA="Comprobando..."
        INIT_FECHA="Hoy"
    else
        INIT_HORA="$(date -d "@$INIT_NEXT_RUN" +"%H:%M")"
        INIT_FECHA="$(date -d "@$INIT_NEXT_RUN" +"%d %b")"
        [ "$INIT_FECHA" = "$(date +'%d %b')" ] && INIT_FECHA="Hoy"
    fi
else
    INIT_FECHA="Hoy"
    INIT_HORA="--:--"
fi

SNAP_LINE=$(obtener_info_ultimo_snapshot)
if [ -n "$SNAP_LINE" ]; then
    INIT_AUTO_INFO="Modo automático: $AUTO_TAG"$'\n'"Revisión cada: $(( INIT_SLEEP / 60 )) min."$'\n'"$SNAP_LINE"
else
    INIT_AUTO_INFO="Modo automático: $AUTO_TAG"$'\n'"Revisión cada: $(( INIT_SLEEP / 60 )) min."
fi

if [ "$INIT_STATUS" = "UPDATING" ]; then
    INIT_IMAGE="easyupd_red"
    INIT_TEXT="⏳ En proceso de descarga/actualización del sistema..."$'\n'"$INIT_AUTO_INFO"
    INIT_CMD="true"
elif [ "$INIT_STATUS" = "RED" ] || [ "$INIT_STATUS" = "CRITICAL" ]; then
    INIT_IMAGE="easyupd_red"
    if [ "$INIT_REASON" = "STRUCTURAL" ]; then
        INIT_TEXT="⚠️ Modo Auto Suspendido: Requiere intervención."
    elif [ "$INIT_REASON" = "EXEC_ERROR" ]; then
        INIT_TEXT="❌ Error en el registro del sistema."
    else
        [ "$INIT_COUNT" -eq 1 ] && INIT_TEXT="🔴 1 actualización disponible."$'\n'"$INIT_AUTO_INFO" || INIT_TEXT="🔴 ${INIT_COUNT} actualizaciones disponibles."$'\n'"$INIT_AUTO_INFO"
    fi
    INIT_CMD="sakura -c 120 -r 20 -f 'Ubuntu Mono Regular 14' -t 'EasyUpd - Actualizador' -e $SCRIPT_INTERNO"
else
    INIT_IMAGE="easyupd_green"
    INIT_TEXT="🟢 Sistema al día. Próxima revisión: ${INIT_FECHA} - ${INIT_HORA}"$'\n'"$INIT_AUTO_INFO"
    INIT_CMD="$SCRIPT_AVISO_VERDE &"
fi

# Lectura única y eficiente de la bandera generada por el postinst
TRAY_MODE=$(cat "${CACHE_DIR}/tray_backend" 2>/dev/null || echo "NATIVE_TRAY")

if [ "$TRAY_MODE" = "NATIVE_TRAY" ]; then
    yad --notification \
        --listen \
        --image="$INIT_IMAGE" \
        --text="$INIT_TEXT" \
        --menu="$COMP_MENU" \
        --command="$INIT_CMD" < "$PIPE_YAD" 2>/dev/null &
    YAD_PID=$!
else
    if ! yad --notification \
        --listen \
        --image="$INIT_IMAGE" \
        --text="$INIT_TEXT" \
        --menu="$COMP_MENU" \
        --command="$INIT_CMD" < "$PIPE_YAD" 2>/dev/null & then
        
        notify-send -i "$INIT_IMAGE" "EasyUpd - Servicio Activo" "El motor corre en segundo plano (Bandeja no disponible)."
        
        while true; do
            sleep 60
            CURRENT_STATUS=$(cat "${CACHE_DIR}/status" 2>/dev/null)
            if [ "$CURRENT_STATUS" = "RED" ] || [ "$CURRENT_STATUS" = "CRITICAL" ]; then
                notify-send -u critical -i software-update-urgent "EasyUpd - Atención" "Hay actualizaciones pendientes en el sistema."
                sleep 3600
            fi
        done &
        YAD_PID=$!
    else
        YAD_PID=$!
    fi
fi

if [ "$INIT_COUNT" -gt 0 ] && [ "$INIT_STATUS" != "UPDATING" ]; then
    notify-send -i system-software-update "EasyUpd: Actualizaciones disponibles" "Se encontraron ${INIT_COUNT} paquetes listos para instalar."
fi

sleep 1.5

# =====================================================================
# 6. BUCLE RECEPTOR DE ESTADO
# =====================================================================
# Inicializamos las variables de control de estado con los valores REALES de la Sección 5
ULTIMO_ESTADO="$INIT_STATUS"
ULTIMO_COUNT="$INIT_COUNT"
ULTIMA_PROXIMA_RUN="$INIT_NEXT_RUN"
ULTIMO_AUTO="$INIT_AUTO"
ULTIMA_REASON="$INIT_REASON"
ULTIMO_SLEEP="$INIT_SLEEP"
ULTIMO_SRV_ACTIVE=$(pgrep -f "sysupd-daemon_lab.sh" >/dev/null 2>&1; echo $?)

while kill -0 "$YAD_PID" 2>/dev/null; do
    SLEEP_TIME=$(grep -Eo '[0-9]+' "$SLEEP_TIME_FILE" 2>/dev/null || echo 10800)
    if [ -f "${CACHE_DIR}/status" ]; then

        STATUS=$(cat "${CACHE_DIR}/status" 2>/dev/null)
        STATUS=${STATUS:-GREEN}
        COUNT=$(leer_num "${CACHE_DIR}/pending_count")
        NEXT_RUN=$(leer_num "${CACHE_DIR}/next_check")
        CUR_AUTO=$(leer_flag "${CACHE_DIR}/auto_mode")
        CUR_REASON=$(cat "${CACHE_DIR}/auto_reason" 2>/dev/null || echo "")

        # Lectura en tiempo real del estado del servicio backend
        SRV_ACTIVE=$(pgrep -f "sysupd-daemon_lab.sh" >/dev/null 2>&1; echo $?)

        [ "$CUR_AUTO" -eq 1 ] && AUTO_TAG="[ON]" || AUTO_TAG="[OFF]"

        # Evaluación estricta de cambios reales (incluye estado del servicio)
        if [ "$STATUS" != "$ULTIMO_ESTADO" ] || [ "$SLEEP_TIME" != "$ULTIMO_SLEEP" ] || [ "$COUNT" != "$ULTIMO_COUNT" ] || [ "$NEXT_RUN" != "$ULTIMA_PROXIMA_RUN" ] || [ "$CUR_REASON" != "$ULTIMA_REASON" ] || [ "$CUR_AUTO" != "$ULTIMO_AUTO" ] || [ "$SRV_ACTIVE" != "$ULTIMO_SRV_ACTIVE" ] || [ "$FORZAR_REFRESCO_GUI" -eq 1 ]; then
            FORZAR_REFRESCO_GUI=0
            
            NOW=$(date +%s)
            if [ -n "$NEXT_RUN" ] && [ "$NEXT_RUN" -gt 0 ]; then
                if [ "$NOW" -gt "$NEXT_RUN" ]; then
                    HORA="Comprobando..."
                    FECHA="Hoy"
                else
                    HORA="$(date -d "@$NEXT_RUN" +"%H:%M")"
                    FECHA="$(date -d "@$NEXT_RUN" +"%d %b")"
                    [ "$FECHA" = "$(date +'%d %b')" ] && FECHA="Hoy"
                fi
            else
                FECHA="Hoy"
                HORA="--:--"
            fi

			SNAP_LINE=$(obtener_info_ultimo_snapshot)
			if [ -n "$SNAP_LINE" ]; then
				AUTO_INFO="Modo automático: $AUTO_TAG"$'\n'"Revisión cada: $(( SLEEP_TIME / 60 )) min."$'\n'"$SNAP_LINE"
			else
				AUTO_INFO="Modo automático: $AUTO_TAG"$'\n'"Revisión cada: $(( SLEEP_TIME / 60 )) min."
			fi

			case "$STATUS" in
                "GREEN")
                    IMAGE="easyupd_green"
                    TEXT="🟢 Sistema al día. Próxima revisión: ${FECHA} - ${HORA}"$'\n'"${AUTO_INFO}"
                    CMD="$SCRIPT_AVISO_VERDE &"
                    ;;    

                "UPDATING")
                    IMAGE="easyupd_red"
                    TEXT="⏳ Actualizando el sistema, por favor espere..."$'\n'"$AUTO_INFO"
                    CMD="true"
                    ;;

                "OFFLINE")
                    if [ "$COUNT" -gt 0 ]; then
                        IMAGE="easyupd_red"
                        TEXT="🟠 Pendientes: ${COUNT} (Sin conexión a Internet)."$'\n'"$AUTO_INFO"
                    else
                        IMAGE="easyupd_green"
                        TEXT="🟢 Sin conexión. Última revisión omitida."$'\n'"$AUTO_INFO"
                    fi
                    CMD="$SCRIPT_AVISO_VERDE &"
                    ;;

                "RED")
                    IMAGE="easyupd_red"
                    CMD="sakura -c 120 -r 20 -f 'Ubuntu Mono Regular 14' -t 'EasyUpd - Actualizador' -e $SCRIPT_INTERNO"
                    
                    if [ "$CUR_REASON" = "STRUCTURAL" ]; then
                        TEXT="⚠️ Modo Auto Suspendido: Se requiere acción."
                    elif [ "$CUR_REASON" = "EXEC_ERROR" ]; then
                        TEXT="❌ La actualización terminó con errores."
                    else
                        [ "$COUNT" -eq 1 ] && TEXT="🔴 1 actualización disponible."$'\n'"$AUTO_INFO" || TEXT="🔴 ${COUNT} actualizaciones disponibles."$'\n'"$AUTO_INFO"
                    fi

                    if [ "$COUNT" != "$ULTIMO_COUNT" ] && [ "$COUNT" -gt 0 ]; then
                        notify-send -i system-software-update "EasyUpd: Actualizaciones disponibles" "Se encontraron ${COUNT} paquetes listos para instalar."
                    fi
                    ;;

                "CRITICAL")
                    IMAGE="easyupd_red"
                    TEXT="🔥 URGENTE: ${COUNT} paquetes pendientes."$'\n'"$AUTO_INFO"
                    CMD="sakura -c 120 -r 20 -f 'Ubuntu Mono Regular 14' -t 'EasyUpd - Actualizador' -e $SCRIPT_INTERNO"
                    notify-send -u critical -i software-update-urgent "¡Atención URGENTE!" "El sistema lleva más de 15 días sin actualizarse. Hay ${COUNT} paquetes urgentes."
                    ;;

                *)
                    IMAGE="easyupd_red"
                    TEXT="❓ Estado desconocido"$'\n'"$AUTO_INFO"
                    CMD="true"
                    ;;
            esac

            # --- REGENERACIÓN DINÁMICA DEL MENÚ DE YAD SI CAMBIA CUALQUIER ESTADO O PARÁMETRO ---
            if [ "$STATUS" != "$ULTIMO_ESTADO" ] || [ "$CUR_AUTO" != "$ULTIMO_AUTO" ] || [ "$SLEEP_TIME" != "$ULTIMO_SLEEP" ] || [ "$SRV_ACTIVE" != "$ULTIMO_SRV_ACTIVE" ] || { [ "$STATUS" = "UPDATING" ] || [ "$ULTIMO_ESTADO" = "UPDATING" ]; }; then
                COMP_MENU=$(generar_menu)

                kill "$YAD_PID" 2>/dev/null
                wait "$YAD_PID" 2>/dev/null
                
                exec 3>&-
                exec 3<> "$PIPE_YAD"

                yad --notification \
                    --listen \
                    --image="$IMAGE" \
                    --text="$TEXT" \
                    --menu="$COMP_MENU" \
                    --command="$CMD" < "$PIPE_YAD" 2>/dev/null &
                YAD_PID=$!
            else
                TEXT_FIFO=$(echo "$TEXT" | sed ':a;N;$!ba;s/\n/\\n/g')
                printf "icon:%s\n" "$IMAGE" >&3
                printf "tooltip:%s\n" "$TEXT_FIFO" >&3
                printf "action:%s\n" "$CMD" >&3
            fi

            # Actualización de variables de control para la siguiente iteración
            ULTIMO_ESTADO="$STATUS"
            ULTIMO_COUNT="$COUNT"
            ULTIMA_PROXIMA_RUN="$NEXT_RUN"
            ULTIMA_REASON="$CUR_REASON"
            ULTIMO_AUTO="$CUR_AUTO"
            ULTIMO_SLEEP="$SLEEP_TIME"
            ULTIMO_SRV_ACTIVE="$SRV_ACTIVE"
        fi
    fi

    sleep_interrumpible 10
done
