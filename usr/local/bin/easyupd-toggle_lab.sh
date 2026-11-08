#!/usr/bin/env bash

SERVICE="sysupd_lab.service"
TITULO="EasyUpd - Control de Servicio"

# 1. Verificar el estado actual directamente en systemd
if systemctl is-active --quiet "$SERVICE"; then
    ACCION="stop"
    MENSAJE_OK="El servicio de Chequeo de Actualizaciones ha sido **DETENIDO** exitosamente."
    MENSAJE_ERR="Error al intentar **detener** el servicio o fue cancelado por el usuario."
else
    ACCION="start"
    MENSAJE_OK="El servicio de Chequeo de Actualizaciones ha sido **INICIADO** exitosamente."
    MENSAJE_ERR="Error al intentar **iniciar** el servicio o fue cancelado por el usuario."
fi

# Función auxiliar para notificar al Tray sin demoras
notificar_tray() {
    local TRAY_PID
    TRAY_PID=$(pgrep -f "easyupd-tray_lab.sh" | head -n 1)
    [ -n "$TRAY_PID" ] && kill -SIGUSR2 "$TRAY_PID" 2>/dev/null
}

# 2. Ejecutar la acción con privilegios
if sudo systemctl "$ACCION" "$SERVICE"; then
    # Notificar al Tray DE INMEDIATO en segundo plano
    notificar_tray &

    # Diálogo de éxito (desacoplado)
    echo -e "$MENSAJE_OK" | yad --text-info \
        --class="EasyUpdServiceStatus" \
        --title="$TITULO" \
        --skip-taskbar \
        --width=600 \
        --height=80 \
        --fontname="Ubuntu Mono 14" \
        --wrap \
        --fore="#FFFFFF" \
        --back="#1E1E1E" \
        --undecorated \
        --no-buttons \
        --timeout=5 \
        --close-on-unfocus 2>/dev/null &
    exit 0
else
    # Notificar al Tray por si hubo cambio parcial de estado
    notificar_tray &

    # Diálogo de error (si el usuario cancela o falla systemd)
    echo -e "$MENSAJE_ERR" | yad --text-info \
        --class="EasyUpdServiceStatus" \
        --title="$TITULO" \
        --skip-taskbar \
        --width=600 \
        --height=80 \
        --fontname="Ubuntu Mono 14" \
        --wrap \
        --fore="#FFFFFF" \
        --back="#1E1E1E" \
        --undecorated \
        --no-buttons \
        --timeout=5 \
        --close-on-unfocus 2>/dev/null &
    exit 1
fi
