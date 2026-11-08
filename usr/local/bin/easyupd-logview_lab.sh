#!/usr/bin/env bash
# /usr/local/bin/easyupd-logview_lab.sh
# Visor gráfico de registros de EasyUpd usando YAD

LOG="/var/log/easyupd_lab.log"
MODO="${1:-ultimos}"

if [ ! -f "$LOG" ]; then
    yad --image="dialog-warning" \
        --title="EasyUpd - Registros" \
        --text="No se encontró el archivo de registro en:\n<b>$LOG</b>" \
        --button="Cerrar:0" \
        --width=400 --geometry=+600+350 2>/dev/null
    exit 1
fi

if [ "$MODO" = "ultimos" ]; then
    # Procesa el log agrupando por bloques separados por la línea de guiones.
    # Mantiene el orden interno de cada bloque pero invierte el orden cronológico
    # de los eventos para mostrar el más reciente arriba.
    LOG_FORMATEADO=$(awk '
        BEGIN { RS = "-------------------------------------------------------\n"; FS = "\n" }
        {
            # Sanitizar bloques vacíos
            if ($0 ~ /[^[:space:]]/) {
                # Reconstruir el bloque con su separador
                bloque = $0 "-------------------------------------------------------\n"
                # Almacenar en array ordenado
                bloques[NR] = bloque
                total = NR
            }
        }
        END {
            # Imprimir los últimos bloques en orden inverso (más reciente arriba)
            limite = (total - 5 > 0) ? total - 5 : 1
            for (i = total; i >= limite; i--) {
                if (bloques[i] != "") {
                    printf "%s", bloques[i]
                }
            }
        }
    ' "$LOG")

    echo "$LOG_FORMATEADO" | yad --text-info \
        --title="EasyUpd - Últimos Registros (Más recientes primero)" \
        --center \
        --width=950 --height=550 \
        --fontname="Ubuntu Mono 13" \
        --button="Cerrar:0" \
        --geometry=+450+250 2>/dev/null
else
    # Muestra todo el histórico en orden cronológico normal
    yad --text-info \
        --filename="$LOG" \
        --title="EasyUpd - Registro Histórico Completo" \
        --center \
        --width=950 --height=600 \
        --fontname="Ubuntu Mono 13" \
        --button="Cerrar:0" \
        --geometry=+450+200 2>/dev/null
fi
