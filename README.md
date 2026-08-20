# deployer

Despliegue automatizado de proyectos **PHP + MySQL/MariaDB** sobre Docker, en
cualquier VPS Linux, desde una sola orden.

Un único script Bash instala Docker si hace falta, busca puertos libres,
construye el `docker-compose.yml` a partir de las opciones que elijas, clona tu
proyecto, **lee su archivo de conexión PHP** para crear en la base el usuario y
la clave que tu código ya espera, importa el volcado `.sql` que le indiques y
comprueba que todo responde antes de darte las direcciones de acceso.

---

## Uso

```bash
curl -fsSL https://raw.githubusercontent.com/andru2025/doc/main/dist/deploy.sh -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh
```

El script pregunta por pantalla el nombre del proyecto, el servidor web, el
motor de base de datos, la versión de PHP y la URL del repositorio.

> No uses `curl … | bash`: el *pipe* ocupa la entrada estándar y el script no
> podría hacerte las preguntas. Si aun así lo haces, detecta la situación y cae
> a `/dev/tty`; y si tampoco hay terminal, exige que pases todo por parámetros.

### Modo desatendido

```bash
sudo bash deploy.sh \
    --name tienda \
    --web nginx \
    --db mariadb \
    --php 8.3 \
    --repo https://github.com/usuario/tienda.git \
    --sql auto \
    --pma -y
```

### Ver qué haría, sin tocar nada

```bash
sudo bash deploy.sh --dry-run
```

---

## Qué hace, paso a paso

| Fase | Qué ocurre |
|---|---|
| 1 | Detecta la distribución e instala Docker y el plugin Compose si faltan. Si Docker ya está, no lo toca. |
| 2 | Pide el nombre del proyecto y comprueba que no choque con contenedores, volúmenes, stacks ni directorios existentes. |
| 3 | Eliges Apache o Nginx, MySQL o MariaDB, la versión de PHP y si quieres phpMyAdmin. |
| 4 | Busca puertos libres consultando a Docker **y** al sistema, y asigna los siguientes consecutivos. |
| 5 | Clona el repositorio (o descarga el ZIP), aplana la carpeta contenedora y localiza la raíz pública. |
| 6 | Encuentra el archivo de conexión PHP, te enseña las credenciales que trae y crea esa base y ese usuario. |
| 7 | Genera `docker-compose.yml`, `Dockerfile`, configuración de Nginx, `.env` y `manage.sh`. |
| 8 | Levanta todo y verifica que Apache/Nginx, PHP-FPM y la base responden **dentro** del contenedor. |
| 9 | Lista los `.sql` del proyecto para que elijas, importa y comprueba que se crearon tablas de verdad. |
| 10 | Abre los puertos en el cortafuegos, detecta la IP pública y te muestra los enlaces. |

---

## Opciones

| Opción | Descripción |
|---|---|
| `--name NOMBRE` | Nombre del proyecto (minúsculas, números, `-` y `_`) |
| `--web apache\|nginx` | Servidor web |
| `--db mysql\|mariadb` | Motor de base de datos |
| `--php 8.3\|8.2\|7.4\|5.6` | Versión de PHP (por defecto 8.3) |
| `--repo URL` | Repositorio Git público |
| `--zip URL` | Archivo ZIP por URL |
| `--docroot RUTA` | Subdirectorio público dentro del proyecto |
| `--sql RUTA\|auto\|none` | Volcado a importar (`auto` = el más grande) |
| `--pma` / `--no-pma` | Incluir o no phpMyAdmin |
| `--port-http`, `--port-db`, `--port-pma` | Forzar puertos |
| `--no-firewall` | No tocar firewalld ni ufw |
| `-y`, `--yes` | Aceptar todas las confirmaciones |
| `--dry-run` | Simular sin modificar nada |

---

## Qué genera

Cada proyecto vive en `/opt/deployer/<nombre>/`:

```
/opt/deployer/tienda/
├── docker-compose.yml   servicios web, php (si nginx), db y pma
├── Dockerfile           imagen de PHP con mysqli, pdo_mysql, gd, zip…
├── nginx/default.conf   solo cuando eliges Nginx
├── .env                 credenciales y puertos (permisos 600)
├── app/                 tu proyecto
├── manage.sh            start · stop · logs · shell · db · backup · destroy
└── RESUMEN.txt          accesos y credenciales (permisos 600)
```

Los datos de la base viven en el volumen `<nombre>_dbdata` y los logs del
servidor web en `<nombre>_weblogs`. **Parar o reiniciar los contenedores no
borra nada**; solo `manage.sh destroy` elimina los volúmenes.

### Gestión posterior

```bash
cd /opt/deployer/tienda
./manage.sh status          # estado de los contenedores
./manage.sh logs web        # logs en vivo
./manage.sh db              # cliente de MySQL/MariaDB como root
./manage.sh backup          # volcado comprimido en ./backups/
./manage.sh restore f.sql   # restaurar un volcado
./manage.sh destroy         # borrar todo, incluidos los datos
```

---

## Cómo trata tu archivo de conexión

El script busca en tu proyecto un archivo con credenciales (`config.php`,
`conexion.php`, `db.php`, `database.php`, `.env`, `wp-config.php`…) y entiende
los cinco formatos habituales:

```php
define('DB_USER', 'tienda_user');                             // constantes
$username = "tienda_user";                                    // variables sueltas
'username' => 'tienda_user',                                  // arrays de configuración
mysqli_connect("localhost", "tienda_user", "clave", "tienda") // posicional
new PDO("mysql:host=localhost;dbname=tienda", "user", "pass") // PDO
```

Te enseña lo que ha leído, y **respeta tu usuario, tu clave y tu nombre de
base**: los crea tal cual en el motor. Lo único que reescribe es el host,
porque dentro de la red de Docker `localhost` no es la base de datos: el
servicio se llama `db`. Antes de tocar nada guarda una copia `.deployer.bak`.

Si prefieres otras credenciales, puedes editarlas en ese momento y el script
las escribe en tu archivo y las crea en la base.

---

## Seguridad

- El puerto de la base **solo escucha en `127.0.0.1`** salvo que pidas lo
  contrario. El contenedor web conecta por la red interna de Docker, que no
  pasa por el puerto publicado. Para entrar con un cliente externo:
  `ssh -L 33060:127.0.0.1:33060 usuario@tu-vps`
- `.env` y `RESUMEN.txt` se crean con permisos `600` porque contienen claves.
- La configuración de Nginx bloquea el acceso a `.sql`, `.env`, `.bak` y
  ficheros ocultos.
- La clave de `root` de la base se genera al azar en cada despliegue.
- Con Apache, el `docroot` apunta al subdirectorio público: el resto del
  repositorio está en el contenedor pero no se sirve por web.

---

## Distribuciones soportadas

Debian, Ubuntu y derivadas · AlmaLinux, Rocky, CentOS, RHEL, Fedora ·
openSUSE/SLES · Arch.

En AlmaLinux, Rocky y CentOS el script detecta SELinux y etiqueta los montajes
con `:Z`; sin eso el contenedor vería la raíz web vacía.

---

## PHP 7.4 y 5.6

Están disponibles porque muchos proyectos con `mysql_*` no arrancan en PHP 8.
Sus imágenes se basan en versiones de Debian ya archivadas, así que el
`Dockerfile` generado redirige los repositorios a `archive.debian.org`. **No
reciben parches de seguridad**: úsalas solo si tu código lo necesita.

---

## Desarrollo

El script se escribe por módulos en `src/` y se compila a un único archivo:

```bash
bash build.sh                                 # genera dist/deploy.sh
RAW_URL=https://mi.servidor/x bash build.sh   # y sustituye la URL del one-liner

bash tests/smoke.sh          # 92 comprobaciones, sin necesidad de Docker
bash tests/gen-artifacts.sh  # genera las 24 combinaciones de stack para revisarlas
python3 tests/validate-compose.py  # valida esos 24 docker-compose.yml
```

`tests/smoke.sh` cubre el parseo de configuraciones PHP en los cinco formatos,
la reescritura del host, la asignación de puertos, la validación de parámetros
y la generación de artefactos. La validación de compose necesita PyYAML
(`pip install pyyaml`); sin él se omite sin fallar.

`dist/deploy.sh` es un artefacto generado: no lo edites a mano.

### Publicar una versión nueva

El one-liner apunta directamente a `dist/deploy.sh` de la rama `main`, así que
publicar es hacer *push*. **Reconstruye siempre antes de commitear**: si tocas
`src/` y no ejecutas `build.sh`, el repositorio quedaría sirviendo la versión
anterior.

```bash
bash build.sh          # regenera dist/deploy.sh con la URL de produccion
bash tests/smoke.sh    # 95 comprobaciones
git add -A && git commit -m "..." && git push
```

Después conviene comprobar que se sirve lo que esperas:

```bash
RAW=https://raw.githubusercontent.com/andru2025/doc/main/dist/deploy.sh
curl -fsSL "$RAW" | head -1     # debe salir el shebang
curl -fsSL "$RAW" | wc -l       # mismo número de líneas que dist/deploy.sh
curl -fsSL "$RAW" | bash -s -- --version
```

Dos detalles de GitHub que conviene tener presentes:

- **`raw.githubusercontent.com` cachea unos 5 minutos.** Tras un *push*, la
  versión antigua puede seguir sirviéndose un rato. Para forzar la nueva:
  `curl -H 'Cache-Control: no-cache' …`
- **Finales de línea.** `build.sh` garantiza LF en el artefacto y el repositorio
  lleva un `.gitattributes` que impide que git los convierta a CRLF. Sin eso,
  bash fallaría en el VPS con `bad interpreter`.

Para las pruebas reales en máquinas Linux, ver [`tests/vms.md`](tests/vms.md).
