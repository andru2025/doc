# Pruebas reales en máquinas Linux

`tests/smoke.sh` cubre el parseo, la validación y la generación de artefactos,
pero no puede probar lo que de verdad importa: que Docker se instale en cada
distribución y que el stack levante. Eso hay que hacerlo en una VM o un VPS.

Marca cada casilla al comprobarlo.

## Matriz de distribuciones

Para cada una, ejecutar el despliegue completo **dos veces**: la primera sin
Docker instalado, la segunda con Docker ya presente (debe saltarse la fase 1).

| Distribución | Instala Docker | Segunda pasada lo omite | Notas |
|---|---|---|---|
| Ubuntu 24.04 | ☐ | ☐ | |
| Ubuntu 22.04 | ☐ | ☐ | |
| Debian 12 | ☐ | ☐ | |
| AlmaLinux 9 | ☐ | ☐ | **valida la ruta de SELinux** |
| Rocky Linux 9 | ☐ | ☐ | firewalld activo por defecto |
| Fedora reciente | ☐ | ☐ | |

En AlmaLinux/Rocky, confirmar además que el docroot se ve dentro del
contenedor (`docker compose exec web ls /var/www/html`); si aparece vacío, la
etiqueta `:Z` no se aplicó.

## Matriz de stack

| Combinación | Levanta | Sirve PHP | Conecta con la base |
|---|---|---|---|
| apache + mysql + PHP 8.3 | ☐ | ☐ | ☐ |
| apache + mariadb + PHP 8.3 | ☐ | ☐ | ☐ |
| nginx + mysql + PHP 8.3 | ☐ | ☐ | ☐ |
| nginx + mariadb + PHP 8.3 | ☐ | ☐ | ☐ |
| apache + mariadb + PHP 7.4 | ☐ | ☐ | ☐ |
| apache + mariadb + PHP 5.6 | ☐ | ☐ | ☐ |

PHP 7.4 y 5.6 son las que más riesgo tienen: sus imágenes están sobre Debian
archivado y el `apt-get update` del `Dockerfile` es el punto que puede fallar.

## Casos de comportamiento

- ☐ **Puertos consecutivos.** Desplegar dos proyectos seguidos en el mismo
  servidor. El segundo debe tomar 8081 y 33061 sin conflicto.
- ☐ **Puerto ocupado por un servicio nativo.** Levantar algo en el 8080 antes
  de desplegar (`python3 -m http.server 8080`) y comprobar que lo esquiva.
- ☐ **Contenedor parado.** Parar un despliegue anterior y comprobar que su
  puerto sigue considerándose ocupado.
- ☐ **Nombre repetido.** Reutilizar un nombre existente y probar las tres
  salidas del menú: otro nombre, recrear y cancelar.
- ☐ **Persistencia.** Importar un `.sql`, `manage.sh stop`, `manage.sh start`,
  y comprobar que las tablas siguen ahí. Repetir reiniciando el servidor.
- ☐ **Credenciales del proyecto.** Desplegar un proyecto real cuyo
  `config.php` traiga usuario y clave propios. La web debe conectar sin editar
  nada a mano.
- ☐ **Copia de seguridad del config.** Comprobar que existe el
  `.deployer.bak` y que conserva el host original.
- ☐ **Docroot en subdirectorio.** Un proyecto con el código en `public/` que
  además haga `require '../includes/config.php'`: debe funcionar (el montaje
  incluye todo el repositorio, no solo la raíz pública).
- ☐ **Varios `.sql`.** Un proyecto con tres volcados: comprobar el listado
  ordenado por tamaño, elegir uno, y luego repetir con `a` (todos) y `0`.
- ☐ **Volcado grande.** Un `.sql` de varios cientos de MB: el script debe
  esperar a que termine, no seguir adelante.
- ☐ **Volcado que no crea tablas.** Debe avisar en vez de dar el despliegue
  por bueno.
- ☐ **ZIP de GitHub.** Descargar un `.zip` cuyo contenido esté dentro de una
  carpeta: debe aplanarse solo.
- ☐ **Repositorio inexistente.** Debe fallar rápido y con un mensaje claro, no
  quedarse colgado pidiendo credenciales.
- ☐ **Rollback.** Interrumpir a mitad (o dar una URL de repositorio inválida
  tras crear el directorio) y comprobar que ofrece limpiar.
- ☐ **Modo desatendido.** Ejecutar con todos los parámetros y `< /dev/null`
  para simular la ausencia de TTY.
- ☐ **`--dry-run`.** No debe modificar absolutamente nada del sistema.
- ☐ **Cortafuegos.** En Rocky/AlmaLinux con firewalld activo, comprobar que el
  puerto queda abierto y el sitio es accesible desde fuera.
- ☐ **Base no expuesta.** Por defecto, `nmap` desde otra máquina no debe ver el
  puerto 33060.

## Receta rápida con Multipass

```bash
multipass launch 24.04 --name deployer-test --cpus 2 --memory 4G --disk 20G
multipass shell deployer-test
# dentro:
curl -fsSL <URL>/deploy.sh -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh
```

Para AlmaLinux y Rocky no hay imagen de Multipass: usar una VM en VirtualBox o
un VPS de pago por horas.
