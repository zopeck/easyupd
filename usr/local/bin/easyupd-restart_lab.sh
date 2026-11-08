#!/usr/bin/env bash

SERVICE="sysupd_lab.service"
TITULO="EasyUpd - Reinicio de Servicio"

# 1. Verificar el estado actual directamente en systemd
if systemctl is-active --quiet "$SERVICE"; then
    ACCION="restart"
    MENSAJE_OK="El servicio de Chequeo de Actualizaciones ha sido REINICIADO exitosamente."
    MENSAJE_ERR="Error al intentar **reiniciar** el servicio o fue cancelado por el usuario."
else
    ACCION="start"
    MENSAJE_OK="Chequeo de Actualizaciones estaba detenido, ha sido INICIADO exitosamente."
    MENSAJE_ERR="Error al intentar **iniciar** el servicio o fue cancelado por el usuario."
fi

# 2. Ejecutar la acción con privilegios
if sudo systemctl "$ACCION" "$SERVICE"; then
    # Diálogo de éxito
	echo -e "$MENSAJE_OK" | yad --text-info \
	    --class="EasyUpdRestartService" \
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
    # Diálogo de error (si el usuario cancela pkexec o falla systemd)
	echo -e "$MENSAJE_ERR" | yad --text-info \
	    --class="EasyUpdRestartService" \
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
