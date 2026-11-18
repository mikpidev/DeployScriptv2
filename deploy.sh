#!/bin/bash

# ==============================================================================
# Script de Despliegue Automatizado - Gestock (API & Web)
# Entorno: Sandbox / Staging
# ==============================================================================

#Detener script si se produce un error
set -e

#Colores para el output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

#Paths a hacer Deploy

API_DIR="/var/www/gestock-api"
WEB_DIR="/var/www/gestock-web"
API_URL="https://sandbox.gestock.site"

# ------------------------------------------------------------------------------
# 1. Prechecks Obligatorios Generales
# ------------------------------------------------------------------------------
log_info "Ejecutando prechecks generales del sistema..."

# Verificar servicios activos
SERVICES=("nginx" "php8.4-fpm" "mariadb")
for svc in "${SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$svc"; then
        log_error "El servicio $svc no está activo. Resuélvelo antes de continuar."

        echo ""
        echo "Desea iniciar los servicios automaticamente? (s/n)"
        read -n 1 -s RESPONSE
        if [ "$RESPONSE" == "s" ]; then
            systemctl start "$svc"
            log_info "Servicio $svc iniciado correctamente."
        else
            log_error "Los servicios no se han iniciado. Resuelve el problema antes de continuar."
            exit 1
        fi
        echo ""
    fi
done
log_info "Servicios (Nginx, PHP-FPM, MariaDB) OK."

# Verificar espacio en disco (advertir si el uso de raíz supera el 90%)
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_USAGE" -ge 90 ]; then
    log_error "El disco está casi lleno (${DISK_USAGE}% utilizado). Libera espacio antes de desplegar."
fi
log_info "Espacio en disco OK (${DISK_USAGE}% usado)."

# Preguntar qué componentes actualizar
echo ""
echo "Selecciona el componente a actualizar:"
echo "1) Gestock-API"
echo "2) Gestock-Web"
echo "3) Ambos (API y luego Web)"
read -rp "Opción [1-3]: " CHOICE

# ------------------------------------------------------------------------------
# Función para actualizar Gestock-API
# ------------------------------------------------------------------------------
update_api() {
    log_info "=== Iniciando actualización de Gestock-API ==="
    cd "$API_DIR" || log_error "No se pudo acceder a $API_DIR"

    # Verificaciones de repositorio
    BRANCH=$(sudo -u jenkins git branch --show-current)
    if [ "$BRANCH" != "main" ]; then
        log_error "La rama actual es '$BRANCH'. Debe ser 'main'."
    fi

    if [ -n "$(sudo -u jenkins git status --short)" ]; then
        log_error "El repositorio de la API tiene cambios locales sin confirmar. Deteniendo despliegue."
    fi

    if [ ! -f .env ]; then
        log_error "Falta el archivo .env en la API."
    fi
    sudo -u jenkins git check-ignore .env > /dev/null || log_error ".env no está ignorado por git."

    # Registrar versión actual
    OLD_COMMIT=$(sudo -u jenkins git rev-parse --short HEAD)
    log_info "Commit actual de la API: $OLD_COMMIT"

    # Fetch y análisis de diferencias
    sudo -u jenkins git fetch origin
    REMOTE_DIFF=$(sudo -u jenkins git rev-list --left-right --count HEAD...origin/main)
    log_info "Diferencias con origin/main: $REMOTE_DIFF"

    # Aplicar pull fast-forward
    sudo -u jenkins git pull --ff-only origin main
    NEW_COMMIT=$(sudo -u jenkins git rev-parse --short HEAD)
    log_info "API actualizada al commit: $NEW_COMMIT"

    # Instalar dependencias PHP
    log_info "Instalando dependencias de Composer (producción)..."
    sudo -u jenkins -H /usr/local/bin/composer install \
      --no-dev \
      --prefer-dist \
      --no-interaction \
      --optimize-autoloader

    # Migraciones
    log_info "Verificando estado de migraciones..."
    sudo -u jenkins -H php artisan migrate:status

    log_info "Ejecutando migraciones pendientes..."
    sudo -u jenkins -H php artisan migrate --force

    # Limpiar y reconstruir cachés
    log_info "Limpiando y reconstruyendo cachés de Laravel..."
    sudo -u jenkins -H php artisan optimize:clear
    sudo -u jenkins -H php artisan config:cache
    sudo -u jenkins -H php artisan route:cache
    sudo -u jenkins -H php artisan view:cache

    # Permisos
    log_info "Ajustando permisos de almacenamiento y caché..."
    chown -R jenkins:www-data storage bootstrap/cache
    find storage bootstrap/cache -type d -exec chmod 2775 {} \;
    find storage bootstrap/cache -type f -exec chmod 664 {} \;

    # Verificaciones del backend
    log_info "Verificando estado del backend..."
    sudo -u jenkins -H php artisan about > /dev/null
    
    # Smoke test de autenticación (Login vacío -> 422)
    log_info "Ejecutando smoke test de la API..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "$API_URL/api/v1/login" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --data '{}')

    if [ "$HTTP_CODE" -eq 422 ]; then
        log_info "Smoke test API exitoso (Código 422 obtenido correctamente)."
    else
        log_warn "El smoke test devolvió el código inesperado: $HTTP_CODE (Se esperaba 422)"
    fi

    log_info "=== Gestock-API actualizada con éxito ==="
}

# ------------------------------------------------------------------------------
# Función para actualizar Gestock-Web
# ------------------------------------------------------------------------------
update_web() {
    log_info "=== Iniciando actualización de Gestock-Web ==="
    cd "$WEB_DIR" || log_error "No se pudo acceder a $WEB_DIR"

    # Verificaciones de repositorio
    BRANCH=$(sudo -u jenkins git branch --show-current)
    if [ "$BRANCH" != "main" ]; then
        log_error "La rama actual es '$BRANCH'. Debe ser 'main'."
    fi

    if [ -n "$(sudo -u jenkins git status --short)" ]; then
        log_error "El repositorio web tiene cambios locales sin confirmar. Deteniendo despliegue."
    fi

    if [ ! -f .env ]; then
        log_error "Falta el archivo .env en el Frontend."
    fi
    
    # Validar variable VITE_API_URL
    API_URL_ENV=$(grep '^VITE_API_URL=' .env | cut -d '=' -f2)
    log_info "VITE_API_URL configurado: $API_URL_ENV"

    # Registrar versión actual
    OLD_COMMIT=$(sudo -u jenkins git rev-parse --short HEAD)
    log_info "Commit actual de la Web: $OLD_COMMIT"

    # Fetch y pull
    sudo -u jenkins git fetch origin
    sudo -u jenkins git pull --ff-only origin main
    NEW_COMMIT=$(sudo -u jenkins git rev-parse --short HEAD)
    log_info "Web actualizada al commit: $NEW_COMMIT"

    # Dependencias NPM
    log_info "Instalando dependencias de Node (npm ci)..."
    sudo -u jenkins -H npm ci --include=dev --no-audit --no-fund

    # Validaciones y Build
    log_info "Ejecutando linter..."
    sudo -u jenkins -H npm run lint

    log_info "Ejecutando pruebas..."
    sudo -u jenkins -H npm test

    log_info "Compilando assets (npm run build)..."
    sudo -u jenkins -H npm run build

    # Validar que exista el build y no apunte a localhost
    if [ ! -f "$WEB_DIR/dist/index.html" ]; then
        log_error "ERROR: Falta el archivo dist/index.html tras la compilación."
    fi

    if grep -RIl '127.0.0.1:8001' "$WEB_DIR/dist" > /dev/null 2>&1; then
        log_error "ERROR: El build contiene referencias a localhost (127.0.0.1:8001)."
    fi
    log_info "Build verificado correctamente."

    # Aplicar permisos a dist
    log_info "Ajustando permisos en la carpeta dist..."
    chown -R jenkins:www-data dist
    find dist -type d -exec chmod 755 {} \;
    find dist -type f -exec chmod 644 {} \;

    # Recargar Nginx
    log_info "Validando y recargando Nginx..."
    nginx -t || log_error "La validación de la configuración de Nginx falló."
    systemctl reload nginx

    # Smoke test del frontend
    WEB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -I "$API_URL/")
    if [ "$WEB_STATUS" -eq 200 ] || [ "$WEB_STATUS" -eq 304 ] || [ "$WEB_STATUS" -eq 302 ]; then
        log_info "Smoke test Frontend exitoso (Código $WEB_STATUS)."
    else
        log_warn "El frontend respondió con código: $WEB_STATUS"
    fi

    log_info "=== Gestock-Web actualizada con éxito ==="
}

# ------------------------------------------------------------------------------
# Ejecución según la selección
# ------------------------------------------------------------------------------
case $CHOICE in
    1)
        update_api
        ;;
    2)
        update_web
        ;;
    3)
        update_api
        echo ""
        update_web
        ;;
    *)
        log_error "Opción no válida. Ejecuta el script de nuevo y selecciona 1, 2 o 3."
        ;;
esac

log_info "¡Despliegue finalizado exitosamente!"
log_info "Puedes acceder a la aplicación en $API_URL"
log_info "Recuerda Verificar las Variables de Entorno en la API y Web."