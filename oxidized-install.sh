#!/usr/bin/env bash

# Copyright (c) 2026 Psycomy
# License: MIT
# Repo:   https://github.com/Psycomy/oxidized-proxmox-lxc
# Source: https://github.com/ytti/oxidized
#
# Instala Oxidized dentro de un LXC (Debian 13, Ubuntu 24.04, Ubuntu 26.04)
# con el estilo de community-scripts/ProxmoxVE.
#
# Uso (apunta a una etiqueta o commit concreto de tu repo, no a la rama principal,
# para que nadie pueda cambiar lo que ejecutas como root sin que lo sepas):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Psycomy/oxidized-proxmox-lxc/v1.0.0/oxidized-install.sh)"
#
# Instalación desatendida (cualquier variable definida se salta su pregunta):
#   OXI_WEB_MODE=none|direct|nginx   OXI_WEB_USER  OXI_WEB_PASS
#   OXI_GIT_MODE=local|remote        OXI_GIT_REMOTE (ej. git@gitea.local:red/configs.git)
#   OXI_TELEGRAM=yes|no              OXI_TG_TOKEN  OXI_TG_CHAT
#   OXI_INTERVAL=3600                VERBOSE=yes
#   OXI_VERSION / OXI_WEB_VERSION    fija la versión de las gemas (por defecto, la última)

set -Eeuo pipefail

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
SUPPORTED_OS="Debian 13, Ubuntu 24.04, Ubuntu 26.04"

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
  echo -e "\n${CROSS}${RD}Error en la línea ${line} (código ${exit_code}): ${YW}${cmd}${CL}" >&2
  echo -e "${INFO}${YW}Revisa el log: ${BL}${INSTALL_LOG}${CL}" >&2
  exit "${exit_code}"
}
trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR
trap 'stop_spinner' EXIT
trap 'stop_spinner; echo; msg_error "Cancelado por el usuario"; exit 130' INT TERM

exit_script() {
  stop_spinner
  echo -e "\n${CROSS}${YW}Instalación cancelada${CL}\n"
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
    whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "El valor no puede estar vacío." 8 50
  done
  printf -v "${var}" '%s' "${value}"
}

ask_password() { # ask_password <var> <título> <texto>
  local var=$1 title=$2 text=$3 p1 p2
  [[ -n "${!var:-}" ]] && return 0
  while true; do
    p1=$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --passwordbox "${text}" 10 72 3>&1 1>&2 2>&3) || exit_script
    p2=$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --passwordbox "Repite la contraseña:" 10 72 3>&1 1>&2 2>&3) || exit_script
    if [[ -z "${p1}" ]]; then
      whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "La contraseña no puede estar vacía." 8 50
    elif [[ "${p1}" != "${p2}" ]]; then
      whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "Las contraseñas no coinciden." 8 50
    else
      break
    fi
  done
  printf -v "${var}" '%s' "${p1}"
}

ask_yesno() { # ask_yesno <título> <texto>  -> 0 = sí
  whiptail --backtitle "${BACKTITLE}" --title "$1" --yesno "$2" 12 72
}

# ---------------------------------------------------------------------------
# Comprobaciones previas
# ---------------------------------------------------------------------------
check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    msg_error "Este script debe ejecutarse como root"
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
    msg_ok "Sistema soportado: ${BL}${PRETTY_NAME}${CL}"
    ;;
  *)
    msg_error "Sistema no soportado: ${PRETTY_NAME:-desconocido}"
    echo -e "${INFO}${YW}Soportados: ${SUPPORTED_OS}${CL}"
    exit 1
    ;;
  esac
}

check_container() {
  local virt
  virt=$(systemd-detect-virt --container 2>/dev/null || true)
  if [[ "${virt}" != "lxc" ]]; then
    msg_warn "No parece un LXC (detectado: ${virt:-none}); se continúa igualmente"
    return
  fi
  if awk 'NR==1 && !($1==0 && $2==0) {exit 0} {exit 1}' /proc/self/uid_map; then
    msg_ok "LXC no privilegiado detectado (Oxidized funciona sin problemas)"
  else
    msg_ok "LXC privilegiado detectado"
  fi
  # Ningún requisito de Oxidized necesita privilegios; solo avisamos de lo que puede fallar
  local state
  state=$(systemctl is-system-running 2>/dev/null || true)
  if [[ "${state}" == "offline" || -z "${state}" ]]; then
    msg_warn "systemd no está operativo en el contenedor; el servicio no podrá arrancar"
  fi
}

check_network() {
  msg_info "Comprobando conectividad (DNS y rubygems.org)"
  if ! getent hosts rubygems.org >/dev/null 2>&1; then
    msg_error "No se resuelve rubygems.org: revisa el DNS del contenedor"
    exit 1
  fi
  if ! timeout 15 bash -c 'exec 3<>/dev/tcp/rubygems.org/443' 2>/dev/null; then
    msg_error "Sin acceso a rubygems.org:443: revisa la salida a Internet / proxy"
    exit 1
  fi
  msg_ok "Conectividad correcta"
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
    ask_menu OXI_WEB_MODE "Interfaz web" "¿Cómo quieres exponer oxidized-web?" \
      "nginx" "HTTPS (nginx, puerto 443) con usuario/contraseña" \
      "none" "Sin web (API solo en 127.0.0.1, usada por oxidized-reload)" \
      "direct" "HTTP directo en el puerto ${OXI_PORT}, SIN autenticación"
    [[ "${OXI_WEB_MODE}" != "direct" || -n "${web_preset}" ]] && break
    if ask_yesno "⚠️  Web sin autenticación" "Cualquiera que llegue al puerto ${OXI_PORT} podrá:\n\n - Leer y buscar en TODAS las configuraciones guardadas\n   (hashes de contraseñas, comunidades SNMP, claves de VPN...)\n - Lanzar copias y recargar el inventario\n\nTodo viaja sin cifrar. ¿Seguro que quieres este modo?"; then
      break
    fi
    OXI_WEB_MODE=""
  done
  case "${OXI_WEB_MODE}" in none | direct | nginx) ;; *)
    msg_error "OXI_WEB_MODE inválido: ${OXI_WEB_MODE}"
    exit 1
    ;;
  esac
  if [[ "${OXI_WEB_MODE}" == "nginx" ]]; then
    ask_input OXI_WEB_USER "Autenticación web" "Usuario para acceder a la web:" "admin"
    ask_password OXI_WEB_PASS "Autenticación web" "Contraseña para el usuario ${OXI_WEB_USER}:"
  fi

  ask_menu OXI_GIT_MODE "Almacenamiento" "¿Dónde guardar las configuraciones?" \
    "local" "Repositorio git local en ${OXI_REPO}" \
    "remote" "Git local + push automático a un remoto (Gitea, GitHub...)"
  case "${OXI_GIT_MODE}" in local | remote) ;; *)
    msg_error "OXI_GIT_MODE inválido: ${OXI_GIT_MODE}"
    exit 1
    ;;
  esac
  if [[ "${OXI_GIT_MODE}" == "remote" ]]; then
    ask_input OXI_GIT_REMOTE "Repositorio remoto" \
      "URL SSH del repositorio remoto (debe existir y estar vacío):\nej. git@gitea.local:red/oxidized-configs.git" ""
  fi

  if [[ -z "${OXI_TELEGRAM:-}" ]]; then
    if ask_yesno "Notificaciones" "¿Quieres recibir un aviso por Telegram cada vez que cambie la configuración de un equipo?"; then
      OXI_TELEGRAM="yes"
    else
      OXI_TELEGRAM="no"
    fi
  fi
  if [[ "${OXI_TELEGRAM}" == "yes" ]]; then
    ask_password OXI_TG_TOKEN "Telegram" "Token del bot (de @BotFather):"
    ask_input OXI_TG_CHAT "Telegram" "Chat ID destino (usuario, grupo o canal):" ""
  fi

  ask_input OXI_INTERVAL "Intervalo" "Segundos entre copias de cada equipo:" "3600"
  if ! [[ "${OXI_INTERVAL}" =~ ^[0-9]+$ ]]; then
    msg_error "OXI_INTERVAL debe ser un número de segundos"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Instalación
# ---------------------------------------------------------------------------
install_dependencies() {
  msg_info "Actualizando el sistema"
  export DEBIAN_FRONTEND=noninteractive
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Sistema actualizado"

  if [[ "${OS_ID}" == "ubuntu" ]] && ! apt-cache policy libssh2-1-dev 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    msg_info "Habilitando el repositorio universe"
    $STD apt-get install -y software-properties-common
    $STD add-apt-repository -y universe
    $STD apt-get update
    msg_ok "Repositorio universe habilitado"
  fi

  msg_info "Instalando dependencias"
  local pkgs=(
    ruby ruby-dev libsqlite3-dev libssl-dev pkg-config cmake make g++
    libssh2-1-dev libicu-dev zlib1g-dev libyaml-dev libzstd-dev
    git curl ca-certificates openssh-client openssl
  )
  [[ "${OXI_WEB_MODE}" == "nginx" ]] && pkgs+=(nginx)
  $STD apt-get install -y --no-install-recommends "${pkgs[@]}"
  msg_ok "Dependencias instaladas"

  local ruby_ver
  ruby_ver=$(ruby -e 'print RUBY_VERSION')
  if ! ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1") ? 0 : 1)'; then
    msg_error "Ruby ${ruby_ver} es demasiado antiguo (Oxidized necesita >= 3.1)"
    exit 1
  fi
  msg_ok "Ruby ${ruby_ver}"
}

install_oxidized() {
  msg_info "Instalando Oxidized y oxidized-web (compila extensiones, tarda unos minutos)"
  local gems=(oxidized)
  [[ -n "${OXI_VERSION:-}" ]] && gems+=(-v "${OXI_VERSION}")
  $STD gem install --no-document "${gems[@]}"
  gems=(oxidized-web)
  [[ -n "${OXI_WEB_VERSION:-}" ]] && gems+=(-v "${OXI_WEB_VERSION}")
  $STD gem install --no-document "${gems[@]}"
  OXI_BIN=$(command -v oxidized || true)
  if [[ -z "${OXI_BIN}" ]]; then
    msg_error "No se encuentra el binario de oxidized tras instalar la gema"
    exit 1
  fi
  msg_ok "Instalado Oxidized $(oxidized_version) (${OXI_BIN})"

  if [[ "${OXI_GIT_MODE}" == "remote" ]] && ! ruby -e 'require "rugged"; exit(Rugged.features.include?(:ssh) ? 0 : 1)' 2>/dev/null; then
    msg_error "rugged se compiló sin soporte SSH: el push al remoto no funcionará"
    exit 1
  fi
}

create_user_dirs() {
  msg_info "Creando usuario y directorios"
  if ! id "${OXI_USER}" >/dev/null 2>&1; then
    useradd --system --home-dir "${OXI_DATA}" --create-home --shell /usr/sbin/nologin "${OXI_USER}"
  fi
  install -d -m 0750 -o "${OXI_USER}" -g "${OXI_USER}" "${OXI_HOME}" "${OXI_DATA}" "${OXI_DATA}/crashes"
  # Huellas SSH de los equipos (input.ssh.secure) y del remoto git
  install -d -m 0700 -o "${OXI_USER}" -g "${OXI_USER}" "${OXI_DATA}/.ssh"
  [[ -f "${OXI_DATA}/.ssh/known_hosts" ]] || install -m 0644 -o "${OXI_USER}" -g "${OXI_USER}" /dev/null "${OXI_DATA}/.ssh/known_hosts"
  msg_ok "Usuario ${OXI_USER} y directorios creados"
}

setup_git_remote() {
  [[ "${OXI_GIT_MODE}" == "remote" ]] || return 0
  msg_info "Generando clave SSH para el push al remoto"
  local sshdir="${OXI_DATA}/.ssh" host port keys
  if [[ ! -f "${sshdir}/id_rsa" ]]; then
    # El hook githubrepo (rugged/libssh2) exige el formato PEM clásico
    $STD sudo_oxi ssh-keygen -q -t rsa -b 4096 -m PEM -N "" -C "oxidized@$(hostname)" -f "${sshdir}/id_rsa"
  fi
  # Extrae host y puerto de git@host:ruta o ssh://user@host:puerto/ruta
  if [[ "${OXI_GIT_REMOTE}" =~ ^https?:// ]]; then
    msg_error "El push necesita una URL SSH, no HTTP(S): ${OXI_GIT_REMOTE}"
    exit 1
  elif [[ "${OXI_GIT_REMOTE}" =~ ^ssh://([^@/]+@)?([^:/]+)(:([0-9]+))?/ ]]; then
    host="${BASH_REMATCH[2]}"
    port="${BASH_REMATCH[4]:-22}"
  elif [[ "${OXI_GIT_REMOTE}" =~ ^([^@]+@)?([^:]+): ]]; then
    host="${BASH_REMATCH[2]}"
    port=22
  else
    msg_error "URL de remoto no reconocida: ${OXI_GIT_REMOTE} (usa formato SSH)"
    exit 1
  fi
  # Se confía en la huella obtenida ahora (primer uso); compruébala si puedes
  if keys=$(ssh-keyscan -p "${port}" -T 10 "${host}" 2>/dev/null) && [[ -n "${keys}" ]]; then
    echo "${keys}" >>"${sshdir}/known_hosts"
    chown "${OXI_USER}:${OXI_USER}" "${sshdir}/known_hosts"
    msg_ok "Clave SSH generada y huella de ${host} registrada"
  else
    msg_warn "No se pudo obtener la huella SSH de ${host}:${port}; revisa la URL/red"
  fi

  if [[ -t 0 ]]; then
    whiptail --backtitle "${BACKTITLE}" --title "Clave de despliegue" --scrolltext --msgbox \
      "Añade esta clave pública como Deploy Key CON PERMISO DE ESCRITURA en el repositorio remoto y pulsa Aceptar:\n\n$(cat "${sshdir}/id_rsa.pub")" 20 78
  fi
  echo -e "${INFO}${YW}Clave pública (deploy key con escritura):${CL}"
  echo -e "${TAB}${DGN}$(cat "${sshdir}/id_rsa.pub")${CL}"
}

sudo_oxi() {
  runuser -u "${OXI_USER}" -- "$@"
}

write_config() {
  msg_info "Escribiendo configuración"
  local listen="127.0.0.1"
  [[ "${OXI_WEB_MODE}" == "direct" ]] && listen="0.0.0.0"

  cat >"${OXI_HOME}/config" <<EOF
---
# Configuración de Oxidized generada por oxidized-install.sh
# Documentación: https://github.com/ytti/oxidized/blob/master/docs/Configuration.md
# Tras editar este fichero: systemctl restart oxidized
# Credenciales por defecto (cada equipo las sobrescribe en router.db)
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
    # La web muestra las vars de cada equipo: sin esto el enable se ve en claro
    hide_node_vars:
      - enable
input:
  # Solo SSH: con "ssh, telnet", si SSH falla Oxidized reintenta por Telnet y
  # envía las credenciales en claro. Para un modelo que solo tenga Telnet:
  #   models: { <modelo>: { input: telnet } }
  default: ssh
  debug: false
  ssh:
    # Verifica la huella SSH de cada equipo contra ${OXI_DATA}/.ssh/known_hosts.
    # oxidized-reload registra automáticamente la de los equipos nuevos.
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
    # Se usa ';' para admitir IPv6 y ':' dentro de las contraseñas
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
  fi

  chown -R "${OXI_USER}:${OXI_USER}" "${OXI_HOME}"
  chmod 0640 "${OXI_HOME}/config"
  chmod 0600 "${OXI_HOME}/router.db"
  msg_ok "Configuración escrita en ${OXI_HOME}"
}

setup_telegram() {
  [[ "${OXI_TELEGRAM}" == "yes" ]] || return 0
  msg_info "Configurando notificaciones de Telegram"
  (
    umask 027
    printf 'TG_TOKEN=%q\nTG_CHAT=%q\n' "${OXI_TG_TOKEN}" "${OXI_TG_CHAT}" >"${OXI_HOME}/telegram.env"
  )
  chown "root:${OXI_USER}" "${OXI_HOME}/telegram.env"
  chmod 0640 "${OXI_HOME}/telegram.env"

  cat >/usr/local/bin/oxidized-telegram-notify <<'EOF'
#!/usr/bin/env bash
# Hook de Oxidized (evento post_store): avisa por Telegram de un cambio de configuración.
# Solo envía un resumen: el diff puede contener secretos (hashes, comunidades SNMP,
# claves de VPN...) y no debe salir hacia Telegram. El detalle está en la web/git.
# Uso manual para probar: oxidized-telegram-notify --test
set -uo pipefail
# shellcheck disable=SC1091
. /etc/oxidized/telegram.env

send() {
  # La URL (con el token) va por stdin para que no aparezca en la lista de procesos
  curl -fsS -m 20 -K - \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" \
    -d "disable_web_page_preview=true" >/dev/null \
    <<<"url = \"https://api.telegram.org/bot${TG_TOKEN}/sendMessage\""
}

if [[ "${1:-}" == "--test" ]]; then
  send "✅ Oxidized en $(hostname): notificaciones de Telegram configuradas correctamente."
  exit $?
fi

added='?' removed='?'
if [[ -n "${OX_REPO_NAME:-}" && -n "${OX_REPO_COMMITREF:-}" ]]; then
  read -r added removed < <(git --git-dir="${OX_REPO_NAME}" show --numstat --format= "${OX_REPO_COMMITREF}" 2>/dev/null |
    awk '{a += $1; r += $2} END {print a + 0, r + 0}')
fi

send "🔄 Cambio de configuración detectado
Equipo: ${OX_NODE_NAME:-?}
IP: ${OX_NODE_IP:-?}
Modelo: ${OX_NODE_MODEL:-?}
Líneas: +${added} / -${removed}
Commit: ${OX_REPO_COMMITREF:0:10}"
EOF
  chmod 0755 /usr/local/bin/oxidized-telegram-notify
  msg_ok "Hook de Telegram instalado"

  msg_info "Enviando mensaje de prueba a Telegram"
  if /usr/local/bin/oxidized-telegram-notify --test >>"${INSTALL_LOG}" 2>&1; then
    msg_ok "Mensaje de prueba enviado a Telegram"
  else
    msg_warn "No se pudo enviar el mensaje de prueba: revisa token/chat ID en ${OXI_HOME}/telegram.env"
  fi
}

install_helpers() {
  msg_info "Instalando oxidized-reload"
  {
    echo '#!/usr/bin/env bash'
    echo "# Valida router.db, registra las huellas SSH de los equipos nuevos y hace que"
    echo "# Oxidized relea el inventario (o lo arranca si estaba parado)."
    echo "#"
    echo "#   oxidized-reload                  valida, registra huellas nuevas y recarga"
    echo "#   oxidized-reload --trust IP [P]   vuelve a registrar la huella (equipo sustituido)"
    echo "#   oxidized-reload --forget IP [P]  borra la huella registrada"
    echo "DB=\"${OXI_HOME}/router.db\""
    echo "KH=\"${OXI_DATA}/.ssh/known_hosts\""
    echo "OXI_USER=\"${OXI_USER}\""
    echo "API=\"http://127.0.0.1:${OXI_PORT}\""
    cat <<'EOF'
set -uo pipefail

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
    echo "Huella SSH registrada para ${label} (${host}):"
    ssh-keygen -lf - <<<"${keys}" | sed 's/^/    /'
  else
    echo "AVISO: no se pudo obtener la huella SSH de ${label} (${host}:${port}); su copia fallará hasta registrarla." >&2
  fi
}

finish_kh() { chown "${OXI_USER}:${OXI_USER}" "${KH}"; chmod 0644 "${KH}"; }

case "${1:-}" in
--trust)
  [[ -n "${2:-}" ]] || { echo "Uso: oxidized-reload --trust IP [PUERTO]" >&2; exit 1; }
  forget "$2" "${3:-22}"
  trust "$2" "${3:-22}"
  finish_kh
  exit 0
  ;;
--forget)
  [[ -n "${2:-}" ]] || { echo "Uso: oxidized-reload --forget IP [PUERTO]" >&2; exit 1; }
  forget "$2" "${3:-22}"
  finish_kh
  echo "Huella de $2 eliminada."
  exit 0
  ;;
"") ;;
*)
  echo "Opción desconocida: $1" >&2
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
    echo "router.db línea ${n}: se esperaban 6 campos y hay ${fields}" >&2
    errors=$((errors + 1))
    continue
  fi
  IFS=';' read -r name ip _ <<<"${line}"
  targets+=("${name};${ip:-${name}}")
done <"${DB}"
if [[ ${errors} -gt 0 ]]; then
  echo "Corrige los errores anteriores; no se ha recargado nada." >&2
  exit 1
fi
if [[ ${nodes} -eq 0 ]]; then
  echo "router.db no tiene equipos: Oxidized no arranca hasta que añadas al menos uno." >&2
  exit 1
fi

# Oxidized conecta a la IP resuelta, así que la huella se guarda por IP.
# Los equipos con ssh_port distinto de 22 se registran con: oxidized-reload --trust IP PUERTO
for t in "${targets[@]}"; do
  name=${t%%;*} host=${t#*;}
  if ! [[ "${host}" =~ ^[0-9.]+$ || "${host}" == *:* ]]; then
    host=$(getent ahosts "${host}" | awk 'NR==1 {print $1}')
    [[ -n "${host}" ]] || { echo "AVISO: no se resuelve ${name}; no se registra su huella." >&2; continue; }
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
  echo "Oxidized estaba parado; arrancándolo con ${nodes} equipo(s)..."
  systemctl restart oxidized
  if wait_api; then
    echo "Oxidized en marcha."
  else
    echo "Oxidized no arranca; revisa: journalctl -u oxidized -n 30" >&2
    exit 1
  fi
elif out=$(curl -fsS -m 10 "${API}/reload?format=json" 2>&1); then
  echo "Inventario recargado (${nodes} equipo(s)): ${out}"
else
  echo "La API no responde; enviando SIGHUP para recargar sin reiniciar..."
  systemctl kill -s HUP oxidized
fi
EOF
  } >/usr/local/bin/oxidized-reload
  chmod 0755 /usr/local/bin/oxidized-reload
  msg_ok "Instalado oxidized-reload"
}

setup_service() {
  msg_info "Creando servicio systemd"
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
# Sin locale UTF-8, Ruby lee router.db y las configuraciones como US-ASCII y falla con tildes
Environment=LANG=C.UTF-8 LC_ALL=C.UTF-8
# Oxidized se niega a arrancar con el inventario vacío: sin equipos, systemd no lo
# lanza (queda inactivo, sin bucle de reinicios). oxidized-reload lo arranca después.
ExecCondition=/usr/bin/grep -qvE "^[[:space:]]*(#|$$)" ${OXI_HOME}/router.db
ExecStart=${OXI_BIN}
RuntimeDirectory=oxidized
# Solo protecciones que funcionan en un LXC no privilegiado (las que crean
# namespaces, como ProtectSystem, impiden arrancar al servicio)
NoNewPrivileges=yes
UMask=0027
# SIGTERM (por defecto) en vez de SIGKILL: no corta una escritura en el repo git
TimeoutStopSec=30
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  $STD systemctl enable --now oxidized
  if has_nodes; then
    msg_ok "Servicio oxidized creado y arrancado"
  else
    msg_ok "Servicio oxidized creado (arrancará al añadir equipos)"
  fi
}

# Comillas para valores en un fichero de configuración de curl (-K)
curl_quote() {
  local v=${1//\\/\\\\}
  printf '"%s"' "${v//\"/\\\"}"
}

setup_nginx() {
  [[ "${OXI_WEB_MODE}" == "nginx" ]] || return 0
  msg_info "Configurando nginx con HTTPS y autenticación básica"
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
# Todo el tráfico HTTP se redirige a HTTPS
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

    # Certificado autofirmado; sustitúyelo por uno propio si lo tienes
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
  msg_ok "nginx configurado con HTTPS (443) y redirección desde el 80"
}

verify_install() {
  if ! has_nodes; then
    msg_info "Verificando la configuración"
    if runuser -u "${OXI_USER}" -- env OXIDIZED_HOME="${OXI_HOME}" LANG=C.UTF-8 \
      ruby -ryaml -e 'YAML.unsafe_load_file(ARGV[0])' "${OXI_HOME}/config" >>"${INSTALL_LOG}" 2>&1; then
      msg_ok "Configuración válida; Oxidized arrancará al añadir equipos"
    else
      msg_error "El fichero ${OXI_HOME}/config no es YAML válido (ver ${INSTALL_LOG})"
      exit 1
    fi
    return 0
  fi
  msg_info "Verificando la instalación (hasta 60 s)"
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
    msg_error "Oxidized no responde (reinicios: $(systemctl show -p NRestarts --value oxidized)). Últimas líneas del log:"
    journalctl -u oxidized -n 20 --no-pager >&2 || true
    exit 1
  fi
  msg_ok "Servicio activo y API respondiendo"
  if [[ "${OXI_WEB_MODE}" == "nginx" ]]; then
    if curl -fsS -m 5 -k -K - "https://127.0.0.1/nodes?format=json" >/dev/null 2>&1 \
      <<<"user = $(curl_quote "${OXI_WEB_USER}:${OXI_WEB_PASS}")"; then
      msg_ok "nginx responde por HTTPS con autenticación"
    else
      msg_warn "nginx no responde correctamente (journalctl -u nginx)"
    fi
  fi
}

print_summary() {
  local ip url
  ip=$(container_ip)
  case "${OXI_WEB_MODE}" in
  direct) url="http://${ip}:${OXI_PORT}" ;;
  nginx) url="https://${ip}  (usuario: ${OXI_WEB_USER}, certificado autofirmado)" ;;
  none) url="desactivada (API solo en 127.0.0.1:${OXI_PORT})" ;;
  esac
  echo
  echo -e "${CM}${GN}${BOLD}${APP} $(oxidized_version) instalado correctamente${CL}"
  echo -e "${INFO}${YW}Web:            ${BL}${url}${CL}"
  echo -e "${INFO}${YW}Inventario:     ${BL}${OXI_HOME}/router.db${CL}"
  echo -e "${INFO}${YW}Configuración:  ${BL}${OXI_HOME}/config${CL}"
  echo -e "${INFO}${YW}Repositorio:    ${BL}${OXI_REPO}${CL}"
  [[ "${OXI_GIT_MODE}" == "remote" ]] && echo -e "${INFO}${YW}Remoto:         ${BL}${OXI_GIT_REMOTE}${CL}"
  [[ "${OXI_TELEGRAM}" == "yes" ]] && echo -e "${INFO}${YW}Telegram:       ${BL}${OXI_HOME}/telegram.env${CL}"
  [[ "${OXI_WEB_MODE}" == "nginx" ]] && echo -e "${INFO}${YW}Certificado:    ${BL}/etc/nginx/ssl/oxidized.crt${CL}"
  [[ "${OXI_WEB_MODE}" == "direct" ]] && echo -e "${WARN}${YWB}La web no tiene autenticación ni cifrado: limita el acceso al puerto ${OXI_PORT}${CL}"
  echo
  has_nodes || echo -e "${INFO}${YWB}Oxidized no arranca con el inventario vacío: añade al menos un equipo y ejecuta oxidized-reload${CL}\n"
  echo -e "${TAB}${BOLD}Siguientes pasos:${CL}"
  echo -e "${TAB}1. Añade tus equipos:   ${DGN}nano ${OXI_HOME}/router.db${CL}"
  echo -e "${TAB}2. Arranca/recarga:     ${DGN}oxidized-reload${CL}  (registra también las huellas SSH)"
  echo -e "${TAB}3. Ver logs:            ${DGN}journalctl -u oxidized -f${CL}"
  echo -e "${TAB}4. Actualizar/backup:   ${DGN}vuelve a ejecutar este script${CL}"
  echo
}

# ---------------------------------------------------------------------------
# Mantenimiento: actualizar, copia de seguridad, desinstalar
# ---------------------------------------------------------------------------
do_backup() {
  local file
  file="/root/oxidized-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  msg_info "Creando copia de seguridad"
  local paths=()
  for p in "${OXI_HOME}" "${OXI_DATA}" /etc/systemd/system/oxidized.service \
    /usr/local/bin/oxidized-reload /usr/local/bin/oxidized-telegram-notify \
    /etc/nginx/sites-available/oxidized /etc/nginx/oxidized.htpasswd /etc/nginx/ssl; do
    if [[ -e "${p}" ]]; then paths+=("${p#/}"); fi
  done
  tar -czf "${file}" -C / "${paths[@]}"
  chmod 0600 "${file}"
  msg_ok "Copia guardada en ${BL}${file}${CL}"
}

do_update() {
  local before after
  before=$(oxidized_version)
  do_backup
  msg_info "Actualizando paquetes del sistema"
  export DEBIAN_FRONTEND=noninteractive
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Paquetes del sistema actualizados"
  msg_info "Actualizando Oxidized ${before}"
  $STD gem update --no-document oxidized oxidized-web
  $STD gem cleanup oxidized oxidized-web
  after=$(oxidized_version)
  msg_ok "Oxidized ${before} → ${after}"
  msg_info "Reiniciando el servicio"
  systemctl restart oxidized
  sleep 5
  if systemctl is-active --quiet oxidized; then
    msg_ok "Servicio oxidized activo"
  else
    msg_error "El servicio no arranca tras la actualización (journalctl -u oxidized)"
    exit 1
  fi
}

do_uninstall() {
  ask_yesno "Desinstalar" "Se eliminará Oxidized, su servicio y su configuración.\n\n¿Continuar?" || exit_script
  if ask_yesno "Desinstalar" "¿Hacer antes una copia de seguridad completa en /root?"; then
    do_backup
  fi
  local keep_repo=no
  if [[ -d "${OXI_REPO}" ]] && ask_yesno "Desinstalar" "¿Conservar el repositorio git con el histórico de configuraciones?\n(se moverá a /root/oxidized-configs.git)"; then
    keep_repo=yes
  fi

  msg_info "Desinstalando Oxidized"
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
  msg_ok "Oxidized desinstalado"
  [[ "${keep_repo}" == "yes" ]] && echo -e "${INFO}${YW}Repositorio conservado en ${BL}/root/oxidized-configs.git${CL}"
  echo -e "${INFO}${YW}Las dependencias (ruby, nginx...) se mantienen instaladas${CL}"
}

maintenance_menu() {
  local action="${OXI_ACTION:-}"
  if [[ -z "${action}" ]]; then
    action=$(whiptail --backtitle "${BACKTITLE}" --title "${APP} ya instalado ($(oxidized_version))" \
      --menu "¿Qué quieres hacer?" 15 78 4 \
      "update" "Actualizar (hace antes una copia de seguridad)" \
      "backup" "Copia de seguridad en /root" \
      "uninstall" "Desinstalar" \
      "exit" "Salir" 3>&1 1>&2 2>&3) || exit_script
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
  header_info
  check_os

  if ! command -v whiptail >/dev/null 2>&1; then
    msg_info "Instalando whiptail"
    $STD apt-get update
    $STD apt-get install -y whiptail
    msg_ok "whiptail instalado"
  fi

  if is_installed; then
    maintenance_menu
    exit 0
  fi

  check_container
  check_network
  gather_options
  header_info
  echo -e "${INFO}${YW}Log detallado de la instalación: ${BL}${INSTALL_LOG}${CL}\n"

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
