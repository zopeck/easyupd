# EasyUpd:

Framework modular de mantenimiento y gestión de actualizaciones para sistemas basados en Debian. Diseñado para entornos Linux con bajo consumo de recursos, integrando monitoreo en segundo plano mediante `systemd`, alertas visuales con `yad` y protección de respaldos con `Timeshift`.

## Características:
- **Daemon de fondo (`sysupd-daemon.sh`):** Monitoreo ligero de actualizaciones del sistema sin consumir ciclos de CPU innecesarios.
- **Interfaz gráfica interactiva (`easyupd_yad.sh`):** Control visual optimizado para entornos de escritorio ligeros (XFCE, i3).
- **Seguridad y respaldos (`easyupd-timeshift.sh`):** Integración nativa con instantáneas de Timeshift previas a la aplicación de cambios críticos.
- **Servicios y Timers:** Automatización limpia mediante unidades de `systemd`.

## Dependencias:
- `bash` (>= 4.0)
- `yad`
- `timeshift`
- `dpkg` / `apt`

## Instalación:
Descarga la última versión del paquete empaquetado desde la sección de **Releases** e instálalo localmente:
```bash
sudo dpkg -i easyupd_1.0-1_amd64.deb
sudo apt-get install -f # para resolver dependencias si es necesario
```

## Autor:
**Mark**
*Marco A. Rodriguez G.*
*email: zopeck@gmail.com*


