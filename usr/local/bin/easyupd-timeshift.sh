#!/usr/bin/env bash
# ==============================================================================
# Nombre: easyupd-timeshift.sh
# Descripción: Módulo de actualización del sistema y gestión inteligente de Timeshift
# Autor: Mark / Charlie (Co-Pilot)
# Fecha: 25 Octubre 2026
# ==============================================================================

set -eo pipefail

# Descomentar la linea 17 (# debugging) para activar el debugging:
debugging() {
	exec 5> /tmp/easyupd_timeshift_debug.log
	BASH_XTRACEFD=5
	set -x
}
# debugging

LOCKFILE="/tmp/easyupd-timeshift.lock"
exec 200>"$LOCKFILE"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m'

REAL_USER=${SUDO_USER:-$USER}
USER_ID=$(id -u "$REAL_USER" 2>/dev/null)

CACHE_DIR="/var/cache/easyupd_lab"
DISKS_REGISTRY="${CACHE_DIR}/snapshot_disks"

# Configuración de umbrales para Smart Backups
readonly MAX_USAGE_PCT=85         # Umbral máximo de uso de disco (85%)
readonly ESTIMATED_DELTA_MB=4096   # Margen predictivo estimado por snapshot (4 GB)

# Asegurar existencia del registro de discos de respaldo
if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
    chown root:easyupd "$CACHE_DIR" 2>/dev/null || true
    chmod 2775 "$CACHE_DIR"
fi

if [ ! -f "$DISKS_REGISTRY" ]; then
    touch "$DISKS_REGISTRY"
    chown root:easyupd "$DISKS_REGISTRY" 2>/dev/null || true
    chmod 664 "$DISKS_REGISTRY"
fi

spinner() {
    local pid=$1
    local mensaje=$2
    local delay=0.08
    local -a marks=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    tput civis
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%b ${yellow}%s${nc}   " "$mensaje" "${marks[$i]}"
        i=$(( (i + 1) % 10 ))
        sleep $delay
    done

    printf "\r%b ${green}[HECHO]${nc}\n" "$mensaje"
    tput cnorm
}

registrar_uuid() {
    local uuid_to_add="$1"
    if [ -n "$uuid_to_add" ] && ! grep -qxF "$uuid_to_add" "$DISKS_REGISTRY" 2>/dev/null; then
        echo "$uuid_to_add" >> "$DISKS_REGISTRY"
    fi
}

notificar() {
    local icono="$1" titulo="$2" mensaje="$3"
    if [ -n "$USER_ID" ]; then
        if [ "$EUID" -eq 0 ]; then
            sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
                notify-send -i "$icono" "$titulo" "$mensaje" 2>/dev/null
        else
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
                notify-send -i "$icono" "$titulo" "$mensaje" 2>/dev/null
        fi
    fi
}

if ! flock -n 200; then
    notificar "dialog-warning" "EasyUpd - Timeshift:" "Ya hay un proceso de respaldo en ejecución."
    exit 0
fi

run_root() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo -A "$@"
    fi
}

PATRON_SALIDA='rsync error|rsync: .*(failed|error)|Input/output error|I/O error|read error|write error|No space left|[Rr]ead-only file system'
PATRON_KERNEL='I/O error|Buffer I/O|blk_update_request|critical medium error|Unrecovered read error|Medium Error|EXT4-fs error|BTRFS.*error|XFS.*(error|corrupt)|Aborting journal|Remounting filesystem read-only|device offline|uas_eh|reset (high|full|super)-speed USB|USB disconnect|DID_NO_CONNECT|unable to enumerate|Cannot enable\. Maybe the USB cable is bad'

TS_LOG=$(mktemp /tmp/easyupd-timeshift.XXXXXX)
cleanup() { rm -f "$TS_LOG"; }
trap cleanup EXIT

esperar_enter() {
    echo -en "\n${yellow}Presiona [ENTER] para cerrar... ${nc}"
	read -n 1 -s -r
    echo ""
}

listar_snapshots() {
    run_root timeshift --list --scripted 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' \
        | sort -u
}

errores_kernel() {
    local desde="$1"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -k --since "@${desde}" --no-pager -q 2>/dev/null | grep -Ei "$PATRON_KERNEL"
    else
        dmesg 2>/dev/null | tail -n 500 | grep -Ei "$PATRON_KERNEL"
    fi
}

# ---------------------------------------------------------------------
# FUNCIONES SMART BACKUP: Control de Espacio y Purga Silenciosa
# ---------------------------------------------------------------------
evaluar_capacidad_disco() {
    local dev_path="$1"
    
    local mount_pt
    mount_pt=$(lsblk -no MOUNTPOINT "$dev_path" 2>/dev/null | grep -v '^$' | head -n1)
    
    local tmp_mounted=0
    if [ -z "$mount_pt" ]; then
        mount_pt="/tmp/easyupd_mnt_check"
        mkdir -p "$mount_pt"
        if run_root mount "$dev_path" "$mount_pt" 2>/dev/null; then
            tmp_mounted=1
        else
            echo "OK:0:0:0"
            return 0
        fi
    fi

    local total_mb used_mb avail_mb use_pct
    read -r total_mb used_mb avail_mb use_pct < <(df -BM --output=size,used,avail,pcent "$mount_pt" | tail -n1 | tr -d 'M%')

    if [ "$tmp_mounted" -eq 1 ]; then
        run_root umount "$mount_pt" 2>/dev/null || true
        rmdir "$mount_pt" 2>/dev/null || true
    fi

    local projected_used=$((used_mb + ESTIMATED_DELTA_MB))
    local projected_pct=$(( (projected_used * 100) / total_mb ))

    if [ "$projected_pct" -ge "$MAX_USAGE_PCT" ]; then
        echo "NEED_PURGE:$use_pct:$projected_pct:$avail_mb"
        return 1
    fi

    echo "OK:$use_pct:$projected_pct:$avail_mb"
    return 0
}

purgar_snapshot_mas_antiguo() {
    local oldest_snapshot
    oldest_snapshot=$(listar_snapshots | head -n 1)

    if [ -z "$oldest_snapshot" ]; then
        echo -e "${yellow}⚠ No hay snapshots antiguos para purgar en esta unidad.${nc}"
        return 1
    fi

    echo -e "${yellow}🧹 Purga inteligente: Eliminando snapshot más antiguo (${oldest_snapshot}) para liberar espacio...${nc}"
    notificar "edit-delete" "EasyUpd - Timeshift" "Optimizando espacio: purgando snapshot $oldest_snapshot"

    if run_root timeshift --delete --snapshot "$oldest_snapshot" --scripted &>/dev/null; then
        echo -e "${green}✔ Snapshot $oldest_snapshot eliminado correctamente.${nc}"
        return 0
    else
        echo -e "${red}✖ Falló la eliminación del snapshot $oldest_snapshot.${nc}"
        return 1
    fi
}

garantizar_espacio_suficiente() {
    local dev_path="$1"
    echo -e "${yellow}Evaluando capacidad disponible y proyección de delta...${nc}"

    while true; do
        local cap_status
        cap_status=$(evaluar_capacidad_disco "$dev_path")
        local code="${cap_status%%:*}"

        if [ "$code" == "OK" ]; then
            echo -e "${green}✔ Almacenamiento verificado dentro del margen seguro (<${MAX_USAGE_PCT}% y +4GB de delta).${nc}"
            break
        fi

        echo -e "${yellow}⚠ El espacio proyectado supera el umbral de seguridad del ${MAX_USAGE_PCT}%.${nc}"
        
        if ! purgar_snapshot_mas_antiguo; then
            echo -e "${red}✖ No fue posible liberar espacio suficiente en la unidad.${nc}"
            return 1
        fi
    done
}

# ---------------------------------------------------------------------
# MODO DE EJECUCIÓN Y SELECCIÓN DE DISPOSITIVO
# ---------------------------------------------------------------------
MODO="ULTIMO"
if [ "$1" = "--cambiar" ]; then
    MODO="CAMBIAR"
fi

if [ "$MODO" = "CAMBIAR" ]; then
    echo -e "${yellow}=== EasyUpd: Selección de nuevo dispositivo para Timeshift ===${nc}\n"
    echo -e "Buscando particiones disponibles con etiqueta 'timeshift'...\n"

    DEV_NUEVO=$(lsblk -lno PATH,LABEL | grep -i "timeshift" | awk '{print $1}' | head -n 1)

    if [ -z "$DEV_NUEVO" ]; then
        echo -e "${red}✖ Error: No se encontró ningún dispositivo conectado con la etiqueta 'timeshift'.${nc}"
        echo -e "${yellow}Asegúrate de que la partición del disco nuevo tenga asignada la etiqueta 'timeshift'.${nc}"
        notificar "dialog-error" "EasyUpd - Timeshift" "No se detectó la partición 'timeshift' en los discos conectados."
        esperar_enter
        exit 1
    fi

    NEW_UUID=$(blkid -s UUID -o value "$DEV_NUEVO" 2>/dev/null)
    if [ -z "$NEW_UUID" ]; then
        echo -e "${red}✖ Error: No se pudo obtener el UUID del dispositivo $DEV_NUEVO.${nc}"
        esperar_enter
        exit 1
    fi

    echo -e "${green}✔ Dispositivo detectado: ${DEV_NUEVO} (UUID: ${NEW_UUID})${nc}"
    echo -e "${yellow}Actualizando UUID de respaldo en /etc/timeshift/timeshift.json...${nc}"
    run_root sed -i -E "s/\"backup_device_uuid\"\s*:\s*\"[^\"]+\"/\"backup_device_uuid\" : \"$NEW_UUID\"/" /etc/timeshift/timeshift.json
    registrar_uuid "$NEW_UUID"
    echo -e "${green}✔ Configuración actualizada y unidad registrada con éxito.${nc}\n"
fi

# ---------------------------------------------------------------------
# USO DEL ÚLTIMO DISPOSITIVO / AUTO-CONMUTACIÓN A DISCO CONOCIDO
# ---------------------------------------------------------------------

# Si easyupd_yad_lab.sh nos pasó el dispositivo exacto, lo usamos sin buscar a ciegas
if [ "$1" = "--dispositivo" ] && [ -n "$2" ]; then
    DEV_PATH="$2"
    TS_UUID=$(blkid -s UUID -o value "$DEV_PATH" 2>/dev/null)
    echo -e "${green}✔ Usando dispositivo validado por el padre: ${DEV_PATH} (UUID: ${TS_UUID})${nc}"
else
    # Lógica original si se ejecuta suelto desde la terminal o por otra vía
    TS_UUID=$(grep -oP '"backup_device_uuid"\s*:\s*"\K[^"]+' /etc/timeshift/timeshift.json 2>/dev/null)

    [ -n "$TS_UUID" ] && registrar_uuid "$TS_UUID"

    if [ -z "$TS_UUID" ]; then
        echo -e "${yellow}⚠ No se encontró un UUID configurado en /etc/timeshift/timeshift.json.${nc}"
        echo -e "Abriendo Timeshift GTK para la configuración inicial..."
        exec sudo -A -E timeshift-gtk
    fi

    echo -e "${yellow}Buscando dispositivo de respaldo...${nc}"

	while true; do
		DEV_PATH=$(blkid -U "$TS_UUID" 2>/dev/null)

		if [ -z "$DEV_PATH" ]; then
			DEV_CANDIDATO=$(lsblk -lno PATH,LABEL 2>/dev/null | grep -i "timeshift" | awk '{print $1}' | head -n 1)
			if [ -n "$DEV_CANDIDATO" ]; then
				CANDIDATE_UUID=$(blkid -s UUID -o value "$DEV_CANDIDATO" 2>/dev/null)
				if [ -n "$CANDIDATE_UUID" ]; then
					if grep -qxF "$CANDIDATE_UUID" "$DISKS_REGISTRY" 2>/dev/null || [ -n "$DEV_CANDIDATO" ]; then
						echo -e "${yellow}ℹ Se detectó una unidad alternativa con respaldos/etiqueta 'timeshift' (${DEV_CANDIDATO}).${nc}"
						echo -e "${yellow}Conmutando UUID de respaldo automáticamente...${nc}"
						run_root sed -i -E "s/\"backup_device_uuid\"\s*:\s*\"[^\"]+\"/\"backup_device_uuid\" : \"$CANDIDATE_UUID\"/" /etc/timeshift/timeshift.json
						registrar_uuid "$CANDIDATE_UUID"
						TS_UUID="$CANDIDATE_UUID"
						DEV_PATH="$DEV_CANDIDATO"
					fi
				fi
			fi
		fi

		if [ -n "$DEV_PATH" ]; then
			echo -e "${green}✔ Dispositivo de respaldo detectado en ${DEV_PATH} (UUID: ${TS_UUID}).${nc}"

			MOUNT_POINT=$(lsblk -no MOUNTPOINT "$DEV_PATH" 2>/dev/null | grep -v '^$' || true)
			if [ -n "$MOUNT_POINT" ]; then
				echo -e "${yellow}Liberando punto de montaje previo en ${MOUNT_POINT}...${nc}"
				udisksctl unmount -b "$DEV_PATH" >/dev/null 2>&1 || umount "$DEV_PATH" 2>/dev/null || true
			fi

			notificar "drive-harddisk" "EasyUpd - Timeshift" "Dispositivo de respaldo detectado y listo."
			echo -e "${green}✔ Dispositivo listo.${nc}"
			break
		else
			echo -e "\n${red}✖ El dispositivo de respaldo no está conectado o no se detecta.${nc}"
			echo -e "${yellow}Por favor, conecta el disco de respaldo habitual o una unidad alternativa con la partición 'timeshift'.${nc}"
			echo -n "Presiona [ENTER] para reintentar la detección (o Ctrl+C para cancelar)... "
			read -r
		fi
	done
fi

# ---------------------------------------------------------------------
# EVALUACIÓN DE ESPACIO Y PURGA PREDICTIVA
# ---------------------------------------------------------------------
if ! garantizar_espacio_suficiente "$DEV_PATH"; then
    echo -e "\n${red}✖ Abortando: La unidad no cuenta con espacio suficiente para un nuevo respaldo.${nc}"
    notificar "dialog-error" "EasyUpd - Timeshift" "Respaldo cancelado: Espacio insuficiente en la unidad."
    esperar_enter
    exit 1
fi

# ---------------------------------------------------------------------
# CREACIÓN DEL SNAPSHOT Y VALIDACIÓN ROBUSTA
# ---------------------------------------------------------------------
echo -e "\n${yellow}Registrando snapshots existentes...${nc}"
SNAPS_ANTES=$(listar_snapshots)
START_EPOCH=$(date +%s)

echo -e ""
run_root timeshift --create --comments "Snapshot Preventivo (EasyUpd)" --scripted > "$TS_LOG" 2>&1 &
# TS_EXIT=${PIPESTATUS[0]}
TS_PID=$!

spinner "$TS_PID" "Creando Snapshot Preventivo, por favor espere..."
wait "$TS_PID"
TS_EXIT=$?

echo -e "\n${yellow}Verificando el resultado del respaldo...${nc}"

PROBLEMAS=()
ERR_SALIDA=$(sed 's/\x1b\[[0-9;]*m//g' "$TS_LOG" | grep -Ei "$PATRON_SALIDA" | head -n 5 || true)
if [ -n "$ERR_SALIDA" ]; then
    PROBLEMAS+=("La salida de Timeshift contiene mensajes de error de rsync/disco:
$(echo "$ERR_SALIDA" | sed 's/^/      /')")
fi

SNAPS_DESPUES=$(listar_snapshots)
SNAP_NUEVO=$(comm -13 <(printf '%s\n' "$SNAPS_ANTES" | grep -v '^$') \
                      <(printf '%s\n' "$SNAPS_DESPUES" | grep -v '^$'))

if [ -z "$SNAP_NUEVO" ]; then
    PROBLEMAS+=("No apareció ningún snapshot nuevo en la lista de Timeshift.")
fi

if [ "$TS_EXIT" -ne 0 ]; then
    if grep -q "Failed to remove directory" "$TS_LOG" && [ -n "$SNAP_NUEVO" ] && [ -z "$ERR_SALIDA" ]; then
        echo -e "${yellow}ℹ Nota: Timeshift finalizó el respaldo correctamente pero dejó un aviso menor de limpieza temporal (no crítico).${nc}"
    else
        PROBLEMAS+=("Timeshift terminó con código de error ${TS_EXIT}.")
    fi
fi

ERR_KERNEL=$(errores_kernel "$START_EPOCH" | tail -n 5 || true)

if [ -n "$ERR_KERNEL" ]; then
    PROBLEMAS+=("El kernel registró errores de disco/USB durante el respaldo:
$(echo "$ERR_KERNEL" | sed 's/^/      /')")
fi

if [ "${#PROBLEMAS[@]}" -eq 0 ]; then
    echo -e "\n${green}✔ Snapshot creado y verificado exitosamente: ${SNAP_NUEVO}${nc}"
    
    # --- REGISTRO DEL ÚLTIMO SNAPSHOT EXITOSO ---
    SUCCESS_DATE=$(date +'%Y-%m-%d')
    {
        echo "UUID=$TS_UUID"
        echo "DATE=$SUCCESS_DATE"
    } > "${CACHE_DIR}/easyupd_last_snapshot"
    chown root:easyupd "${CACHE_DIR}/easyupd_last_snapshot" 2>/dev/null || true
    chmod 664 "${CACHE_DIR}/easyupd_last_snapshot" 2>/dev/null || true

    # Forzar actualización instantánea del tooltip en el tray
    TRAY_PID=$(pgrep -u "$REAL_USER" -f "easyupd-tray_lab.sh" | head -n 1)
    [ -n "$TRAY_PID" ] && kill -SIGUSR2 "$TRAY_PID" 2>/dev/null
    # ---------------------------------------------

    notificar "document-save" "EasyUpd - Timeshift" "El Snapshot preventivo se creó y verificó correctamente."
    
    echo -e "\n${green}Proceso completado con éxito.${nc}"
    esperar_enter
    exit 0
fi

echo -e "\n${red}✖ El respaldo NO se completó correctamente:${nc}"
for p in "${PROBLEMAS[@]}"; do
    echo -e "${red}  • ${p}${nc}"
done

cp -f "$TS_LOG" /var/log/easyupd_timeshift_last.log 2>/dev/null \
    && echo -e "\n${yellow}Salida completa guardada en /var/log/easyupd_timeshift_last.log${nc}"

notificar "dialog-error" "EasyUpd - Timeshift" "El snapshot FALLÓ o quedó incompleto. Revisa la consola."
esperar_enter
exit 1
