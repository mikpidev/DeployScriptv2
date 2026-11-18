# DeployScriptv2
# Guía de Despliegue Automatizado — Gestock (`deploy.sh`)

Script en Bash diseñado para estandarizar y automatizar la actualización de los repositorios **Gestock-API** (Laravel) y **Gestock-Web** (Frontend/Vite) en el servidor, siguiendo estrictamente el runbook operativo.

---

## 🎯 Entorno y Requisitos Previos

* **Entorno destino:** Sandbox / Staging (`https://sandbox.gestock.site`)
* **Flujo de Git / CI:** GitHub + Jenkins. 
* **Regla de oro:** Este script **solo** debe ejecutarse después de que Jenkins marque el Pull Request como `SUCCESS` y los cambios hayan sido fusionados a la rama `main` en GitHub. El servidor nunca hace *pull* de ramas de PR directamente.
* **Permisos de ejecución:** Requiere privilegios `root` o `sudo` para gestionar servicios del sistema (`systemd`), validar Nginx y asignar permisos de archivos entre los usuarios `jenkins` y `www-data`.

---

## ⚙️ Variables Importantes a Verificar

Al inicio del script (`deploy.sh`), asegúrate de que las siguientes rutas y URLs coincidan con la configuración del servidor antes de ejecutarlo por primera vez:

| Variable | Valor por defecto | Descripción |
| :--- | :--- | :--- |
| `API_DIR` | `/var/www/gestock-api` | Ruta absoluta del repositorio backend en el servidor. |
| `WEB_DIR` | `/var/www/gestock-web` | Ruta absoluta del repositorio frontend en el servidor. |
| `API_URL` | `https://sandbox.gestock.site` | URL base del entorno utilizada para ejecutar los *smoke tests* con `curl`. |

### Variables de entorno de los proyectos (`.env`)
* **Gestock-Web:** El script lee e imprime la variable `VITE_API_URL` dentro de `/var/www/gestock-web/.env`. Antes de continuar, verifica visualmente que apunte a `https://sandbox.gestock.site/api/v1` y no a un entorno local.

---

## 🚀 Cómo se usa

1. **Conéctate al servidor** por SSH.
2. **Ejecuta el script** con privilegios de administrador:
   ```bash
   sudo /var/scripts/deploy.sh

   Elige una opción en el menú interactivo según el alcance del issue desplegado:

        1) Gestock-API: Actualiza únicamente el backend.

        2) Gestock-Web: Actualiza únicamente el frontend.

3) Ambos (API y luego Web): Ejecuta el flujo completo en el orden estricto (primero la API, valida su funcionamiento y luego compila la Web para evitar errores de endpoints inexistentes).

🛡️ Validaciones y Controles de Seguridad
El script opera bajo set -e (detención inmediata ante cualquier error) y ejecuta las siguientes comprobaciones automáticas:

1. Prechecks del Sistema
Servicios activos: Verifica mediante systemctl que nginx, php8.4-fpm y mariadb estén corriendo (active). Si alguno está caído, aborta.

Espacio en disco: Evalúa el porcentaje de uso de la partición raíz (/). Si supera el 90%, detiene el despliegue para prevenir fallos de escritura o corrupción de datos.

2. Validaciones de Repositorio (API y Web)
Rama exacta: Confirma que el repositorio esté posicionado en main.

Árbol de trabajo limpio: Ejecuta git status --short. Si detecta archivos modificados, sin seguimiento o eliminados localmente, aborta para no sobrescribir ni perder cambios sin auditar.

Integridad del .env: Comprueba que el archivo .env exista en el servidor y que esté correctamente ignorado por Git (git check-ignore .env).

Trazabilidad: Imprime y registra el hash corto del commit instalado antes (OLD_COMMIT) y después (NEW_COMMIT) de la actualización.

Actualización lineal: Utiliza git pull --ff-only origin main. Si existen commits locales en el servidor o historias divergentes, Git rechazará la operación y el script se detendrá.

3. Validaciones Específicas de Gestock-API
Dependencias y Migraciones: Instala dependencias de producción (--no-dev), muestra el estado actual de las migraciones (migrate:status) y aplica las pendientes (migrate --force).

Cachés y Permisos: Reconstruye las cachés de configuración, rutas y vistas de Laravel, y aplica los permisos exactos (2775 para directorios y 664 para archivos bajo jenkins:www-data) en storage y bootstrap/cache.

Smoke Test de API: Realiza una petición POST vacía a /api/v1/login. Confirma que Nginx, PHP-FPM y Laravel responden correctamente si el servidor devuelve un código HTTP 422 Unprocessable Content.

4. Validaciones Específicas de Gestock-Web
Calidad y Compilación: Instala dependencias exactas con npm ci y ejecuta en cadena npm run lint, npm test y npm run build. Si alguna prueba o regla de linter falla, la compilación se cancela.

Auditoría del Build (dist):

Verifica que exista el archivo /var/www/gestock-web/dist/index.html.

Escanea todo el directorio dist/ buscando referencias accidentales a entornos locales (127.0.0.1:8001). Si encuentra alguna, detiene el proceso antes de recargar el servidor web.

Permisos seguros: Aplica permisos (755 / 644) exclusivamente sobre la carpeta dist/ sin tocar node_modules/.bin.

Recarga de Nginx y Smoke Test: Valida la sintaxis de configuración (nginx -t), recarga el servicio sin cortes y verifica con curl -I que el sitio responda con código 200 (o redirección válida 302/304).

⚠️ Qué hacer si el script se detiene por un error
No fuerces los cambios con comandos como git reset --hard ni borres archivos manualmente.

Si el error ocurrió durante la actualización de la API (en la opción 3), el script no avanzará hacia la Web para evitar dejar el sistema inconsistente.

Revisa los logs correspondientes según el punto donde falló:

Bash
# Logs de aplicación Laravel
tail -n 150 /var/www/gestock-api/storage/logs/laravel.log

# Logs de errores de Nginx
tail -n 150 /var/log/nginx/sandbox.gestock.site.error.log
Corrige el problema mediante un nuevo PR en GitHub, espera a que Jenkins apruebe el build, haz merge a main y vuelve a ejecutar sudo /var/scripts/deploy.sh.

📋 Verificación Post-Despliegue (Manual)
Una vez que el script muestre ¡Despliegue finalizado exitosamente!:

Ingresa a https://sandbox.gestock.site en el navegador.

Verifica en DevTools → Network que las peticiones apunten a /api/v1 y no devuelvan errores 500, 502 o 503.

Si el navegador muestra una versión en caché antigua, limpia los datos del sitio desde DevTools → Application → Storage → Clear site data y recarga con Ctrl + Shift + R.