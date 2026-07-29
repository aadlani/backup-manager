

# Backup Manager

[![CI](https://github.com/aadlani/backup-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/aadlani/backup-manager/actions/workflows/ci.yml)

Un sistema de copias de seguridad portátil e incremental construido enteramente con herramientas Unix estándar. Originalmente escrito para macOS en 2011, ahora funciona en cualquier sistema POSIX (Linux, macOS, FreeBSD, ...).

El objetivo de este proyecto es doble:

1. **Proporcionar una solución práctica de copias de seguridad** — programada, incremental, basada en instantáneas, cifrada y que no requiere intervención manual.
2. **Enseñar los fundamentos de Unix mediante ejemplos** — cada comando, opción y técnica utilizada en el script se explica a continuación para que los principiantes puedan aprender programación de shell en entornos reales a partir de una herramienta práctica.

---

## Características

| Requisito | Cómo se cumple |
|-----------------|-------------|
| **Regular** | Se ejecuta en un cronograma cron (p. ej., cada 30 min) |
| **Discreto** | Se ejecuta como trabajo en segundo plano, sin necesidad de interacción |
| **Incremental** | rsync solo envía deltas; los enlaces duros eliminan duplicados de archivos sin cambios |
| **Instantáneas** | Cada ejecución crea una copia puntual con marca de tiempo |
| **Rápido** | Los enlaces duros + transferencia de deltas mantienen al mínimo el E/S y el espacio |
| **Seguro** | Los archivos se cifran con GPG (opcional) |
| **Consistente** | Conserva permisos, marcas de tiempo, enlaces simbólicos y propiedad |

---

## Inicio rápido

```bash
# 1. Clone the repo
git clone https://github.com/aadlani/backup-manager.git
cd backup-manager

# 2. Create your configuration
cp backup.conf.example backup.conf
$EDITOR backup.conf          # set BACKUP_SOURCE_DIR, BACKUP_HOME, etc.

# 3. Run it
./backup.sh

# 4. (Optional) Schedule it with cron — see the cron section below
crontab -e
```

### Dependencias

Solo utilidades Unix estándar: no es necesario instalar nada en la mayoría de los sistemas:

- `rsync`
- `tar`
- `find`
- `date`
- `gpg` (solo si habilitas el cifrado)

---

## Cómo funciona

El script ejecuta cinco pasos en orden:

```
 ┌─────────┐     ┌──────────┐     ┌─────────┐     ┌──────────┐
 │ Step 1   │────▶│ Step 2   │────▶│ Step 3   │────▶│ Step 4   │
 │ Snapshot │     │ Compress │     │ Encrypt  │     │ Rotate   │
 └─────────┘     └──────────┘     └─────────┘     └──────────┘
```

1. **Instantánea** — rsync copia el origen en un directorio con marca de tiempo, creando enlaces duros a los archivos sin cambios desde la instantánea anterior.
2. **Compresión** — las instantáneas anteriores a hoy se recopilan en archivos diarios `.tar.gz`.
3. **Cifrado** — los archivos no cifrados se cifran con GPG (se omite si `GPG_RECIPIENT` está vacío).
4. **Rotación** — los archivos diarios pasan a contenedores semanales y luego mensuales.

### Estructura de directorios

```
$BACKUP_HOME/
├── backups.log
├── current -> snapshots/202602211430    # symlink to the latest snapshot
├── snapshots/
│   ├── 202602211400/
│   ├── 202602211430/
│   └── 202602211500/
└── archives/
    ├── daily/
    │   └── 20260220.tar.gz.gpg
    ├── weekly/
    │   └── 202601.WK_2.tar.gz.gpg
    └── monthly/
        └── 202512.tar.gz.gpg
```

---

## Configuración

Copia `backup.conf.example` en una de estas ubicaciones:

| Prioridad | Ruta |
|----------|------|
| 1 | `./backup.conf` (junto al script) |
| 2 | `~/.backup.conf` |

Variables que puedes establecer:

| Variable | Valor predeterminado | Propósito |
|----------|---------|---------|
| `BACKUP_SOURCE_DIR` | `$HOME/Documents` | Directorio que se respaldará |
| `BACKUP_HOME` | `$HOME/backups` | Dónde se almacenan las instantáneas y los archivos |
| `GPG_RECIPIENT` | *(vacío: sin cifrado)* | Correo electrónico/ID de la clave GPG para cifrar archivos |
| `RSYNC_EXTRA_OPTS` | *(vacío)* | Opciones adicionales para rsync (p. ej. `--exclude`) |

---

## Trucos de Unix explicados

El resto de este README recorre los conceptos y comandos de Unix utilizados en `backup.sh`. Si estás aprendiendo shell, sigue leyendo.

### Modo estricto de shell

```sh
set -eu
```

- **`-e`** — salir inmediatamente si algún comando falla (devuelve un valor distinto de cero).
- **`-u`** — tratar las variables no definidas como errores en lugar de expandirlas silenciosamente a cadenas vacías.

Estas dos opciones detectan clases enteras de errores. Úsalas siempre.

> **Nota:** `set -o pipefail` es una extensión de Bash. El script usa
> `/bin/sh` para máxima portabilidad, por lo que se basa en `set -eu` y verifica explícitamente los resultados de las tuberías.

### Verificación de comandos

Antes de hacer nada, el script se asegura de que cada herramienta requerida esté disponible:

```sh
for cmd in date rsync find tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
done
```

- **`command -v`** es la forma POSIX de verificar si existe un comando.
  Preferirlo sobre `which`, que se comporta de manera diferente según el sistema.
- **`>/dev/null 2>&1`** silenciosa tanto stdout como stderr: solo nos importa
  el código de salida.

### Aritmética de fechas entre plataformas

Este es el mayor problema de portabilidad en los scripts de shell. macOS
incluye BSD `date`; Linux incluye GNU `date`. Tienen una sintaxis completamente
diferente para fechas relativas.

| Qué deseas | GNU date (Linux) | BSD date (macOS) |
|---------------|-------------------|-------------------|
| Ayer | `date -d "1 day ago" +%Y%m%d` | `date -v -1d +%Y%m%d` |
| El mes pasado | `date -d "1 month ago" +%Y%m` | `date -v -1m +%Y%m` |

El script detecta qué variante está disponible en tiempo de ejecución:

```sh
date_subtract() {
    _fmt="$1" _unit="$2" _n="$3"
    if date -d "now" +%s >/dev/null 2>&1; then
        # GNU date
        case "$_unit" in
            d) date -d "$_n day ago"   +"$_fmt" ;;
            m) date -d "$_n month ago" +"$_fmt" ;;
        esac
    else
        # BSD date
        case "$_unit" in
            d) date -v "-${_n}d" +"$_fmt" ;;
            m) date -v "-${_n}m" +"$_fmt" ;;
        esac
    fi
}
```

**Truco:** la detección en sí misma es solo `date -d "now"`. GNU date acepta
`-d`; BSD date no. Probamos una vez y hacemos la ramificación.

### rsync con enlaces duros

```sh
rsync -aH --link-dest="$CURRENT_LINK" "$BACKUP_SOURCE_DIR" "$SNAPSHOT_DIR/$NOW"
```

| Opción | Significado |
|------|---------|
| `-a` | Modo de archivo: recursivo, conserva permisos, marcas de tiempo, enlaces simbólicos, propietario y grupo |
| `-H` | Conservar enlaces duros dentro del origen |
| `--link-dest=DIR` | Para archivos sin cambios desde DIR, crear enlaces duros en lugar de copias |

El truco `--link-dest` es el núcleo de la eficiencia de espacio. Una instantánea de
143 MB de datos puede usar solo 16 KB de nuevo espacio en disco si casi nada
cambió:

```
$ du -sch backups/snapshots/*
143M  snapshots/202602211400
 16K  snapshots/202602211430
 16K  snapshots/202602211500
178M  total
```

- **`du -s`** — resumen (no recursar en subdirectorios)
- **`du -c`** — mostrar un total general al final
- **`du -h`** — tamaños legibles por humanos (K, M, G)

> **Advertencia:** Los enlaces duros no funcionan en sistemas de archivos NTFS o FAT (p. ej.
> montajes Samba). rsync volverá silenciosamente a copias completas.

### Enlaces simbólicos y `ln`

Después de cada instantánea, el script apunta `current` a la más reciente:

```sh
ln -snf "$LATEST" "$CURRENT_LINK"
```

| Opción | Propósito |
|------|---------|
| `-s` | Crear un enlace simbólico (blando), no un enlace duro |
| `-n` | Si el destino ya es un enlace simbólico a un directorio, no seguirlo |
| `-f` | Reemplazar el enlace existente |

Sin `-n`, `ln` seguiría el enlace simbólico existente y crearía un enlace
*dentro* del directorio de la instantánea antigua en lugar de reemplazar el enlace simbólico en sí.

### Comandos encadenados (`&&`)

```sh
command1 && command2
```

`command2` se ejecuta solo si `command1` tiene éxito (código de salida 0). Esto se usa
en todo el script para que las operaciones destructivas (como `rm`) solo se ejecuten
después de que el paso anterior se complete sin errores.

### Sustitución de comandos

```sh
LATEST="$(ls -1d "$SNAPSHOT_DIR"/* | tail -n1)"
```

`$(...)` ejecuta el comando contenido en un subshell y sustituye su
stdout en el comando externo. Preferir `$(...)` sobre los backticks (`` `...` ``)
porque se anida limpiamente y es más fácil de leer.

### `find` con expresiones regulares extendidas

El paso de rotación necesita coincidir con nombres de archivo como `20260220.tar.gz.gpg`. El
script usa un auxiliar para mantener la portabilidad:

```sh
find_ere() {
    _dir="$1"; shift
    if find "$_dir" -maxdepth 0 -regextype posix-extended >/dev/null 2>&1; then
        find "$_dir" -regextype posix-extended "$@"    # GNU find
    else
        find -E "$_dir" "$@"                           # BSD find
    fi
}
```

| Sistema | Cómo habilitar expresiones regulares extendidas |
|--------|-----------------------------|
| GNU find (Linux) | `-regextype posix-extended` |
| BSD find (macOS) | Opción `-E` antes de la ruta |

### `tar` — crear archivos comprimidos

```sh
tar -czf archive.tar.gz -C /parent dir1 dir2
```

| Opción | Significado |
|------|---------|
| `-c` | Crear un nuevo archivo |
| `-z` | Comprimir con gzip |
| `-f` | Escribir en el nombre de archivo dado |
| `-C` | Cambiar a este directorio antes de agregar archivos (evita almacenar rutas absolutas) |

### Cifrado con GPG

```sh
gpg --batch --yes -r "$GPG_RECIPIENT" --encrypt-files archive.tar.gz
```

| Opción | Significado |
|------|---------|
| `-r` | Destinatario: cifrar para que solo esta clave pueda descifrar |
| `--encrypt-files` | Cifrar cada argumento de archivo (produce archivos `.gpg`) |
| `--batch --yes` | Modo no interactivo, omitir solicitudes de confirmación |

Para descifrar más tarde:

```sh
gpg --decrypt-files archive.tar.gz.gpg
```

Se te pedirá tu frase de contraseña.

### Carga de archivos de configuración

```sh
. "$SCRIPT_DIR/backup.conf"
```

El comando punto (`.`) lee y ejecuta un archivo en el *shell actual*,
lo que significa que cualquier variable definida en ese archivo queda disponible para el resto del
script. Es el equivalente POSIX de `source` de Bash.

### Valores predeterminados de variables con `${VAR:-default}`

```sh
BACKUP_HOME="${BACKUP_HOME:-$HOME/backups}"
```

Si `BACKUP_HOME` no está definida o está vacía, usar `$HOME/backups`. Esta es una
expansión de parámetros POSIX: no se necesitan comandos externos.

### Redirección de stderr

```sh
command >/dev/null 2>&1
```

- `>/dev/null` — enviar stdout a la nada.
- `2>&1` — redirigir el descriptor de archivo 2 (stderr) a donde apunta actualmente 1 (stdout)
  (también a la nada).

El efecto combinado: silenciar el comando por completo. Útil cuando solo
te importa el código de salida.

### Recorte de cadenas con expansión de parámetros

```sh
TODAY="${NOW%????}"      # remove last 4 characters
THISMONTH="${TODAY%??}"  # remove last 2 characters
```

`${var%pattern}` elimina la coincidencia más corta de `pattern` desde el *final* de
`$var`. Cada `?` coincide con un carácter. Esto es shell POSIX: no se necesita
`cut` ni `sed` para recortes simples.

También existe `${var#pattern}` que elimina desde el *inicio*:

| Sintaxis | Elimina desde |
|--------|-------------|
| `${var%pattern}` | Final (coincidencia más corta) |
| `${var%%pattern}` | Final (coincidencia más larga) |
| `${var#pattern}` | Inicio (coincidencia más corta) |
| `${var##pattern}` | Inicio (coincidencia más larga) |

---

## Programación con cron

Edita tu crontab:

```sh
crontab -e
```

Una entrada de cron tiene cinco campos de tiempo seguidos por el comando:

```
*  *  *  *  *    command
┬  ┬  ┬  ┬  ┬
│  │  │  │  └─  day of week   (0-6, Sunday=0)
│  │  │  └────  month         (1-12)
│  │  └───────  day of month  (1-31)
│  └──────────  hour          (0-23)
└─────────────  minute        (0-59)
```

Ejemplo: ejecutar cada 30 minutos durante las horas laborables de lunes a viernes:

```
*/30 8-18 * * 1-5  /path/to/backup.sh
```

| Campo | Valor | Significado |
|-------|-------|---------|
| `*/30` | cada 30 min | el `/` significa "cada" |
| `8-18` | horas 8–18 | el `-` significa un rango |
| `1-5` | Lun–Vie | rango de días de la semana |

**Consejo:** usa `crontab -l` para listar tus entradas actuales sin abrir un
editor.

---

## Ejecución de pruebas

```sh
sh tests/test_backup.sh
```

El conjunto de pruebas está escrito en shell POSIX puro (no se necesita framework). Cubre:

- **Funciones auxiliares** — envoltorios de portabilidad `date_subtract` y `find_ere`
- **Configuración** — valores predeterminados y carga de archivos de configuración
- **Tubería de extremo a extremo** — creación de instantáneas, archivado, eliminación de duplicados con enlaces duros y salida de registros (requiere `rsync`)

CI ejecuta el conjunto completo tanto en **Ubuntu (GNU)** como en **macOS (BSD)** a través de
GitHub Actions, además del análisis estático de **ShellCheck**.

---

## Restauración de archivos

### Desde una instantánea (datos más recientes)

Las instantáneas son directorios simples: simplemente copia lo que necesites:

```sh
cp ~/backups/current/Documents/report.txt ~/Documents/
```

### Desde un archivo

```sh
# Desencriptar primero (si está cifrado)
gpg --decrypt-files ~/backups/archives/daily/20260220.tar.gz.gpg

# Extraer
tar -xzf ~/backups/archives/daily/20260220.tar.gz -C /tmp/restore/

# Explorar y copiar lo que necesites
ls /tmp/restore/
```

---

## Licencia

MIT: ver [LICENSE](LICENSE).

---

*Publicado originalmente en
[anouar.adlani.com](https://anouar.adlani.com/2011/12/how-to-backup-with-rsync-tar-gpg-on-osx.html)
en diciembre de 2011.*
