#!/usr/bin/env bash

# Copyright (c) 2026 Psycomy
# License: MIT
# Repo:   https://github.com/Psycomy/oxidized-proxmox-lxc
# Source: https://github.com/ytti/oxidized
#
# EN: Installs Oxidized inside an LXC (Debian 13, Ubuntu 24.04, Ubuntu 26.04)
#     in the style of community-scripts/ProxmoxVE. English and Spanish.
# ES: Instala Oxidized dentro de un LXC (Debian 13, Ubuntu 24.04, Ubuntu 26.04)
#     con el estilo de community-scripts/ProxmoxVE. En inglés y español.
#
# Usage / Uso (pin a tag, not the main branch / apunta a una etiqueta, no a main):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Psycomy/oxidized-proxmox-lxc/v1.1.0/oxidized-install.sh)"
#
# Unattended install / Instalación desatendida (each variable skips its question):
#   OXI_LANG=en|es
#   OXI_WEB_MODE=none|direct|nginx   OXI_WEB_USER  OXI_WEB_PASS
#   OXI_GIT_MODE=local|remote        OXI_GIT_REMOTE (e.g. git@gitea.local:net/configs.git)
#   OXI_TELEGRAM=yes|no              OXI_TG_TOKEN  OXI_TG_CHAT
#   OXI_INTERVAL=3600                VERBOSE=yes
#   OXI_VERSION / OXI_WEB_VERSION    pin gem versions (default: latest)

set -Eeuo pipefail

# Idioma del sistema antes de forzar UTF-8 (sirve para preseleccionar el idioma)
SYS_LANG="${LC_ALL:-${LANG:-}}"

# Los LXC suelen arrancar con locale C/POSIX: whiptail corta el texto en la
# primera letra con tilde. C.UTF-8 viene incluido en glibc (no hay que generarlo).
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
fi

APP="Oxidized"
OXI_HOME="/etc/oxidized"
OXI_DATA="/var/lib/oxidized"
OXI_REPO="${OXI_DATA}/configs.git"
OXI_USER="oxidized"
OXI_PORT="8888"
INSTALL_LOG="/var/log/oxidized-install.log"
LANG_FILE="${OXI_HOME}/installer.lang"
SUPPORTED_OS="Debian 13, Ubuntu 24.04, Ubuntu 26.04"

# ---------------------------------------------------------------------------
# Idioma: L "texto en español" "English text"
# ---------------------------------------------------------------------------
UI_LANG="${OXI_LANG:-}"

L() {
  if [[ "${UI_LANG}" == "es" ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# ---------------------------------------------------------------------------
# Estilo (colores, iconos y spinner al estilo community-scripts)
# ---------------------------------------------------------------------------
YW=$'\033[33m'
YWB=$'\033[93m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
DGN=$'\033[32m'
CL=$'\033[m'
BOLD=$'\033[1m'
BFR=$'\r\033[K'
TAB="  "
CM="${TAB}✔️${TAB}"
CROSS="${TAB}✖️${TAB}"
INFO="${TAB}💡${TAB}"
WARN="${TAB}⚠️${TAB}"
HOURGLASS="${TAB}⏳${TAB}"
SPINNER_PID=""

header_info() {
  clear
  cat <<'EOF'
   ____        _     ___               __
  / __ \_  __ (_)___/ (_)___  ___  ___/ /
 / / / / |/_// / __  / /_  / / _ \/ __  /
/ /_/ />  < / / /_/ / / / /_/  __/ /_/ /
\____/_/|_|/_/\__,_/_/ /___/\___/\__,_/

EOF
}

spinner() {
  local chars=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
  while true; do
    printf "\r\033[2K%s %b" "${TAB}${YWB}${chars[i]}${CL}" "${YWB}${SPINNER_MSG}${CL}"
    i=$(((i + 1) % ${#chars[@]}))
    sleep 0.1
  done
}

stop_spinner() {
  if [[ -n "${SPINNER_PID}" ]] && kill -0 "${SPINNER_PID}" 2>/dev/null; then
    kill "${SPINNER_PID}" 2>/dev/null || true
    wait "${SPINNER_PID}" 2>/dev/null || true
  fi
  SPINNER_PID=""
  printf "%s" "${BFR}"
  stty sane 2>/dev/null || true
}

msg_info() {
  stop_spinner
  if [[ "${VERBOSE:-no}" == "yes" || ! -t 1 ]]; then
    echo -e "${HOURGLASS}${YW}$1${CL}"
  else
    SPINNER_MSG="$1"
    spinner &
    SPINNER_PID=$!
    disown "${SPINNER_PID}" 2>/dev/null || true
  fi
}

msg_ok() {
  stop_spinner
  echo -e "${CM}${GN}$1${CL}"
}

msg_warn() {
  stop_spinner
  echo -e "${WARN}${YWB}$1${CL}"
}

msg_error() {
  stop_spinner
  echo -e "${CROSS}${RD}$1${CL}" >&2
}

# Equivalente al $STD de community-scripts: oculta la salida salvo con VERBOSE=yes
silent() {
  if [[ "${VERBOSE:-no}" == "yes" ]]; then
    "$@" 2>&1 | tee -a "${INSTALL_LOG}"
  else
    "$@" >>"${INSTALL_LOG}" 2>&1
  fi
}
STD="silent"

error_handler() {
  local exit_code=$? line=$1 cmd=$2
  stop_spinner
  echo -e "\n${CROSS}${RD}$(L "Error en la línea ${line} (código ${exit_code})" "Error on line ${line} (exit code ${exit_code})"): ${YW}${cmd}${CL}" >&2
  echo -e "${INFO}${YW}$(L "Revisa el log" "Check the log"): ${BL}${INSTALL_LOG}${CL}" >&2
  exit "${exit_code}"
}
trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR
trap 'stop_spinner' EXIT
trap 'stop_spinner; echo; msg_error "$(L "Cancelado por el usuario" "Cancelled by user")"; exit 130' INT TERM

exit_script() {
  stop_spinner
  echo -e "\n${CROSS}${YW}$(L "Instalación cancelada" "Installation cancelled")${CL}\n"
  exit 0
}

# ---------------------------------------------------------------------------
# Diálogos (whiptail, o variable de entorno si está definida)
# ---------------------------------------------------------------------------
BACKTITLE="Oxidized LXC Installer"

ask_menu() { # ask_menu <var> <título> <texto> <tag> <desc> ...
  local var=$1 title=$2 text=$3
  shift 3
  [[ -n "${!var:-}" ]] && return 0
  local choice
  choice=$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --menu "${text}" 16 78 6 "$@" 3>&1 1>&2 2>&3) || exit_script
  printf -v "${var}" '%s' "${choice}"
}

ask_input() { # ask_input <var> <título> <texto> [valor por defecto]
  local var=$1 title=$2 text=$3 def=${4:-} value
  [[ -n "${!var:-}" ]] && return 0
  while true; do
    value=$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --inputbox "${text}" 10 72 "${def}" 3>&1 1>&2 2>&3) || exit_script
    [[ -n "${value}" ]] && break
    whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "$(L "El valor no puede estar vacío." "The value cannot be empty.")" 8 50
  done
  printf -v "${var}" '%s' "${value}"
}

ask_password() { # ask_password <var> <título> <texto> [texto de confirmación]
  local var=$1 title=$2 text=$3 confirm=${4:-} p1 p2
  [[ -n "${confirm}" ]] || confirm=$(L "Repite la contraseña:" "Repeat the password:")
  [[ -n "${!var:-}" ]] && return 0
  while true; do
    p1=$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --passwordbox "${text}" 10 72 3>&1 1>&2 2>&3) || exit_script
    p2=$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --passwordbox "${confirm}" 10 72 3>&1 1>&2 2>&3) || exit_script
    if [[ -z "${p1}" ]]; then
      whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "$(L "El valor no puede estar vacío." "The value cannot be empty.")" 8 50
    elif [[ "${p1}" != "${p2}" ]]; then
      whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "$(L "Los dos valores no coinciden; vuelve a introducirlo." "The two values do not match; please enter it again.")" 8 60
    else
      break
    fi
  done
  printf -v "${var}" '%s' "${p1}"
}

ask_yesno() { # ask_yesno <título> <texto>  -> 0 = sí
  whiptail --backtitle "${BACKTITLE}" --title "$1" --yes-button "$(L "Sí" "Yes")" --no-button "No" --yesno "$2" 12 72
}

# Primera pregunta: idioma. Se preselecciona el de una instalación previa o el del sistema.
choose_language() {
  if [[ -n "${UI_LANG}" ]]; then
    case "${UI_LANG}" in en | es) return 0 ;; esac
    echo "OXI_LANG must be 'en' or 'es' / OXI_LANG debe ser 'en' o 'es'" >&2
    exit 1
  fi
  local def=en
  if [[ -f "${LANG_FILE}" ]]; then
    def=$(<"${LANG_FILE}")
  elif [[ "${SYS_LANG}" == es* ]]; then
    def=es
  fi
  if [[ ! -t 0 ]]; then
    UI_LANG="${def}"
    return 0
  fi
  UI_LANG=$(whiptail --backtitle "${BACKTITLE}" --title "Language / Idioma" --default-item "${def}" \
    --menu "Choose the installer language\nElige el idioma del instalador" 12 60 2 \
    "en" "English" \
    "es" "Español" 3>&1 1>&2 2>&3) || exit_script
}

# ---------------------------------------------------------------------------
# Comprobaciones previas
# ---------------------------------------------------------------------------
check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    msg_error "This script must be run as root / Este script debe ejecutarse como root"
    exit 1
  fi
}

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID}"
  OS_VERSION="${VERSION_ID}"
  case "${OS_ID}:${OS_VERSION}" in
  debian:13 | ubuntu:24.04 | ubuntu:26.04)
    msg_ok "$(L "Sistema soportado" "Supported system"): ${BL}${PRETTY_NAME}${CL}"
    ;;
  *)
    msg_error "$(L "Sistema no soportado" "Unsupported system"): ${PRETTY_NAME:-?}"
    echo -e "${INFO}${YW}$(L "Soportados" "Supported"): ${SUPPORTED_OS}${CL}"
    exit 1
    ;;
  esac
}

check_container() {
  local virt
  virt=$(systemd-detect-virt --container 2>/dev/null || true)
  if [[ "${virt}" != "lxc" ]]; then
    msg_warn "$(L "No parece un LXC (detectado: ${virt:-none}); se continúa igualmente" "This does not look like an LXC (detected: ${virt:-none}); continuing anyway")"
    return
  fi
  if awk 'NR==1 && !($1==0 && $2==0) {exit 0} {exit 1}' /proc/self/uid_map; then
    msg_ok "$(L "LXC no privilegiado detectado (Oxidized funciona sin problemas)" "Unprivileged LXC detected (Oxidized works fine)")"
  else
    msg_ok "$(L "LXC privilegiado detectado" "Privileged LXC detected")"
  fi
  # Ningún requisito de Oxidized necesita privilegios; solo avisamos de lo que puede fallar
  local state
  state=$(systemctl is-system-running 2>/dev/null || true)
  if [[ "${state}" == "offline" || -z "${state}" ]]; then
    msg_warn "$(L "systemd no está operativo en el contenedor; el servicio no podrá arrancar" "systemd is not running in the container; the service will not be able to start")"
  fi
}

check_network() {
  msg_info "$(L "Comprobando conectividad (DNS y rubygems.org)" "Checking connectivity (DNS and rubygems.org)")"
  if ! getent hosts rubygems.org >/dev/null 2>&1; then
    msg_error "$(L "No se resuelve rubygems.org: revisa el DNS del contenedor" "Cannot resolve rubygems.org: check the container DNS")"
    exit 1
  fi
  if ! timeout 15 bash -c 'exec 3<>/dev/tcp/rubygems.org/443' 2>/dev/null; then
    msg_error "$(L "Sin acceso a rubygems.org:443: revisa la salida a Internet / proxy" "No access to rubygems.org:443: check Internet access / proxy")"
    exit 1
  fi
  msg_ok "$(L "Conectividad correcta" "Connectivity OK")"
}

is_installed() {
  [[ -f "${OXI_HOME}/config" ]] || [[ -f /etc/systemd/system/oxidized.service ]]
}

oxidized_version() {
  gem list --exact oxidized 2>/dev/null | sed -n 's/^oxidized (\([^,)]*\).*/\1/p'
}

has_nodes() {
  grep -qvE '^[[:space:]]*(#|$)' "${OXI_HOME}/router.db" 2>/dev/null
}

container_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Preguntas de instalación
# ---------------------------------------------------------------------------
gather_options() {
  local web_preset="${OXI_WEB_MODE:-}"
  while true; do
    ask_menu OXI_WEB_MODE "$(L "Interfaz web" "Web interface")" "$(L "¿Cómo quieres exponer oxidized-web?" "How do you want to expose oxidized-web?")" \
      "nginx" "$(L "HTTPS (nginx, puerto 443) con usuario/contraseña" "HTTPS (nginx, port 443) with username/password")" \
      "none" "$(L "Sin web (API solo en 127.0.0.1, usada por oxidized-reload)" "No web (API on 127.0.0.1 only, used by oxidized-reload)")" \
      "direct" "$(L "HTTP directo en el puerto ${OXI_PORT}, SIN autenticación" "Plain HTTP on port ${OXI_PORT}, NO authentication")"
    [[ "${OXI_WEB_MODE}" != "direct" || -n "${web_preset}" ]] && break
    if ask_yesno "$(L "⚠️  Web sin autenticación" "⚠️  Web without authentication")" "$(L \
      "Cualquiera que llegue al puerto ${OXI_PORT} podrá:\n\n - Leer y buscar en TODAS las configuraciones guardadas\n   (hashes de contraseñas, comunidades SNMP, claves de VPN...)\n - Lanzar copias y recargar el inventario\n\nTodo viaja sin cifrar. ¿Seguro que quieres este modo?" \
      "Anyone who can reach port ${OXI_PORT} will be able to:\n\n - Read and search ALL stored configurations\n   (password hashes, SNMP communities, VPN keys...)\n - Trigger backups and reload the inventory\n\nEverything travels unencrypted. Are you sure you want this mode?")"; then
      break
    fi
    OXI_WEB_MODE=""
  done
  case "${OXI_WEB_MODE}" in none | direct | nginx) ;; *)
    msg_error "$(L "OXI_WEB_MODE inválido" "Invalid OXI_WEB_MODE"): ${OXI_WEB_MODE}"
    exit 1
    ;;
  esac
  if [[ "${OXI_WEB_MODE}" == "nginx" ]]; then
    ask_input OXI_WEB_USER "$(L "Autenticación web" "Web authentication")" "$(L "Usuario para acceder a la web:" "Username for the web interface:")" "admin"
    ask_password OXI_WEB_PASS "$(L "Autenticación web" "Web authentication")" "$(L "Contraseña para el usuario ${OXI_WEB_USER}:" "Password for user ${OXI_WEB_USER}:")"
  fi

  ask_menu OXI_GIT_MODE "$(L "Almacenamiento" "Storage")" "$(L "¿Dónde guardar las configuraciones?" "Where should configurations be stored?")" \
    "local" "$(L "Repositorio git local en ${OXI_REPO}" "Local git repository in ${OXI_REPO}")" \
    "remote" "$(L "Git local + push automático a un remoto (Gitea, GitHub...)" "Local git + automatic push to a remote (Gitea, GitHub...)")"
  case "${OXI_GIT_MODE}" in local | remote) ;; *)
    msg_error "$(L "OXI_GIT_MODE inválido" "Invalid OXI_GIT_MODE"): ${OXI_GIT_MODE}"
    exit 1
    ;;
  esac
  if [[ "${OXI_GIT_MODE}" == "remote" ]]; then
    ask_input OXI_GIT_REMOTE "$(L "Repositorio remoto" "Remote repository")" \
      "$(L "URL SSH del repositorio remoto (debe existir y estar vacío):\nej. git@gitea.local:red/oxidized-configs.git" "SSH URL of the remote repository (must exist and be empty):\ne.g. git@gitea.local:net/oxidized-configs.git")" ""
  fi

  if [[ -z "${OXI_TELEGRAM:-}" ]]; then
    if ask_yesno "$(L "Notificaciones" "Notifications")" "$(L "¿Quieres recibir un aviso por Telegram cada vez que cambie la configuración de un equipo?" "Do you want a Telegram notification every time a device configuration changes?")"; then
      OXI_TELEGRAM="yes"
    else
      OXI_TELEGRAM="no"
    fi
  fi
  if [[ "${OXI_TELEGRAM}" == "yes" ]]; then
    ask_password OXI_TG_TOKEN "Telegram" "$(L "Token del bot (de @BotFather):" "Bot token (from @BotFather):")" "$(L "Repite el token del bot:" "Repeat the bot token:")"
    ask_input OXI_TG_CHAT "Telegram" "$(L "Chat ID destino (usuario, grupo o canal):" "Destination chat ID (user, group or channel):")" ""
  fi

  ask_input OXI_INTERVAL "$(L "Intervalo" "Interval")" "$(L "Segundos entre copias de cada equipo:" "Seconds between backups of each device:")" "3600"
  if ! [[ "${OXI_INTERVAL}" =~ ^[0-9]+$ ]]; then
    msg_error "$(L "OXI_INTERVAL debe ser un número de segundos" "OXI_INTERVAL must be a number of seconds")"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Instalación
# ---------------------------------------------------------------------------
install_dependencies() {
  msg_info "$(L "Actualizando el sistema" "Updating the system")"
  export DEBIAN_FRONTEND=noninteractive
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "$(L "Sistema actualizado" "System updated")"

  if [[ "${OS_ID}" == "ubuntu" ]] && ! apt-cache policy libssh2-1-dev 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    msg_info "$(L "Habilitando el repositorio universe" "Enabling the universe repository")"
    $STD apt-get install -y software-properties-common
    $STD add-apt-repository -y universe
    $STD apt-get update
    msg_ok "$(L "Repositorio universe habilitado" "Universe repository enabled")"
  fi

  msg_info "$(L "Instalando dependencias" "Installing dependencies")"
  local pkgs=(
    ruby ruby-dev libsqlite3-dev libssl-dev pkg-config cmake make g++
    libssh2-1-dev libicu-dev zlib1g-dev libyaml-dev libzstd-dev
    git curl ca-certificates openssh-client openssl
  )
  [[ "${OXI_WEB_MODE}" == "nginx" ]] && pkgs+=(nginx)
  $STD apt-get install -y --no-install-recommends "${pkgs[@]}"
  msg_ok "$(L "Dependencias instaladas" "Dependencies installed")"

  local ruby_ver
  ruby_ver=$(ruby -e 'print RUBY_VERSION')
  if ! ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1") ? 0 : 1)'; then
    msg_error "$(L "Ruby ${ruby_ver} es demasiado antiguo (Oxidized necesita >= 3.1)" "Ruby ${ruby_ver} is too old (Oxidized needs >= 3.1)")"
    exit 1
  fi
  msg_ok "Ruby ${ruby_ver}"
}

install_oxidized() {
  msg_info "$(L "Instalando Oxidized y oxidized-web (compila extensiones, tarda unos minutos)" "Installing Oxidized and oxidized-web (builds extensions, takes a few minutes)")"
  local gems=(oxidized)
  [[ -n "${OXI_VERSION:-}" ]] && gems+=(-v "${OXI_VERSION}")
  $STD gem install --no-document "${gems[@]}"
  gems=(oxidized-web)
  [[ -n "${OXI_WEB_VERSION:-}" ]] && gems+=(-v "${OXI_WEB_VERSION}")
  $STD gem install --no-document "${gems[@]}"
  OXI_BIN=$(command -v oxidized || true)
  if [[ -z "${OXI_BIN}" ]]; then
    msg_error "$(L "No se encuentra el binario de oxidized tras instalar la gema" "The oxidized binary was not found after installing the gem")"
    exit 1
  fi
  msg_ok "$(L "Instalado" "Installed") Oxidized $(oxidized_version) (${OXI_BIN})"

  if [[ "${OXI_GIT_MODE}" == "remote" ]] && ! ruby -e 'require "rugged"; exit(Rugged.features.include?(:ssh) ? 0 : 1)' 2>/dev/null; then
    msg_error "$(L "rugged se compiló sin soporte SSH: el push al remoto no funcionará" "rugged was built without SSH support: pushing to the remote will not work")"
    exit 1
  fi
}

create_user_dirs() {
  msg_info "$(L "Creando usuario y directorios" "Creating user and directories")"
  if ! id "${OXI_USER}" >/dev/null 2>&1; then
    useradd --system --home-dir "${OXI_DATA}" --create-home --shell /usr/sbin/nologin "${OXI_USER}"
  fi
  install -d -m 0750 -o "${OXI_USER}" -g "${OXI_USER}" "${OXI_HOME}" "${OXI_DATA}" "${OXI_DATA}/crashes"
  # Huellas SSH de los equipos (input.ssh.secure) y del remoto git
  install -d -m 0700 -o "${OXI_USER}" -g "${OXI_USER}" "${OXI_DATA}/.ssh"
  [[ -f "${OXI_DATA}/.ssh/known_hosts" ]] || install -m 0644 -o "${OXI_USER}" -g "${OXI_USER}" /dev/null "${OXI_DATA}/.ssh/known_hosts"
  msg_ok "$(L "Usuario ${OXI_USER} y directorios creados" "User ${OXI_USER} and directories created")"
}

setup_git_remote() {
  [[ "${OXI_GIT_MODE}" == "remote" ]] || return 0
  msg_info "$(L "Generando clave SSH para el push al remoto" "Generating SSH key for pushing to the remote")"
  local sshdir="${OXI_DATA}/.ssh" host port keys
  if [[ ! -f "${sshdir}/id_rsa" ]]; then
    # El hook githubrepo (rugged/libssh2) exige el formato PEM clásico
    $STD sudo_oxi ssh-keygen -q -t rsa -b 4096 -m PEM -N "" -C "oxidized@$(hostname)" -f "${sshdir}/id_rsa"
  fi
  # Extrae host y puerto de git@host:ruta o ssh://user@host:puerto/ruta
  if [[ "${OXI_GIT_REMOTE}" =~ ^https?:// ]]; then
    msg_error "$(L "El push necesita una URL SSH, no HTTP(S)" "Pushing requires an SSH URL, not HTTP(S)"): ${OXI_GIT_REMOTE}"
    exit 1
  elif [[ "${OXI_GIT_REMOTE}" =~ ^ssh://([^@/]+@)?([^:/]+)(:([0-9]+))?/ ]]; then
    host="${BASH_REMATCH[2]}"
    port="${BASH_REMATCH[4]:-22}"
  elif [[ "${OXI_GIT_REMOTE}" =~ ^([^@]+@)?([^:]+): ]]; then
    host="${BASH_REMATCH[2]}"
    port=22
  else
    msg_error "$(L "URL de remoto no reconocida (usa formato SSH)" "Unrecognised remote URL (use SSH format)"): ${OXI_GIT_REMOTE}"
    exit 1
  fi
  # Se confía en la huella obtenida ahora (primer uso); compruébala si puedes
  if keys=$(ssh-keyscan -p "${port}" -T 10 "${host}" 2>/dev/null) && [[ -n "${keys}" ]]; then
    echo "${keys}" >>"${sshdir}/known_hosts"
    chown "${OXI_USER}:${OXI_USER}" "${sshdir}/known_hosts"
    msg_ok "$(L "Clave SSH generada y huella de ${host} registrada" "SSH key generated and ${host} fingerprint recorded")"
  else
    msg_warn "$(L "No se pudo obtener la huella SSH de ${host}:${port}; revisa la URL/red" "Could not get the SSH fingerprint of ${host}:${port}; check the URL/network")"
  fi

  if [[ -t 0 ]]; then
    whiptail --backtitle "${BACKTITLE}" --title "Deploy key" --scrolltext --msgbox \
      "$(L "Añade esta clave pública como Deploy Key CON PERMISO DE ESCRITURA en el repositorio remoto y pulsa Aceptar:" "Add this public key as a Deploy Key WITH WRITE ACCESS on the remote repository, then press OK:")\n\n$(cat "${sshdir}/id_rsa.pub")" 20 78
  fi
  echo -e "${INFO}${YW}$(L "Clave pública (deploy key con escritura):" "Public key (deploy key with write access):")${CL}"
  echo -e "${TAB}${DGN}$(cat "${sshdir}/id_rsa.pub")${CL}"
}

sudo_oxi() {
  runuser -u "${OXI_USER}" -- "$@"
}

write_config() {
  msg_info "$(L "Escribiendo configuración" "Writing configuration")"
  local listen="127.0.0.1"
  [[ "${OXI_WEB_MODE}" == "direct" ]] && listen="0.0.0.0"

  cat >"${OXI_HOME}/config" <<EOF
---
# $(L "Configuración de Oxidized generada por oxidized-install.sh" "Oxidized configuration generated by oxidized-install.sh")
# $(L "Documentación" "Documentation"): https://github.com/ytti/oxidized/blob/master/docs/Configuration.md
# $(L "Tras editar este fichero" "After editing this file"): systemctl restart oxidized
# $(L "Credenciales por defecto (cada equipo las sobrescribe en router.db)" "Default credentials (each device overrides them in router.db)")
username: oxidized
password: changeme
model: ios
resolve_dns: true
interval: ${OXI_INTERVAL}
debug: false
threads: 30
use_max_threads: false
timeout: 20
retries: 3
prompt: !ruby/regexp /^([\w.@-]+[#>]\s?)$/
next_adds_job: false
vars: {}
groups: {}
models: {}
pid: "/run/oxidized/oxidized.pid"
crash:
  directory: "${OXI_DATA}/crashes"
  hostnames: false
stats:
  history_size: 10
extensions:
  oxidized-web:
    load: true
    listen: ${listen}
    port: ${OXI_PORT}
    # $(L "La web muestra las vars de cada equipo: sin esto el enable se ve en claro" "The web UI shows each device's vars: without this the enable password is visible")
    hide_node_vars:
      - enable
input:
  # $(L "Solo SSH: con \"ssh, telnet\", si SSH falla Oxidized reintenta por Telnet y" "SSH only: with \"ssh, telnet\", if SSH fails Oxidized retries over Telnet and")
  # $(L "envía las credenciales en claro. Para un modelo que solo tenga Telnet:" "sends credentials in clear text. For a model that only has Telnet:")
  #   models: { <$(L "modelo" "model")>: { input: telnet } }
  default: ssh
  debug: false
  ssh:
    # $(L "Verifica la huella SSH de cada equipo contra" "Verifies each device's SSH fingerprint against") ${OXI_DATA}/.ssh/known_hosts.
    # $(L "oxidized-reload registra automáticamente la de los equipos nuevos." "oxidized-reload records new devices' fingerprints automatically.")
    secure: true
  utf8_encoded: true
output:
  default: git
  git:
    user: Oxidized
    email: oxidized@$(hostname -f 2>/dev/null || hostname)
    repo: "${OXI_REPO}"
source:
  default: csv
  csv:
    file: "${OXI_HOME}/router.db"
    # $(L "Se usa ';' para admitir IPv6 y ':' dentro de las contraseñas" "';' is used so IPv6 addresses and ':' inside passwords are allowed")
    delimiter: !ruby/regexp /;/
    map:
      name: 0
      ip: 1
      model: 2
      username: 3
      password: 4
    vars_map:
      enable: 5
    gpg: false
model_map:
  cisco: ios
  juniper: junos
  mikrotik: routeros
EOF

  if [[ "${OXI_GIT_MODE}" == "remote" || "${OXI_TELEGRAM}" == "yes" ]]; then
    echo "hooks:" >>"${OXI_HOME}/config"
  fi
  if [[ "${OXI_GIT_MODE}" == "remote" ]]; then
    cat >>"${OXI_HOME}/config" <<EOF
  push_to_remote:
    type: githubrepo
    events: [post_store]
    remote_repo: "${OXI_GIT_REMOTE}"
    publickey: "${OXI_DATA}/.ssh/id_rsa.pub"
    privatekey: "${OXI_DATA}/.ssh/id_rsa"
EOF
  fi
  if [[ "${OXI_TELEGRAM}" == "yes" ]]; then
    cat >>"${OXI_HOME}/config" <<EOF
  telegram:
    type: exec
    events: [post_store]
    cmd: "/usr/local/bin/oxidized-telegram-notify"
    async: true
    timeout: 60
EOF
  fi

  if [[ ! -f "${OXI_HOME}/router.db" ]]; then
    if [[ "${UI_LANG}" == "es" ]]; then
      cat >"${OXI_HOME}/router.db" <<'EOF'
# Inventario de Oxidized: un equipo por línea, campos separados por ';'
#
#   nombre;ip;modelo;usuario;contraseña;enable
#
# - nombre: identificador único (aparece en la web y en el repositorio git)
# - modelo: ios, nxos, junos, routeros, fortios, procurve, comware, eos...
#   lista completa: https://github.com/ytti/oxidized/blob/master/docs/Supported-OS-Types.md
# - enable: déjalo vacío si el equipo no lo necesita (la línea acaba en ';')
#
# Tras editar este fichero ejecuta: oxidized-reload
#
# Ejemplos:
# core-sw01;192.0.2.10;ios;backup;S3cr3t;EnableS3cr3t
# edge-rtr01;2001:db8::1;junos;backup;Otra:Clave;
# mk-oficina;198.51.100.5;routeros;admin;MiClave;
EOF
    else
      cat >"${OXI_HOME}/router.db" <<'EOF'
# Oxidized inventory: one device per line, fields separated by ';'
#
#   name;ip;model;username;password;enable
#
# - name: unique identifier (shown in the web UI and in the git repository)
# - model: ios, nxos, junos, routeros, fortios, procurve, comware, eos...
#   full list: https://github.com/ytti/oxidized/blob/master/docs/Supported-OS-Types.md
# - enable: leave it empty if the device does not need it (line ends with ';')
#
# After editing this file run: oxidized-reload
#
# Examples:
# core-sw01;192.0.2.10;ios;backup;S3cr3t;EnableS3cr3t
# edge-rtr01;2001:db8::1;junos;backup;Another:Pass;
# mk-office;198.51.100.5;routeros;admin;MyPass;
EOF
    fi
  fi

  echo "${UI_LANG}" >"${LANG_FILE}"
  chown -R "${OXI_USER}:${OXI_USER}" "${OXI_HOME}"
  chmod 0640 "${OXI_HOME}/config"
  chmod 0600 "${OXI_HOME}/router.db"
  msg_ok "$(L "Configuración escrita en ${OXI_HOME}" "Configuration written to ${OXI_HOME}")"
}

setup_telegram() {
  [[ "${OXI_TELEGRAM}" == "yes" ]] || return 0
  msg_info "$(L "Configurando notificaciones de Telegram" "Setting up Telegram notifications")"
  (
    umask 027
    printf 'TG_TOKEN=%q\nTG_CHAT=%q\n' "${OXI_TG_TOKEN}" "${OXI_TG_CHAT}" >"${OXI_HOME}/telegram.env"
  )
  chown "root:${OXI_USER}" "${OXI_HOME}/telegram.env"
  chmod 0640 "${OXI_HOME}/telegram.env"

  {
    echo '#!/usr/bin/env bash'
    echo "# Oxidized hook (post_store event): Telegram notification on configuration changes."
    echo "# Hook de Oxidized (evento post_store): aviso por Telegram de cambios de configuración."
    echo "# Test / Prueba: oxidized-telegram-notify --test"
    echo "MSG_LANG=\"${UI_LANG}\""
    cat <<'EOF'
set -uo pipefail
# shellcheck disable=SC1091
. /etc/oxidized/telegram.env

L() { if [[ "${MSG_LANG}" == "es" ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# Solo envía un resumen: el diff puede contener secretos (hashes, comunidades SNMP,
# claves de VPN...) y no debe salir hacia Telegram. El detalle está en la web/git.
send() {
  # La URL (con el token) va por stdin para que no aparezca en la lista de procesos
  curl -fsS -m 20 -K - \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" \
    -d "disable_web_page_preview=true" >/dev/null \
    <<<"url = \"https://api.telegram.org/bot${TG_TOKEN}/sendMessage\""
}

if [[ "${1:-}" == "--test" ]]; then
  send "✅ $(L "Oxidized en $(hostname): notificaciones de Telegram configuradas correctamente." "Oxidized on $(hostname): Telegram notifications are set up correctly.")"
  exit $?
fi

added='?' removed='?'
if [[ -n "${OX_REPO_NAME:-}" && -n "${OX_REPO_COMMITREF:-}" ]]; then
  read -r added removed < <(git --git-dir="${OX_REPO_NAME}" show --numstat --format= "${OX_REPO_COMMITREF}" 2>/dev/null |
    awk '{a += $1; r += $2} END {print a + 0, r + 0}')
fi

send "🔄 $(L "Cambio de configuración detectado" "Configuration change detected")
$(L "Equipo" "Device"): ${OX_NODE_NAME:-?}
IP: ${OX_NODE_IP:-?}
$(L "Modelo" "Model"): ${OX_NODE_MODEL:-?}
$(L "Líneas" "Lines"): +${added} / -${removed}
Commit: ${OX_REPO_COMMITREF:0:10}"
EOF
  } >/usr/local/bin/oxidized-telegram-notify
  chmod 0755 /usr/local/bin/oxidized-telegram-notify
  msg_ok "$(L "Hook de Telegram instalado" "Telegram hook installed")"

  msg_info "$(L "Enviando mensaje de prueba a Telegram" "Sending a test message to Telegram")"
  if /usr/local/bin/oxidized-telegram-notify --test >>"${INSTALL_LOG}" 2>&1; then
    msg_ok "$(L "Mensaje de prueba enviado a Telegram" "Test message sent to Telegram")"
  else
    msg_warn "$(L "No se pudo enviar el mensaje de prueba: revisa token/chat ID en ${OXI_HOME}/telegram.env" "Could not send the test message: check the token/chat ID in ${OXI_HOME}/telegram.env")"
  fi
}

install_helpers() {
  msg_info "$(L "Instalando oxidized-reload" "Installing oxidized-reload")"
  {
    echo '#!/usr/bin/env bash'
    echo "# Validates router.db, records SSH fingerprints of new devices and makes Oxidized"
    echo "# reload the inventory (or starts it if it was stopped)."
    echo "# Valida router.db, registra las huellas SSH de los equipos nuevos y hace que"
    echo "# Oxidized relea el inventario (o lo arranca si estaba parado)."
    echo "#"
    echo "#   oxidized-reload                  validate, record new fingerprints, reload"
    echo "#   oxidized-reload --trust IP [P]   re-record a fingerprint (replaced device)"
    echo "#   oxidized-reload --forget IP [P]  remove a recorded fingerprint"
    echo "MSG_LANG=\"${UI_LANG}\""
    echo "DB=\"${OXI_HOME}/router.db\""
    echo "KH=\"${OXI_DATA}/.ssh/known_hosts\""
    echo "OXI_USER=\"${OXI_USER}\""
    echo "API=\"http://127.0.0.1:${OXI_PORT}\""
    cat <<'EOF'
set -uo pipefail

L() { if [[ "${MSG_LANG}" == "es" ]]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }

# Entrada de known_hosts tal como la busca Net::SSH: "ip" o "[ip]:puerto"
kh_name() { if [[ "${2:-22}" == "22" ]]; then echo "$1"; else echo "[$1]:$2"; fi; }

forget() {
  ssh-keygen -R "$(kh_name "$1" "${2:-22}")" -f "${KH}" >/dev/null 2>&1
  rm -f "${KH}.old"
}

# Registra la huella de un equipo si no está ya (se confía en el primer uso)
trust() {
  local host=$1 port=${2:-22} label=${3:-$1} keys
  ssh-keygen -F "$(kh_name "${host}" "${port}")" -f "${KH}" >/dev/null 2>&1 && return 0
  if keys=$(ssh-keyscan -p "${port}" -T 5 "${host}" 2>/dev/null) && [[ -n "${keys}" ]]; then
    echo "${keys}" >>"${KH}"
    echo "$(L "Huella SSH registrada para" "SSH fingerprint recorded for") ${label} (${host}):"
    ssh-keygen -lf - <<<"${keys}" | sed 's/^/    /'
  else
    L "AVISO: no se pudo obtener la huella SSH de ${label} (${host}:${port}); su copia fallará hasta registrarla." "WARNING: could not get the SSH fingerprint of ${label} (${host}:${port}); its backup will fail until it is recorded." >&2
  fi
}

finish_kh() { chown "${OXI_USER}:${OXI_USER}" "${KH}"; chmod 0644 "${KH}"; }

case "${1:-}" in
--trust)
  [[ -n "${2:-}" ]] || { echo "$(L "Uso" "Usage"): oxidized-reload --trust IP [$(L "PUERTO" "PORT")]" >&2; exit 1; }
  forget "$2" "${3:-22}"
  trust "$2" "${3:-22}"
  finish_kh
  exit 0
  ;;
--forget)
  [[ -n "${2:-}" ]] || { echo "$(L "Uso" "Usage"): oxidized-reload --forget IP [$(L "PUERTO" "PORT")]" >&2; exit 1; }
  forget "$2" "${3:-22}"
  finish_kh
  L "Huella de $2 eliminada." "Fingerprint of $2 removed."
  exit 0
  ;;
"") ;;
*)
  echo "$(L "Opción desconocida" "Unknown option"): $1" >&2
  exit 1
  ;;
esac

errors=0 n=0 nodes=0 targets=()
while IFS= read -r line || [[ -n "${line}" ]]; do
  n=$((n + 1))
  [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
  nodes=$((nodes + 1))
  fields=$(awk -F';' '{print NF}' <<<"${line}")
  if [[ "${fields}" -ne 6 ]]; then
    L "router.db línea ${n}: se esperaban 6 campos y hay ${fields}" "router.db line ${n}: expected 6 fields, found ${fields}" >&2
    errors=$((errors + 1))
    continue
  fi
  IFS=';' read -r name ip _ <<<"${line}"
  targets+=("${name};${ip:-${name}}")
done <"${DB}"
if [[ ${errors} -gt 0 ]]; then
  L "Corrige los errores anteriores; no se ha recargado nada." "Fix the errors above; nothing was reloaded." >&2
  exit 1
fi
if [[ ${nodes} -eq 0 ]]; then
  L "router.db no tiene equipos: Oxidized no arranca hasta que añadas al menos uno." "router.db has no devices: Oxidized will not start until you add at least one." >&2
  exit 1
fi

# Oxidized conecta a la IP resuelta, así que la huella se guarda por IP.
# Los equipos con ssh_port distinto de 22 se registran con: oxidized-reload --trust IP PUERTO
for t in "${targets[@]}"; do
  name=${t%%;*} host=${t#*;}
  if ! [[ "${host}" =~ ^[0-9.]+$ || "${host}" == *:* ]]; then
    host=$(getent ahosts "${host}" | awk 'NR==1 {print $1}')
    [[ -n "${host}" ]] || { L "AVISO: no se resuelve ${name}; no se registra su huella." "WARNING: cannot resolve ${name}; its fingerprint is not recorded." >&2; continue; }
  fi
  trust "${host}" 22 "${name}"
done
finish_kh

wait_api() {
  for _ in $(seq 1 30); do
    curl -fsS -m 3 "${API}/nodes?format=json" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

if ! systemctl is-active --quiet oxidized; then
  L "Oxidized estaba parado; arrancándolo con ${nodes} equipo(s)..." "Oxidized was stopped; starting it with ${nodes} device(s)..."
  systemctl restart oxidized
  if wait_api; then
    L "Oxidized en marcha." "Oxidized is running."
  else
    echo "$(L "Oxidized no arranca; revisa" "Oxidized does not start; check"): journalctl -u oxidized -n 30" >&2
    exit 1
  fi
elif out=$(curl -fsS -m 10 "${API}/reload?format=json" 2>&1); then
  echo "$(L "Inventario recargado (${nodes} equipo(s))" "Inventory reloaded (${nodes} device(s))"): ${out}"
else
  L "La API no responde; enviando SIGHUP para recargar sin reiniciar..." "The API does not respond; sending SIGHUP to reload without restarting..."
  systemctl kill -s HUP oxidized
fi
EOF
  } >/usr/local/bin/oxidized-reload
  chmod 0755 /usr/local/bin/oxidized-reload
  msg_ok "$(L "Instalado oxidized-reload" "Installed oxidized-reload")"
}

setup_service() {
  msg_info "$(L "Creando servicio systemd" "Creating systemd service")"
  cat >/etc/systemd/system/oxidized.service <<EOF
[Unit]
Description=Oxidized - Network Device Configuration Backup Tool
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OXI_USER}
Group=${OXI_USER}
Environment=OXIDIZED_HOME=${OXI_HOME}
# Without a UTF-8 locale Ruby reads router.db and configs as US-ASCII and crashes on accents
Environment=LANG=C.UTF-8 LC_ALL=C.UTF-8
# Oxidized refuses to start with an empty inventory: without devices systemd skips it
# (inactive, no restart loop). oxidized-reload starts it afterwards.
ExecCondition=/usr/bin/grep -qvE "^[[:space:]]*(#|$$)" ${OXI_HOME}/router.db
ExecStart=${OXI_BIN}
RuntimeDirectory=oxidized
# Only protections that work in an unprivileged LXC (namespace-based ones such as
# ProtectSystem prevent the service from starting)
NoNewPrivileges=yes
UMask=0027
# SIGTERM (default) instead of SIGKILL: does not interrupt a write to the git repo
TimeoutStopSec=30
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  $STD systemctl enable --now oxidized
  if has_nodes; then
    msg_ok "$(L "Servicio oxidized creado y arrancado" "oxidized service created and started")"
  else
    msg_ok "$(L "Servicio oxidized creado (arrancará al añadir equipos)" "oxidized service created (it will start once devices are added)")"
  fi
}

# Comillas para valores en un fichero de configuración de curl (-K)
curl_quote() {
  local v=${1//\\/\\\\}
  printf '"%s"' "${v//\"/\\\"}"
}

setup_nginx() {
  [[ "${OXI_WEB_MODE}" == "nginx" ]] || return 0
  msg_info "$(L "Configurando nginx con HTTPS y autenticación básica" "Configuring nginx with HTTPS and basic authentication")"
  local ssl_dir=/etc/nginx/ssl ip san
  # Hash SHA-512 (crypt $6$); la contraseña entra por stdin, no por argumentos
  printf '%s:%s\n' "${OXI_WEB_USER}" "$(openssl passwd -6 -stdin <<<"${OXI_WEB_PASS}")" >/etc/nginx/oxidized.htpasswd
  chown root:www-data /etc/nginx/oxidized.htpasswd
  chmod 0640 /etc/nginx/oxidized.htpasswd

  install -d -m 0700 "${ssl_dir}"
  if [[ ! -f "${ssl_dir}/oxidized.crt" ]]; then
    ip=$(container_ip)
    san="DNS:$(hostname)"
    [[ "$(hostname -f 2>/dev/null)" != "$(hostname)" ]] && san+=",DNS:$(hostname -f)"
    [[ -n "${ip}" ]] && san+=",IP:${ip}"
    $STD openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 825 \
      -subj "/CN=$(hostname -f 2>/dev/null || hostname)" -addext "subjectAltName=${san}" \
      -keyout "${ssl_dir}/oxidized.key" -out "${ssl_dir}/oxidized.crt"
    chmod 0600 "${ssl_dir}/oxidized.key"
  fi

  cat >/etc/nginx/sites-available/oxidized <<EOF
# All HTTP traffic is redirected to HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    server_tokens off;

    # Self-signed certificate; replace it with your own if you have one
    ssl_certificate     ${ssl_dir}/oxidized.crt;
    ssl_certificate_key ${ssl_dir}/oxidized.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:oxidized:1m;
    ssl_session_timeout 1d;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;

    auth_basic "Oxidized";
    auth_basic_user_file /etc/nginx/oxidized.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:${OXI_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/oxidized /etc/nginx/sites-enabled/oxidized
  $STD nginx -t
  $STD systemctl enable nginx
  $STD systemctl reload-or-restart nginx
  msg_ok "$(L "nginx configurado con HTTPS (443) y redirección desde el 80" "nginx configured with HTTPS (443) and redirect from port 80")"
}

verify_install() {
  if ! has_nodes; then
    msg_info "$(L "Verificando la configuración" "Checking the configuration")"
    if runuser -u "${OXI_USER}" -- env OXIDIZED_HOME="${OXI_HOME}" LANG=C.UTF-8 \
      ruby -ryaml -e 'YAML.unsafe_load_file(ARGV[0])' "${OXI_HOME}/config" >>"${INSTALL_LOG}" 2>&1; then
      msg_ok "$(L "Configuración válida; Oxidized arrancará al añadir equipos" "Configuration is valid; Oxidized will start once devices are added")"
    else
      msg_error "$(L "El fichero ${OXI_HOME}/config no es YAML válido (ver ${INSTALL_LOG})" "${OXI_HOME}/config is not valid YAML (see ${INSTALL_LOG})")"
      exit 1
    fi
    return 0
  fi
  msg_info "$(L "Verificando la instalación (hasta 60 s)" "Checking the installation (up to 60 s)")"
  local i ok=0
  for i in $(seq 1 30); do
    if curl -fsS -m 3 "http://127.0.0.1:${OXI_PORT}/nodes?format=json" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  # is-active no basta: en un bucle de reinicios aparece "activo" a ratos
  if [[ ${ok} -ne 1 ]]; then
    msg_error "$(L "Oxidized no responde (reinicios: $(systemctl show -p NRestarts --value oxidized)). Últimas líneas del log:" "Oxidized does not respond (restarts: $(systemctl show -p NRestarts --value oxidized)). Last log lines:")"
    journalctl -u oxidized -n 20 --no-pager >&2 || true
    exit 1
  fi
  msg_ok "$(L "Servicio activo y API respondiendo" "Service running and API responding")"
  if [[ "${OXI_WEB_MODE}" == "nginx" ]]; then
    if curl -fsS -m 5 -k -K - "https://127.0.0.1/nodes?format=json" >/dev/null 2>&1 \
      <<<"user = $(curl_quote "${OXI_WEB_USER}:${OXI_WEB_PASS}")"; then
      msg_ok "$(L "nginx responde por HTTPS con autenticación" "nginx responds over HTTPS with authentication")"
    else
      msg_warn "$(L "nginx no responde correctamente" "nginx does not respond correctly") (journalctl -u nginx)"
    fi
  fi
}

print_summary() {
  local ip url
  ip=$(container_ip)
  case "${OXI_WEB_MODE}" in
  direct) url="http://${ip}:${OXI_PORT}" ;;
  nginx) url="https://${ip}  ($(L "usuario: ${OXI_WEB_USER}, certificado autofirmado" "user: ${OXI_WEB_USER}, self-signed certificate"))" ;;
  none) url="$(L "desactivada (API solo en 127.0.0.1:${OXI_PORT})" "disabled (API on 127.0.0.1:${OXI_PORT} only)")" ;;
  esac
  echo
  echo -e "${CM}${GN}${BOLD}${APP} $(oxidized_version) $(L "instalado correctamente" "installed successfully")${CL}"
  echo -e "${INFO}${YW}Web:                 ${BL}${url}${CL}"
  echo -e "${INFO}${YW}$(L "Inventario:         " "Inventory:          ") ${BL}${OXI_HOME}/router.db${CL}"
  echo -e "${INFO}${YW}$(L "Configuración:      " "Configuration:      ") ${BL}${OXI_HOME}/config${CL}"
  echo -e "${INFO}${YW}$(L "Repositorio:        " "Repository:         ") ${BL}${OXI_REPO}${CL}"
  [[ "${OXI_GIT_MODE}" == "remote" ]] && echo -e "${INFO}${YW}$(L "Remoto:             " "Remote:             ") ${BL}${OXI_GIT_REMOTE}${CL}"
  [[ "${OXI_TELEGRAM}" == "yes" ]] && echo -e "${INFO}${YW}Telegram:            ${BL}${OXI_HOME}/telegram.env${CL}"
  [[ "${OXI_WEB_MODE}" == "nginx" ]] && echo -e "${INFO}${YW}$(L "Certificado:        " "Certificate:        ") ${BL}/etc/nginx/ssl/oxidized.crt${CL}"
  [[ "${OXI_WEB_MODE}" == "direct" ]] && echo -e "${WARN}${YWB}$(L "La web no tiene autenticación ni cifrado: limita el acceso al puerto ${OXI_PORT}" "The web UI has no authentication or encryption: restrict access to port ${OXI_PORT}")${CL}"
  echo
  has_nodes || echo -e "${INFO}${YWB}$(L "Oxidized no arranca con el inventario vacío: añade al menos un equipo y ejecuta oxidized-reload" "Oxidized does not start with an empty inventory: add at least one device and run oxidized-reload")${CL}\n"
  echo -e "${TAB}${BOLD}$(L "Siguientes pasos:" "Next steps:")${CL}"
  echo -e "${TAB}1. $(L "Añade tus equipos:   " "Add your devices:    ") ${DGN}nano ${OXI_HOME}/router.db${CL}"
  echo -e "${TAB}2. $(L "Arranca/recarga:     " "Start/reload:        ") ${DGN}oxidized-reload${CL}  ($(L "registra también las huellas SSH" "also records SSH fingerprints"))"
  echo -e "${TAB}3. $(L "Ver logs:            " "View logs:           ") ${DGN}journalctl -u oxidized -f${CL}"
  echo -e "${TAB}4. $(L "Actualizar/backup:   " "Update/backup:       ") ${DGN}$(L "vuelve a ejecutar este script" "run this script again")${CL}"
  echo
}

# ---------------------------------------------------------------------------
# Mantenimiento: actualizar, copia de seguridad, desinstalar
# ---------------------------------------------------------------------------
do_backup() {
  local file
  file="/root/oxidized-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  msg_info "$(L "Creando copia de seguridad" "Creating backup")"
  local paths=()
  for p in "${OXI_HOME}" "${OXI_DATA}" /etc/systemd/system/oxidized.service \
    /usr/local/bin/oxidized-reload /usr/local/bin/oxidized-telegram-notify \
    /etc/nginx/sites-available/oxidized /etc/nginx/oxidized.htpasswd /etc/nginx/ssl; do
    if [[ -e "${p}" ]]; then paths+=("${p#/}"); fi
  done
  tar -czf "${file}" -C / "${paths[@]}"
  chmod 0600 "${file}"
  msg_ok "$(L "Copia guardada en" "Backup saved to") ${BL}${file}${CL}"
}

do_update() {
  local before after
  before=$(oxidized_version)
  do_backup
  msg_info "$(L "Actualizando paquetes del sistema" "Updating system packages")"
  export DEBIAN_FRONTEND=noninteractive
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "$(L "Paquetes del sistema actualizados" "System packages updated")"
  msg_info "$(L "Actualizando Oxidized" "Updating Oxidized") ${before}"
  $STD gem update --no-document oxidized oxidized-web
  $STD gem cleanup oxidized oxidized-web
  after=$(oxidized_version)
  msg_ok "Oxidized ${before} → ${after}"
  msg_info "$(L "Reiniciando el servicio" "Restarting the service")"
  systemctl restart oxidized
  sleep 5
  if systemctl is-active --quiet oxidized; then
    msg_ok "$(L "Servicio oxidized activo" "oxidized service running")"
  else
    msg_error "$(L "El servicio no arranca tras la actualización" "The service does not start after the update") (journalctl -u oxidized)"
    exit 1
  fi
}

do_uninstall() {
  ask_yesno "$(L "Desinstalar" "Uninstall")" "$(L "Se eliminará Oxidized, su servicio y su configuración.\n\n¿Continuar?" "Oxidized, its service and its configuration will be removed.\n\nContinue?")" || exit_script
  if ask_yesno "$(L "Desinstalar" "Uninstall")" "$(L "¿Hacer antes una copia de seguridad completa en /root?" "Make a full backup in /root first?")"; then
    do_backup
  fi
  local keep_repo=no
  if [[ -d "${OXI_REPO}" ]] && ask_yesno "$(L "Desinstalar" "Uninstall")" "$(L "¿Conservar el repositorio git con el histórico de configuraciones?\n(se moverá a /root/oxidized-configs.git)" "Keep the git repository with the configuration history?\n(it will be moved to /root/oxidized-configs.git)")"; then
    keep_repo=yes
  fi

  msg_info "$(L "Desinstalando Oxidized" "Uninstalling Oxidized")"
  systemctl disable --now oxidized >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/oxidized.service
  systemctl daemon-reload
  if [[ -f /etc/nginx/sites-available/oxidized ]]; then
    rm -f /etc/nginx/sites-enabled/oxidized /etc/nginx/sites-available/oxidized /etc/nginx/oxidized.htpasswd
    rm -f /etc/nginx/ssl/oxidized.crt /etc/nginx/ssl/oxidized.key
    systemctl reload nginx >/dev/null 2>&1 || true
  fi
  if [[ "${keep_repo}" == "yes" ]]; then
    rm -rf /root/oxidized-configs.git
    mv "${OXI_REPO}" /root/oxidized-configs.git
    chown -R root:root /root/oxidized-configs.git
  fi
  $STD gem uninstall -a -x -I oxidized-web oxidized || true
  rm -f /usr/local/bin/oxidized-reload /usr/local/bin/oxidized-telegram-notify
  rm -rf "${OXI_HOME}" "${OXI_DATA}"
  userdel "${OXI_USER}" >/dev/null 2>&1 || true
  msg_ok "$(L "Oxidized desinstalado" "Oxidized uninstalled")"
  [[ "${keep_repo}" == "yes" ]] && echo -e "${INFO}${YW}$(L "Repositorio conservado en" "Repository kept in") ${BL}/root/oxidized-configs.git${CL}"
  echo -e "${INFO}${YW}$(L "Las dependencias (ruby, nginx...) se mantienen instaladas" "Dependencies (ruby, nginx...) are left installed")${CL}"
}

maintenance_menu() {
  local action="${OXI_ACTION:-}"
  if [[ -z "${action}" ]]; then
    action=$(whiptail --backtitle "${BACKTITLE}" --title "${APP} $(L "ya instalado" "already installed") ($(oxidized_version))" \
      --menu "$(L "¿Qué quieres hacer?" "What do you want to do?")" 15 78 4 \
      "update" "$(L "Actualizar (hace antes una copia de seguridad)" "Update (makes a backup first)")" \
      "backup" "$(L "Copia de seguridad en /root" "Backup to /root")" \
      "uninstall" "$(L "Desinstalar" "Uninstall")" \
      "exit" "$(L "Salir" "Exit")" 3>&1 1>&2 2>&3) || exit_script
  fi
  case "${action}" in
  update) do_update ;;
  backup) do_backup ;;
  uninstall) do_uninstall ;;
  *) exit_script ;;
  esac
}

# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
main() {
  check_root
  install -m 0600 /dev/null "${INSTALL_LOG}"

  if ! command -v whiptail >/dev/null 2>&1; then
    msg_info "Installing whiptail / Instalando whiptail"
    $STD apt-get update
    $STD apt-get install -y whiptail
    msg_ok "whiptail"
  fi

  choose_language
  header_info
  check_os

  if is_installed; then
    maintenance_menu
    exit 0
  fi

  check_container
  check_network
  gather_options
  header_info
  echo -e "${INFO}${YW}$(L "Log detallado de la instalación" "Detailed installation log"): ${BL}${INSTALL_LOG}${CL}\n"

  install_dependencies
  install_oxidized
  create_user_dirs
  setup_git_remote
  write_config
  setup_telegram
  install_helpers
  setup_service
  setup_nginx
  verify_install
  print_summary
}

main "$@"
