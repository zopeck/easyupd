#!/usr/bin/env bash
# =====================================================================
# EasyUpd - Ajustar Frecuencia de Chequeo
# =====================================================================

CONFIG_FILE="/usr/local/bin/easyupd/sleep_time"
CACHE_DIR="/var/cache/easyupd_lab"

# Inicialización defensiva de la estrategia de entorno gráfico
USE_RUNUSER=0

# =====================================================================
# HEREDAR APARIENCIA GTK / TEMA OSCURO DEL USUARIO REAL
# =====================================================================
REAL_USER=${SUDO_USER:-$USER}

if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    REAL_UID=$(id -u "$REAL_USER")
    
    export DISPLAY="${DISPLAY:-:0}"
    export XDG_RUNTIME_DIR="/run/user/${REAL_UID}"
    export XAUTHORITY="${REAL_HOME}/.Xauthority"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus"

    XFSETTINGS_XML="${REAL_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
    if [ -f "$XFSETTINGS_XML" ]; then
        USER_GTK_THEME=$(grep 'name="ThemeName"' "$XFSETTINGS_XML" | awk -F'"' '{print $6}' | tr -d ' \r')
    fi

    if [ -z "$USER_GTK_THEME" ]; then
        GTK_INI="${REAL_HOME}/.config/gtk-3.0/settings.ini"
        if [ -f "$GTK_INI" ]; then
            USER_GTK_THEME=$(grep -Ei "^gtk-theme-name" "$GTK_INI" | cut -d'=' -f2 | tr -d ' \r')
        fi
    fi

    TEMA_EN_HOME="${REAL_HOME}/.local/share/themes/${USER_GTK_THEME}"

    if [ -n "$USER_GTK_THEME" ] && [ -d "$TEMA_EN_HOME" ]; then
        USE_RUNUSER=1
    elif [ -n "$USER_GTK_THEME" ] && [ -d "/usr/share/themes/${USER_GTK_THEME}" ]; then
        [ "$USER_GTK_THEME" = "Adwaita-dark" ] && USER_GTK_THEME="Adwaita:dark"
        export GTK_THEME="$USER_GTK_THEME"
        USE_RUNUSER=0
    else
        export GTK_THEME="Adwaita:dark"
        USE_RUNUSER=0
    fi
fi

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

CURRENT_SECONDS=${SLEEP_TIME:-10800}
CURRENT_MINUTES=$(( CURRENT_SECONDS / 60 ))

# =====================================================================
# EJECUCIÓN DE YAD
# =====================================================================
YAD_ARGS=(
    --entry
    --title="EasyUpd - Ajustar Frecuencia"
    --text="<span font='Ubuntu Mono 13'><b>Ajustar intervalo de revisión</b></span>\n\nIngrese la frecuencia de chequeo en <b>minutos</b>:\n<i>(Ejemplos: 5 = 5 min, 60 = 1 hora, 180 = 3 horas)</i>"
    --entry-text="$CURRENT_MINUTES"
    --image="preferences-system-time"
    --window-icon="easyupd_green"
    --undecorated
    --center
    --width=380
    --button="Cancelar:1"
    --button="Aceptar:0"
)

if [ "$USE_RUNUSER" -eq 1 ]; then
    NUEVO_MINUTOS=$(runuser -u "$REAL_USER" -- env \
        DISPLAY="$DISPLAY" \
        XAUTHORITY="$XAUTHORITY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        yad "${YAD_ARGS[@]}" 2>/dev/null)
    EXIT_YAD=$?
else
    NUEVO_MINUTOS=$(yad "${YAD_ARGS[@]}" 2>/dev/null)
    EXIT_YAD=$?
fi

if [ $EXIT_YAD -ne 0 ] || [ -z "$NUEVO_MINUTOS" ]; then
    exit 0
fi

if ! [[ "$NUEVO_MINUTOS" =~ ^[0-9]+$ ]] || [ "$NUEVO_MINUTOS" -le 0 ]; then
    if [ "$USE_RUNUSER" -eq 1 ]; then
        runuser -u "$REAL_USER" -- env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            yad --error --title="EasyUpd" --text="Error: Ingrese un número entero válido mayor a cero." --button="Aceptar:0" --center --undecorated 2>/dev/null
    else
        yad --error --title="EasyUpd" --text="Error: Ingrese un número entero válido mayor a cero." --button="Aceptar:0" --center --undecorated 2>/dev/null
    fi
    exit 1
fi

NUEVO_SEGUNDOS=$(( NUEVO_MINUTOS * 60 ))

echo "SLEEP_TIME=$NUEVO_SEGUNDOS" > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

AHORA=$(date +%s)
PROXIMA_RUN=$(( AHORA + NUEVO_SEGUNDOS ))
echo "$PROXIMA_RUN" > "${CACHE_DIR}/next_check"

DAEMON_PID=$(pgrep -f "/usr/local/bin/sysupd-daemon_lab.sh" | head -n 1)
[ -n "$DAEMON_PID" ] && kill -SIGUSR1 "$DAEMON_PID" 2>/dev/null

TRAY_PID=$(pgrep -f "easyupd-tray_lab.sh" | head -n 1)
[ -n "$TRAY_PID" ] && kill -SIGUSR2 "$TRAY_PID" 2>/dev/null

if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    runuser -u "$REAL_USER" -- env DISPLAY="$DISPLAY" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" \
        notify-send -i preferences-system-time "EasyUpd" "Frecuencia actualizada a ${NUEVO_MINUTOS} minutos." 2>/dev/null
else
    notify-send -i preferences-system-time "EasyUpd" "Frecuencia actualizada a ${NUEVO_MINUTOS} minutos." 2>/dev/null
fi
