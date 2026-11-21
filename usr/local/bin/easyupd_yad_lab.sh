#!/usr/bin/env bash

FECHA="$( date +'%Y-%m-%d_%H:%M:%S' )"

if [ -f /usr/local/bin/easyupd/sleep_time ]; then
    source /usr/local/bin/easyupd/sleep_time
fi
SLEEP_TIME=${SLEEP_TIME:-10800}

# =====================================================================
# DETECCIÓN ROBUSTA DE USUARIO Y CONFIGURACIÓN DE SESIÓN
# =====================================================================
REAL_USER="${SUDO_USER}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    # Extraemos el nombre de usuario (tercera columna) en lugar del UID numérico
    REAL_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | head -n1)
    [ -z "$REAL_USER" ] && REAL_USER=$(who | awk '($NF ~ /:0|[0-9]/) {print $1; exit}')
    [ -z "$REAL_USER" ] && REAL_USER="${USER:-mark}"
fi

REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SESSION_USER="${REAL_HOME}/.easyupd_lab_last_auth"
GRACE_PERIOD=900
INFO="false"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SESSION_USER="${REAL_HOME}/.easyupd_lab_last_auth"
GRACE_PERIOD=900
INFO="false"

CACHE_DIR="/var/cache/easyupd_lab"
CACHE_AUTO_MODE="${CACHE_DIR}/auto_mode"
CACHE_AUTO_REASON="${CACHE_DIR}/auto_reason"

APTERRORS=""

FORCE=0
PAQUETES=()

for arg in "$@"; do
    case "$arg" in
        "-f" | "--force" ) FORCE=1 ;;
        "-i" | "--info"  ) INFO="true" ;;
        * ) PAQUETES+=("$arg") ;;
    esac
done

# ------------------ FUNCIONES ------------------

validar_repositorios() {
    echo -e "${yellow}Validando disponibilidad de repositorios...${nc}"
    local REPO_URL
    REPO_URL=$(grep -h '^URIs:' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null | awk '{print $2}' | head -n 1)

    if [ -z "$REPO_URL" ]; then
        REPO_URL=$(grep -ve '^#' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep 'http' | head -n 1 | awk '{print $2}')
    fi

    if [ -n "$REPO_URL" ]; then
        if curl -Is --connect-timeout 3 "$REPO_URL" > /dev/null; then
            echo -e "✔ ${green}El servidor remoto responde: ($REPO_URL)${nc}"
            return 0
        else
            echo -e "✘ ${red}El servidor de repositorio no responde o el enlace está roto.${nc}"
            return 1
        fi
    else
        echo -e "⚠ ${yellow}No se pudieron identificar URLs de repositorios para validar.${nc}"
        return 0
    fi
}

es_interactivo() {
    local pkgs="$*" 
    local lista_completa
    lista_completa=$(LC_ALL=C apt-get -s install "$pkgs" 2>/dev/null | grep "^Inst" | awk '{print $2}' )
    echo -e "\t\u23F3 ${green}Validando info, por favor espere...${nc}"
    echo ""

    [[ -z "$lista_completa" ]] && return 1

    if LC_ALL=C apt-cache depends "$lista_completa" 2>/dev/null | grep -qEi "Depend.*: debconf|PreDepend.*: debconf|Depend.*: debconf-2.0"; then
        return 0
    fi

    return 1
}

ejecutar_con_seguridad() {
    local comando="$1"

    if ! eval "$comando"; then
        if fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
            echo -e "${red}[!] ERROR DE BLOQUEO:${nc} El sistema de paquetes está ocupado."
            echo -e "${yellow}Sugerencia:${nc} Cierra Synaptic o espera a que terminen otras tareas."
            exit 1
        else
            echo -e "${red}[!] ERROR CRÍTICO:${nc} Falló la ejecución de: $comando"
            echo -e "${yellow}Iniciando diagnóstico de red...${nc}"

            if ! validar_repositorios; then
                echo -e "${red}[!] El problema parece ser de conectividad o del servidor remoto.${nc}"
            else
                echo -e "${cyan}[i] El servidor responde. El error podría ser de sintaxis o integridad de paquetes.${nc}"
            fi
            exit 1
        fi
    fi
}

spinner() {
    local pid=$1
    local mensaje=$2
    local delay=0.08
    local -a marks=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    tput civis
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%b ${Bcyan}%s${nc}  " "$mensaje" "${marks[$i]}"
        i=$(( (i + 1) % 10 ))
        sleep $delay
    done

    printf "\r%b ${Bgreen}[HECHO]${nc}\n" "$mensaje"
    tput cnorm
}

obtener_descripcion_corta() {
    local pkg="$1"
    local desc=""
    desc=$(LC_ALL=C apt-cache show "$pkg" 2>/dev/null | grep -i "^Description-es:" | head -n 1 | cut -d' ' -f2-)
    if [ -z "$desc" ]; then
        desc=$(LC_ALL=C apt-cache show "$pkg" 2>/dev/null | grep -Ei "^(Description:|Description-en:)" | head -n 1 | cut -d' ' -f2-)
    fi
    echo "${desc:-Sin descripción disponible.}"
}

analizar_comportamiento_apt() {
    echo -e "\t\U1F50D ${cyan}Analizando cambios estructurales y consistencia...${nc}"

    local SIMULACION
    SIMULACION=$(LC_ALL=C apt-get -s dist-upgrade 2>&1)

    local tiene_downgrade=0
    local tiene_cambios_propios_dist=0

    if echo "$SIMULACION" | grep -qi "DOWNGRADED"; then
        tiene_downgrade=1
    fi

    if echo "$SIMULACION" | grep -qiE "NEW packages|REMOVED"; then
        tiene_cambios_propios_dist=1
    fi

    if [ "$tiene_downgrade" -eq 1 ] || [ "$tiene_cambios_propios_dist" -eq 1 ]; then
        echo -e "\n${red}⚠️  ATENCIÓN: La actualización requiere cambios críticos:${nc}"

        if [ "$tiene_downgrade" -eq 1 ]; then
            echo -e "  - Se detectó un ${yellow}DOWNGRADE${nc} (reversión de versión)."
            echo -e "${red}Paquetes que se desactualizarán:${nc}"
            echo "$SIMULACION" | sed -n '/DOWNGRADED/,/siguientes paquetes|following/p' | grep -vE "following|packages" | sed 's/^/    • /'
        fi

        if [ "$tiene_cambios_propios_dist" -eq 1 ]; then
            echo -e "  - El sistema necesita ${yellow}instalar nuevos paquetes o eliminar obsoletos (Cambio Estructural)${nc}."
        fi

        echo ""
        local DISCO_ENCONTRADO=0
        local DEV_TARGET=""

        while [ "$DISCO_ENCONTRADO" -eq 0 ]; do
            clear
            echo -e "${green}=====================================================${nc}"
            echo -e "       ${yellow}CONTROL DE RESPALDO PREVENTIVO (Timeshift)${nc}"
            echo -e "${green}=====================================================${nc}"
            echo -e "La presente actualización requiere cambios críticos en la estructura del sistema."
            echo -e "Por seguridad, es ${Bred}ESTRICTAMENTE REQUERIDO${nc} realizar un snapshot previo."
            echo ""
            echo -e "Por favor, ${cyan}CONECTE el dispositivo externo${nc} que contiene"
            echo -e "la partición dedicada con la etiqueta '${yellow}timeshift${nc}'"
            echo -e "y espere algunos segundos mientras se automonta el disco."
            echo ""
            echo "-----------------------------------------------------"
            read -n 1 -s -r -p "Presione cualquier tecla cuando esté listo para verificar... (Ctrl+C para salir)"
            echo -e "\n\n${cyan}Buscando partición en los buses del sistema...${nc}"
            sleep 1

            if lsblk -o LABEL | grep -qi "timeshift"; then
                DISCO_ENCONTRADO=1
                DEV_TARGET=$(lsblk -lno PATH,LABEL | grep -i "timeshift" | awk '{print $1}' | head -n 1)
                echo -e "\t✔ ${Bgreen}¡Dispositivo detectado exitosamente! ($DEV_TARGET)${nc}\n"
                sleep 2
            else
                echo -e "\t❌ ${red}Error: No se encontró ninguna partición llamada 'timeshift'.${nc}"
                echo -e "Asegúrese de que el disco esté bien conectado. Reintentando..."
                sleep 3
            fi
        done

        echo -e "\t➡ ${cyan}Abriendo proceso de sincronización en terminal dedicada...${nc}"
        
        export yellow nc green cyan Bgreen red Bcyan
        
		SNAP_STATUS_TMP=$(mktemp /tmp/easyupd_snap_status.XXXXXX)
        echo 1 > "$SNAP_STATUS_TMP"

		sakura -c 120 -r 20 -f "Ubuntu Mono Regular 14" \
        -t "EasyUpd - Sincronización de Snapshot" \
        -e bash -c "
            stdbuf -oL -eL sudo /usr/local/bin/easyupd-timeshift.sh --dispositivo '$DEV_TARGET'
            EXIT_SNAP=\$?
            echo \$EXIT_SNAP > '$SNAP_STATUS_TMP'
            if [ \$EXIT_SNAP -eq 0 ]; then
                echo -e '\n${green}✔ Snapshot consolidado con éxito.${nc}'
            elif [ \$EXIT_SNAP -eq 2 ]; then
                echo -e '\n${yellow}⚠ Respaldo NO confiable. Lea el detalle indicado arriba.${nc}'
            else
                echo -e \"\n\${red}✖ El proceso finalizó con código de error: \$EXIT_SNAP\${nc}\"
            fi            echo -e '${green}Cerrando ventana en 3 segundos...${nc}'
            sleep 3
            exit 0
        "

        STATUS_SNAPSHOT=$(cat "$SNAP_STATUS_TMP" 2>/dev/null || echo 1)
        rm -f "$SNAP_STATUS_TMP"

        if [ "$STATUS_SNAPSHOT" -eq 0 ]; then
            echo -e "\t✔ ${green}Snapshot consolidado con éxito.${nc}\n"
            sleep 1.5
        elif [ "$STATUS_SNAPSHOT" -eq 2 ]; then
            echo -e "\t❌ ${Bred}RESPALDO NO CONFIABLE${nc}"
            echo -e "\tSe creó un snapshot, pero durante la copia se detectaron fallos en el disco."
            echo -e "\t${yellow}No se puede garantizar que sirva para restaurar el sistema.${nc}"
            echo -e "\tRecomendación: cancele, revise cable, puerto y disco, y repita el respaldo.\n"
            echo -e "\tPara continuar de todos modos, SIN un respaldo confiable, escriba ${red}CONTINUAR${nc}."
            echo -e -n "\tCualquier otra respuesta cancela la actualización: "
            read -r CONFIRMA_RIESGO
            if [ "$CONFIRMA_RIESGO" != "CONTINUAR" ]; then
                echo -e "\n${yellow}Operación abortada. No se aplicaron cambios.${nc}"
                exit 0
            fi
        else
            echo -e "\t❌ ${red}El respaldo NO se creó.${nc}"
            echo -e "\t${yellow}No existe un respaldo válido previo a esta actualización.${nc}\n"
            echo -e -n "¿Desea abortar la actualización por seguridad? (${green}s${nc}/${red}n${nc}): "
            read -r -n 1 ABORTAR_ACT
            echo -e "\n"
            echo ""
            if [ "$ABORTAR_ACT" = "s" ] || [ -z "$ABORTAR_ACT" ]; then
                echo -e "${yellow}Operación abortada por el usuario. No se aplicaron cambios.${nc}"
                exit 0
            fi
        fi

        [ "$tiene_downgrade" -eq 1 ] && return 10
        return 1
    fi
    return 0
}

preguntar_reactivacion_auto() {
    echo ""
    echo -e "${cyan}-------------------------------------------------------${nc}"
    read -r -n 1 -p "¿Desea reactivar el Modo Automático para próximos chequeos? (s/n): " REAUTO
    echo ""
    if [ "$REAUTO" = "s" ]; then
        echo "1" > "$CACHE_AUTO_MODE"
        echo -e "\t✔ ${green}Modo Automático reactivado con éxito.${nc}"
    fi
}

mostrar_y_preguntar() {
    local COUNT="$1"

    if [ "$COUNT" -gt 0 ]; then
        echo -e "Hay ${yellow}$COUNT${nc} paquetes pendientes de actualización."
        echo -e -n "¿Ver lista con descripción? (${green}s${nc}/${red}n${nc}): "
        read -r -n 1 RESPUESTA
        echo -e "\n"

        if [ "$RESPUESTA" = "s" ]; then
            echo ""
            while read -r pkg; do
                local desc_corta
                desc_corta=$(obtener_descripcion_corta "$pkg")
                echo -e "\t• ${green}$pkg${nc}"
                echo -e "\t  ${white}→ $desc_corta${nc}\n"
            done < "$CACHE_PENDING_LIST"
        fi

        echo ""
        echo -e -n "¿Actualizar ahora? (${green}s${nc}/${red}n${nc}): "
        read -r -n 1 RESPUESTA
        echo -e "\n"

        if [ "$RESPUESTA" = "s" ]; then
            analizar_comportamiento_apt
            local STATUS_ANALISIS=$?

            local CMD_UPGRADE="sudo apt-get dist-upgrade -y"

            if [ "$STATUS_ANALISIS" -eq 10 ]; then
                CMD_UPGRADE="sudo apt-get dist-upgrade -y --allow-downgrades"
            fi

            local STATUS_UPGRADE=1

            if es_interactivo "$(cat "$CACHE_PENDING_LIST")"; then
                echo -e "${Byellow}¡Aviso!${nc} Se detectó que alguno de los paquetes podría necesitar intervenir"
                echo -e "\ten la configuración del sistema. Por prevención, pasamos al modo de instalación"
                echo -e "\tinteractivo, ${yellow}por favor esté atento a esta sesión de EasyUpd${nc}. Gracias.\n"
                echo -e "\t\u27A1 Abriendo sub-proceso de actualización en terminal Sakura..."

                UPG_STATUS_TMP=$(mktemp /tmp/easyupd_upg_status.XXXXXX)
                echo 1 > "$UPG_STATUS_TMP"

                sakura -c 120 -r 20 -f "Ubuntu Mono Regular 14" -t "EasyUpd - Proceso Interactivo" -e bash -c "
                    echo -e '${yellow}=== EASYUPD: PROCESO INTERACTIVO DE APT ===${nc}\n'
                    $CMD_UPGRADE
                    EXIT_STATUS=\${PIPESTATUS[0]}
                    echo \$EXIT_STATUS > '$UPG_STATUS_TMP'
                    read -t 1 -n 10000 discard 2>/dev/null
                    echo -e '\n${green}Proceso finalizado. Presiona Enter para cerrar esta ventana...${nc}'
                    read -r
                    exit 0
                "

                STATUS_UPGRADE=$(cat "$UPG_STATUS_TMP" 2>/dev/null || echo 1)
                rm -f "$UPG_STATUS_TMP"
            else
                MENSAJE="Actualizando el sistema..."
                ejecutar_con_seguridad "$CMD_UPGRADE > /dev/null &"
                PID=$!
                spinner $PID "$MENSAJE"
                wait $PID
                STATUS_UPGRADE=$?
            fi

            if [ "$STATUS_UPGRADE" -eq 0 ]; then
                echo -e "\t\u2714 ${Bgreen}Sistema actualizado exitosamente.${nc}"

                local LOG_HISTORICO="/var/log/easyupd_lab.log"
                [ ! -f "$LOG_HISTORICO" ] && { sudo touch "$LOG_HISTORICO"; sudo chmod 664 "$LOG_HISTORICO"; sudo chown root:easyupd "$LOG_HISTORICO" 2>/dev/null || true; }

                sleep 1

                if [ -f /var/log/apt/history.log ]; then
                    local BLOQUE_LOG
                    BLOQUE_LOG=$(awk '
                        /^Start-Date:/ { 
                            buf = "Fecha inicio: " $2 " " $3 "\n" 
                            next 
                        }
                        /^Upgrade:/   { buf = buf "Actualizados:\n" $0 "\n"; next }
                        /^Install:/   { buf = buf "Instalados nuevos:\n" $0 "\n"; next }
                        /^Commandline:/ || /^Requested-By:/ { next }
                        /^End-Date:/   { 
                            ultimo_bloque = buf 
                        }
                        END { print ultimo_bloque }
                    ' /var/log/apt/history.log | sed -e 's/Upgrade: //g' -e 's/), /)\n/g' -e 's/^/  • /' 2>/dev/null)

                    if [ -n "$BLOQUE_LOG" ] && echo "$BLOQUE_LOG" | grep -q '[^[:space:]]'; then
                        {
                            echo ""
                            echo ">>> ACTUALIZACIÓN EASYUPD: $(date +'%Y-%m-%d %H:%M:%S') <<<"
                            echo "$BLOQUE_LOG"
                            echo "-------------------------------------------------------"
                        } | sudo tee -a "$LOG_HISTORICO" > /dev/null
                    else
                        echo -e "\n>>> ACTUALIZACIÓN EASYUPD: $(date +'%Y-%m-%d %H:%M:%S') <<<\n  • Paquetes actualizados correctamente (Ver /var/log/apt/history.log para detalles).\n-------------------------------------------------------" | sudo tee -a "$LOG_HISTORICO" > /dev/null
                    fi
                fi

                printf "0" > "$CACHE_PENDING_COUNT"
                true > "$CACHE_PENDING_LIST"
                echo "GREEN" > "${CACHE_DIR}/status"
                rm -f "${CACHE_DIR}/update_postponed" 2>/dev/null
                rm -f "$CACHE_AUTO_REASON" 2>/dev/null

                preguntar_reactivacion_auto
            else
                echo -e "\t${red}⚠ Error durante la actualización. El sistema conserva el estado pendiente.${nc}"
            fi
        else
            echo -e "\t\u25BB ${green}Sin cambios. Estado pendiente conservado.${nc}"
            printf '%s' "$COUNT" > "$CACHE_PENDING_COUNT"
            cp "$CACHE_PENDING_LIST" "${CACHE_DIR}/update_postponed" 2>/dev/null
        fi
    else
        echo -e "\t\u2714 ${green}Sistema completamente actualizado.${nc}"
    fi
}

ejecutar_autoremove() {
    local huerfanos
    huerfanos=$(LC_ALL=C apt-get -s autoremove | grep -c '^Remv')

    if [ "$huerfanos" -gt 0 ]; then
        if [ "$huerfanos" -gt "1" ]; then
            SINGPAQ="paquetes"
            SINGOBS="obsoletos"
        else
            SINGPAQ="paquete"
            SINGOBS="obsoleto"
        fi
        local msg="Limpiando sistema ($huerfanos $SINGPAQ $SINGOBS)..."
        ejecutar_con_seguridad "sudo apt-get autoremove -y > /dev/null 2>&1 &"
        local pid=$!
        spinner $pid "$msg"
        wait $pid
        echo -e "\t\u2714 ${green}Paquetes obsoletos/huerfanos eliminados.${nc}"
    fi

    echo -e "\n${yellow}Vaciando caché de paquetes (.deb)...${nc}"

    if [ -z "$(find /var/cache/apt/archives/ -maxdepth 1 -type f -name "*.deb" -print -quit)" ]; then
        echo -e "\t\u2714 ${green}La cache ya estaba vacia.${nc}"
    else
        ejecutar_con_seguridad "sudo apt-get clean"
        echo -e "\t\u2714 ${green}Cache vaciada exitosamente${nc}"
    fi

    sudo touch "$CACHE_LAST_AUTOREMOVE"
}

mostrar_proxima_revision() {
    local CACHE_NEXT_CHECK="/var/cache/easyupd_lab/next_check"
    NOW=$(date +%s)

    if [ -f "$CACHE_NEXT_CHECK" ]; then
        NEXT_RUN=$(grep -E '^[0-9]+$' "$CACHE_NEXT_CHECK" 2>/dev/null || echo 0)
    else
        NEXT_RUN=0
    fi

    if (( NEXT_RUN <= NOW )); then
        NEXT_RUN=$(( NOW + SLEEP_TIME ))
    fi

    echo ""
    echo -e "${yellow}Próxima revisión estimada (fecha / hora):${nc} ${green}$(date -d "@$NEXT_RUN" +"%Y-%m-%d / %H:%M:%S")${nc}"
    echo ""
}

imprimir_titulo() {
    local texto=" $1 "
    local ancho="${#texto}"
    printf "${green}%.0s=${nc}" $(seq 1 "$ancho")
    echo -e "\n${yellow}${texto^^}"
    printf "${green}%.0s=${nc}" $(seq 1 "$ancho")
    echo -e "\n"
}

notificar_servicio_sistema() {
    pkill -SIGUSR1 -f "sysupd-daemon_lab.sh" 2>/dev/null
}

check_apt_installed() {
    tput ed
    tput civis

    ABNORMAL=0
    LOG_ERRORES=$(mktemp /tmp/easyupd_log_errores.XXXXXX)

    for (( i = 0; i <= "${#PAQUETES[@]}" - 1; i++ )); do
        PAQUETE="${PAQUETES[$i]}"
        PROCESADO="no"

        while [[ "$PROCESADO" == "no" ]]; do
            V_INST=$(LC_ALL=C apt-cache policy "$PAQUETE" 2>/dev/null | grep -iE "Instal(led|ados):" | awk '{print $NF}')
            V_CAND=$(LC_ALL=C apt-cache policy "$PAQUETE" 2>/dev/null | grep -iE "Candidat[oe]:" | awk '{print $NF}')

            if [[ -z "$V_INST" && -z "$V_CAND" ]]; then
                echo -e "El paquete \"${red}$PAQUETE${nc}\" no se encuentra en las listas locales actuales."
                echo -e "Puede no estar disponible en este momento o requerir actualización de repositorios."
                echo -e "Buscando paquetes similares..."

                SUGERENCIA=$(fzf --height 10 --cycle --reverse --border \
                    --header "¿Quizá quisiste decir..?: (ESC para omitir):" \
                    --query "$PAQUETE" --select-1 --exit-0 < "$CACHE_PKGS")

                if [[ -n "$SUGERENCIA" ]]; then
                    echo -e "Usando sugerencia: '${green}$SUGERENCIA${nc}'"
                    PAQUETE="$SUGERENCIA"
                    continue
                else
                    echo -e "${yellow}Omitiendo paquete...${nc}"
                    continue 2
                fi

            elif [[ ( "$V_INST" == "(ninguno)" || "$V_INST" == "(none)" ) && -n "$V_CAND" ]]; then
                echo -e "El paquete ${yellow}$PAQUETE${nc} existe pero no está instalado."

                if es_interactivo "$PAQUETE"; then
                    echo -e "${Byellow}¡Aviso!${nc} Se detectó que el paquete podría necesitar intervenir"
                    echo -e "\ten la configuración del sistema. Por prevención, pasamos al modo de instalación"
                    echo -e "\tinteractivo, ${yellow}por favor esté atento a la ventana emergente${nc}.\n"
                    echo -e "\t\u27A1 Abriendo sub-proceso de instalación en terminal Sakura..."

                    STATUS_FILE=$(mktemp /tmp/easyupd_pkg_status.XXXXXX)
                    echo 1 > "$STATUS_FILE"
                    sakura -c 120 -r 20 -f "Ubuntu Mono Regular 14" -t "EasyUpd - Instalando $PAQUETE" -e bash -c "echo -e '${yellow}=== EASYUPD: INSTALACIÓN INTERACTIVA DE APT ===${nc}\n'; sudo apt-get install -y \"$PAQUETE\"; echo \$? > '$STATUS_FILE'; echo -e '\n${green}Proceso finalizado. Presiona Enter para cerrar esta ventana...${nc}'; read"
                    STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo 1)
                    rm -f "$STATUS_FILE"
                else
                    MENSAJE="Instalando $PAQUETE ($V_CAND)..."
                    ejecutar_con_seguridad "sudo apt-get install -y \"$PAQUETE\" > /dev/null &"
                    PID=$!
                    spinner $PID "$MENSAJE"
                    wait $PID
                    STATUS="$?"
                fi

                if [ "$STATUS" -eq 0 ]; then
                    echo -e "\t✔ ${green}Instalado con éxito:${nc} ${yellow}$PAQUETE${nc} ${green}versión $V_CAND${nc}"
                    PROCESADO="si"
                else
                    echo -e "${red}Error al instalar $PAQUETE${nc}"
                    echo "$FECHA: error instalando $PAQUETE" >> "$LOG_ERRORES"
                    ABNORMAL=1
                    break
                fi

            elif [[ "$V_INST" != "$V_CAND" ]]; then
                echo -e "El paquete ${yellow}$PAQUETE${nc} puede actualizarse (${V_INST} → ${V_CAND})."

                if es_interactivo "$PAQUETE"; then
                    echo -e "${Byellow}¡Aviso!${nc} Se detectó que la actualización podría necesitar intervenir"
                    echo -e "\ten la configuración del sistema. Por prevención, pasamos al modo de instalación"
                    echo -e "\tinteractivo, ${yellow}por favor esté atento a la ventana emergente${nc}.\n"
                    echo -e "\t\u27A1 Abriendo sub-proceso de actualización en terminal Sakura..."

                    STATUS_FILE=$(mktemp /tmp/easyupd_pkg_status.XXXXXX)
                    echo 1 > "$STATUS_FILE"
                    sakura -c 120 -r 20 -f "Ubuntu Mono Regular 14" -t "EasyUpd - Actualizando $PAQUETE" -e bash -c "echo -e '${yellow}=== EASYUPD: ACTUALIZACIÓN INTERACTIVA DE APT ===${nc}\n'; sudo apt-get install --only-upgrade -y \"$PAQUETE\"; echo \$? > '$STATUS_FILE'; echo -e '\n${green}Proceso finalizado. Presiona Enter para cerrar esta ventana...${nc}'; read"
                    STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo 1)
                    rm -f "$STATUS_FILE"
                else
                    MENSAJE="Actualizando $PAQUETE..."
                    ejecutar_con_seguridad "sudo apt-get install --only-upgrade -y \"$PAQUETE\" > /dev/null &"
                    PID=$!
                    spinner $PID "$MENSAJE"
                    wait $PID
                    STATUS="$?"
                fi
                if [ "$STATUS" -eq 0 ]; then
                    echo -e "\t✔ ${green}Actualizado con éxito:${nc} ${yellow}$PAQUETE${nc} ${green}versión $V_CAND${nc}"
                    PROCESADO="si"
                else
                    echo -e "${red}Error al actualizar $PAQUETE${nc}"
                    echo "$FECHA: error actualizando $PAQUETE" >> "$LOG_ERRORES"
                    ABNORMAL=1
                    break
                fi
            else
                echo -e "\t\u2756 ${green}El paquete ${yellow}$PAQUETE ${green}ya está en su versión más reciente${nc} ($V_INST)."
                sleep 0.7
                continue 2
            fi
        done
    done

    echo ""
    echo "Saliendo..."
    echo ""
    tput cnorm

    if [ -s "$LOG_ERRORES" ]; then
        echo ""
        echo -e "${red}Resumen de errores:${nc}"
        cat "$LOG_ERRORES"
    fi
    rm -f "$LOG_ERRORES"
    return "$ABNORMAL"
}

show_apt_info() {
    info_paquete_fzf() {
        local busqueda_inicial="$1"
        local tmp_seleccion
        tmp_seleccion=$(mktemp /tmp/easyupd_fzf.XXXXXX)

        local titulo_ventana="EasyUpd - Selector de Paquetes"

        sakura -f "Ubuntu Mono Regular 14" -t "$titulo_ventana" -e bash -c "
            LC_ALL=C apt-cache pkgnames | fzf --query='$busqueda_inicial' \
                --preview='LC_ALL=C apt-cache show {} | grep -E \"^(Description|Version|Section):\"' \
                --header='Selecciona un paquete (ESC para salir)' > '$tmp_seleccion'
        " &

        local sakura_pid=$!

        local intento=0
        while ! wmctrl -l | grep -q "$titulo_ventana" && [ $intento -lt 10 ]; do
            sleep 0.2
            intento=$((intento + 1))
        done

        if wmctrl -l | grep -q "$titulo_ventana"; then
            wmctrl -r "$titulo_ventana" -b add,above
            wmctrl -a "$titulo_ventana"
        fi

        wait $sakura_pid

        local elegido
        elegido=$(cat "$tmp_seleccion")
        rm -f "$tmp_seleccion"
        echo "$elegido"
    }

    local pkg="$1"

    if [ -z "$pkg" ]; then
        echo "No se especificó un paquete. Abriendo búsqueda interactiva..."
        pkg=$( info_paquete_fzf "")
        [ -z "$pkg" ] && { echo "Búsqueda cancelada."; return 0; }
    fi

    if ! LC_ALL=C apt-cache show "$pkg" >/dev/null 2>&1; then
        echo -e "${yellow}Paquete '$pkg' no encontrado.${nc} Abriendo búsqueda interactiva en Sakura..."
        pkg=$( info_paquete_fzf "$pkg" )
        [ -z "$pkg" ] && { echo "Búsqueda cancelada."; return 0; }
    fi

    echo -e "${cyan}======================================================================${nc}"
    echo -e "  ${green}INFORMACIÓN DEL PAQUETE:${nc} $pkg"
    echo -e "${cyan}======================================================================${nc}"

    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
        echo -e " Estado en el sistema: \e[32mINSTALADO\e[0m"
    else
        echo -e " Estado en el sistema: \e[31mNO INSTALADO\e[0m"
    fi

    echo -e "${cyan}----------------------------------------------------------------------${nc}"

    LC_ALL=C apt-cache show "$pkg" 2>/dev/null | grep -E "^(Version|Section|Size|Maintainer|Homepage):" | uniq

    echo -e "${cyan}----------------------------------------------------------------------${nc}"
    echo -e " ${yellow}Descripción (Español):${nc}"

    LC_ALL=C apt-cache show "$pkg" 2>/dev/null | awk '/^Description-es:/,/^Description-md5:/ { if ($0 !~ /^Description-md5:/) { sub(/^Description-es: /, ""); print } }' | uniq

    echo -e "${cyan}======================================================================${nc}"
}

sincronizar_y_revisar_actualizaciones() {
    clear

    if [ "$FORCE" = "1" ]; then
        imprimir_titulo "actualizacion del sistema (forzado):"
    else
        imprimir_titulo "actualizacion del sistema:"
    fi

    ! sudo -v && { echo -e "${red}[!] Permiso denegado. Saliendo.${nc}"; exit 1; }

    APTERRORS=$(mktemp /tmp/easyupd_apt_error.XXXXXXXX)

    if ! check_internet; then
        echo -e "${red}[!] ERROR DE CONEXIÓN:${nc} No hay acceso a Internet."
        echo -e "${yellow}Sugerencia:${nc} Verifica tu conexión de red o Wi-Fi e intenta nuevamente."
        rm -f "$APTERRORS"
        sleep 4
        exit 1
    fi

    echo -e "${cyan}Sincronizando base de datos local de paquetes...${nc}"
    
    APT_FALLO=0
    if ! sudo apt-get update -qq 2>"$APTERRORS"; then
        APT_FALLO=1
    elif [ -s "$APTERRORS" ] && grep -qE "(Could not wait for server fd|Recurso no disponible temporalmente|Temporary failure|EAGAIN|Connection timed out|Temporary failure in name resolution)" "$APTERRORS"; then
        APT_FALLO=1
    fi

    if [ "$APT_FALLO" -eq 1 ]; then
        local DETALLE_ERROR="Error de conexión o saturación en los espejos remotos (EAGAIN/Timeout)."
        if [ -s "$APTERRORS" ]; then
            DETALLE_ERROR=$(head -n 2 "$APTERRORS" | tr '\n' ' ')
        fi

        echo -e "${red}[!] ERROR DE REPOSITORIOS / ESPEJOS REMOTOS:${nc} $DETALLE_ERROR"

        # Validar si la ejecución es interactiva (desde terminal por el usuario) o por un disparo automático 'at'
        if [ -t 0 ]; then
            echo ""
            echo -e "${yellow}Esta condición es temporal y externa a EasyUpd (depende de los servidores remotos).${nc}"
            echo -e -n "¿Desea programar un reintento único automático con 'at' para dentro de ${green}30 minutos${nc}? (${green}s${nc}/${red}n${nc}): "
            read -r -n 1 RESP_AT
            echo -e "\n"

            if [ "$RESP_AT" = "s" ] || [ -z "$RESP_AT" ]; then
                if command -v at >/dev/null 2>&1; then
                    local script_path
                    script_path="$(readlink -f "$0")"
                    echo "sudo $script_path -f" | at now + 30 minutes 2>/dev/null
                    echo -e "✔ ${green}Reintento único programado exitosamente para dentro de 30 minutos usando 'at'.${nc}"
                    notificar_servicio_sistema
                else
                    echo -e "${red}⚠ El servicio 'at' no está instalado en el sistema.${nc}"
                fi
            else
                echo -e "${yellow}Reintento cancelado. El sistema mantendrá su agenda programada normal.${nc}"
            fi
		else
            # Ejecución no interactiva (el reintento programado por 'at' volvió a fallar)
            local LOG_HISTORICO="/var/log/easyupd_lab.log"
            [ ! -f "$LOG_HISTORICO" ] && { sudo touch "$LOG_HISTORICO"; sudo chmod 664 "$LOG_HISTORICO"; sudo chown root:easyupd "$LOG_HISTORICO" 2>/dev/null || true; }
            
            {
                echo ""
                echo ">>> REINTENTO AUTOMÁTICO FALLIDO: $(date +'%Y-%m-%d %H:%M:%S') <<<"
                echo "  • El problema con los espejos remotos persiste (EAGAIN/Timeout)."
                echo "  • Se reintentará nuevamente según la agenda programada de EasyUpd."
                echo "-------------------------------------------------------"
            } | sudo tee -a "$LOG_HISTORICO" > /dev/null 2>&1

            echo -e "${yellow}[i] El reintento programado no tuvo éxito. El problema con los espejos persiste.${nc}"
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -i dialog-warning "EasyUpd - Repositorios" "El problema de los espejos persiste. Se reintentará según la agenda programada."
            fi
        fi
	fi

    sudo touch "$CACHE_LAST_UPDATE"
    LC_ALL=C apt-cache pkgnames > "$CACHE_PKGS"

    echo "Calculando estado del sistema..."
    echo ""
    LC_ALL=C apt-get -s dist-upgrade | grep '^Inst ' | awk '{print $2}' > "$CACHE_PENDING_LIST"
    
    COUNT=$(grep -c '[^[:space:]]' "$CACHE_PENDING_LIST" 2>/dev/null)
    COUNT=${COUNT:-0}
    echo "$COUNT" > "$CACHE_PENDING_COUNT"

    mostrar_y_preguntar "$COUNT"
    ejecutar_autoremove
    mostrar_proxima_revision
    echo ""
    sleep 4
    rm -f "$APTERRORS"
    notificar_servicio_sistema
    exit 0
}

validar_dimensiones() {
    local min_filas=20
    local min_cols=60

    local filas
    filas=$(tput lines)
    local cols
    cols=$(tput cols)

    if [ "$filas" -lt "$min_filas" ] || [ "$cols" -lt "$min_cols" ]; then
        clear
        echo -e "${red}Error: Ventana de terminal demasiado pequeña.${nc}"
        echo "-------------------------------------------------------"
        echo "Este script requiere un área de visualización mínima de:"
        echo -e "Ancho: ${green}$min_cols${nc} | Alto: ${green}$min_filas${nc}"
        echo ""
        echo -e "Actual: Ancho: ${yellow}$cols${nc} | Alto: ${yellow}$filas${nc}"
        echo "-------------------------------------------------------"
        echo "Por favor, agranda la ventana y vuelve a intentarlo."
        exit 1
    fi
}

# ------------------ SOURCES Y SETUP INICIAL ------------------
source /usr/local/bin/easyupd/check_internet
source /usr/local/bin/easyupd/bash_colors
bash_colors

source /usr/local/bin/easyupd/check_os_family
if ! check_os_family; then exit 1; fi

source /usr/local/bin/easyupd/check_pkg_lock
if ! check_pkg_lock; then exit 1; fi

validar_dimensiones

clear
echo -e "${green}#################################################"
echo -e "#           ${yellow}E A S Y   U P D A T E${green}               #"
echo -e "#################################################${nc}"
echo ""

tiempo_restante() {
    LAST_AUTH=$(stat -c %Y "$SESSION_USER" 2>/dev/null)
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_AUTH ))
    REMAINING=$(( GRACE_PERIOD - ELAPSED ))
}
tiempo_restante

expiry_time() {
    MIN_REM=$(( REMAINING / 60 ))
    SEC_REM=$(( REMAINING % 60 ))
    EXPIRY_TIME=$(date -d "@$(( LAST_AUTH + GRACE_PERIOD ))" +%H:%M)
}

if [ "$INFO" = "false" ]; then

    if [ "$(id -u)" -ne 0 ]; then
        if getent group sudo | grep -q "\<$REAL_USER\>" || getent group wheel | grep -q "\<$REAL_USER\>"; then

            if [ ! -f "$SESSION_USER" ] || [ "$REMAINING" -le "0" ]; then
                sudo -k
                echo "Se requiere autorización para aplicar las actualizaciones."
                echo -e "Tienes ${yellow}3${nc} intentos para validarla:"
                echo ""

                if sudo -v; then
                    touch "$SESSION_USER"
                    tiempo_restante
                    echo -e "\n${green}Autorización concedida. Elevando proceso a Root...\n${nc}"
                    
                    exec sudo "$0" "$@"
                else
                    echo -e "${red}[!] Contraseña incorrecta o permiso denegado. Saliendo.${nc}"
                    sleep 1.7
                    exit 1
                fi
            else
                expiry_time
                echo -e "${green}Autorización en el periodo de gracia hasta${nc}: ${yellow}$EXPIRY_TIME${nc}. ${green}(quedan${nc} ${yellow}${MIN_REM}m ${SEC_REM}s${nc}${green}).${nc}"
                echo -e "${green}Iniciando como Root...\n${nc}"
                
                exec sudo "$0" "$@"
            fi
        else
            clear
            echo -e "${cyan}=====================================================${nc}"
            echo -e "       ${yellow}AVISO: CONTROL DE SOBERANÍA DEL SISTEMA${nc}"
            echo -e "${cyan}=====================================================${nc}"
            echo -e "Identificado usuario limitado: ${green}$REAL_USER${nc}"
            echo -e "Para continuar, se requiere que un administrador valide la tarea."
            echo ""
            echo -e "${yellow}Invocando diálogo gráfico de autorización...${nc}"
            echo "-----------------------------------------------------"
            sleep 1.5

            exec sudo "$(readlink -f "$0")" "$@"
        fi
    else
        echo -e "${green}✔ Autenticación exitosa (Soberanía delegada como ROOT).${nc}"
        echo -e "${green}Iniciando el motor de actualizaciones...\n${nc}"
    fi
fi

sleep 1

# ------------------ CACHE ------------------
if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
fi

CACHE_LAST_UPDATE="${CACHE_DIR}/last_apt_update"
CACHE_PENDING_COUNT="${CACHE_DIR}/pending_count"
CACHE_PENDING_LIST="${CACHE_DIR}/pending_list"
CACHE_PKGS="${CACHE_DIR}/apt_all_packages.txt"
CACHE_LAST_AUTOREMOVE="${CACHE_DIR}/last_autoremove"

for archivo in "$CACHE_LAST_UPDATE" "$CACHE_PENDING_COUNT" "$CACHE_PENDING_LIST" "$CACHE_PKGS" "$CACHE_LAST_AUTOREMOVE"; do
    [ ! -f "$archivo" ] && touch "$archivo"
    chmod 664 "$archivo" 2>/dev/null || true
done

LAST_UPDATE_EPOCH=$(stat -c %Y "$CACHE_LAST_UPDATE" 2>/dev/null || echo 0)
LAST_AUTOREMOVE_EPOCH=$(stat -c %Y "$CACHE_LAST_AUTOREMOVE" 2>/dev/null || echo 0)

TIMER_VALUE=$(( 7 * 86400 ))
NOW=$(date +%s)

# shellcheck disable=SC2317
limpiar_al_salir() {
    trap - SIGINT SIGTERM

    [[ -n "$APTERRORS" ]] && rm -f "$APTERRORS" 2>/dev/null

    local hijos
    hijos=$(jobs -p)
    [[ -n "$hijos" ]] && kill -TERM "$hijos" 2>/dev/null

    tput cnorm
    echo -e "\n${yellow}[!] Ejecución interrumpida por el usuario. Limpiando...${nc}"
    exit 0
}

trap limpiar_al_salir SIGINT SIGTERM
clear

# ------------------ LOGICA PRINCIPAL ------------------

if [ "$INFO" = "true" ]; then
    clear
    imprimir_titulo "modo consulta de informacion:"

    if [ "${#PAQUETES[@]}" -eq 0 ]; then
        show_apt_info ""
    else
        for pkg in "${PAQUETES[@]}"; do
            show_apt_info "$pkg"
            echo -e "\n${yellow}Presiona [ENTER] para continuar...${nc}"
            read -r
        done
    fi
    exit 0
fi

if [ "${#PAQUETES[@]}" -gt 0 ]; then
    imprimir_titulo "modo instalacion:"

    cadena="${PAQUETES[*]}"
    long_parametro=${#cadena}
    [ "${#PAQUETES[@]}" -gt 1 ] && titulo="Validando paquetes solicitados: " || titulo="Validando paquete solicitado: "
    long_titulo=${#titulo}
    long_total=$(( long_parametro + long_titulo ))

    printf '%.0s-' $(seq 1 $long_total); printf " \n"
    echo -e "${titulo}${green}${cadena}${nc}"
    printf '%.0s-' $(seq 1 $long_total); printf " \n"
    sleep 2
    echo ""

    check_apt_installed
    exit $?
fi

if [ "$FORCE" = "1" ]; then
    sincronizar_y_revisar_actualizaciones
    exit 0
fi

COUNT=$(cat "$CACHE_PENDING_COUNT" 2>/dev/null)
COUNT=${COUNT:-0}

if (( COUNT > 0 )); then
    imprimir_titulo "actualizacion del sistema:"
    mostrar_y_preguntar "$COUNT"
    ejecutar_autoremove
    mostrar_proxima_revision
    sleep 4
    exit 0
fi

if (( NOW - LAST_UPDATE_EPOCH <= SLEEP_TIME )); then
    imprimir_titulo "estado actual (ventana de gracia)"
    echo -e "${green}El sistema está al día. Listas de paquetes vigentes en caché.${nc}"
    echo -e "\t\u2714 Se revisó recientemente y no hay tareas pendientes."

    (( NOW - LAST_AUTOREMOVE_EPOCH > TIMER_VALUE )) && ejecutar_autoremove

    mostrar_proxima_revision
    sleep 4
    exit 0
fi

sincronizar_y_revisar_actualizaciones
exit 0
