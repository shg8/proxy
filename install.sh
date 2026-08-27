#!/usr/bin/env bash
#
# install.sh - install and start the authenticated HTTP proxy as a systemd service.
#
# Reads credentials from the same .env the Docker Compose stack uses, renders a
# tinyproxy config, and installs a systemd unit named "http-proxy".
#
# The unit and config are deliberately kept separate from the distro's own
# tinyproxy.service and /etc/tinyproxy/tinyproxy.conf, so a pre-existing
# tinyproxy instance keeps running untouched alongside this one.
#
# Usage: sudo ./install.sh [--env PATH] [--port N]

set -euo pipefail

SERVICE_NAME="http-proxy"
CONF_DIR="/etc/${SERVICE_NAME}"
CONF_FILE="${CONF_DIR}/tinyproxy.conf"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
RUN_USER="tinyproxy"
DEFAULT_PORT=3129
DEFAULT_CONNECT_PORTS="443 563"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PORT_OVERRIDE=""

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env)  ENV_FILE="${2:-}"; [ -n "$ENV_FILE" ] || die "--env needs a path"; shift 2 ;;
    --port) PORT_OVERRIDE="${2:-}"; [ -n "$PORT_OVERRIDE" ] || die "--port needs a number"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root - try: sudo $0"
[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"
command -v systemctl >/dev/null 2>&1 || die "systemd is required but systemctl was not found"

# Read one KEY=VALUE from the env file without evaluating it as shell, so that
# passwords containing $, backticks or quotes cannot be executed or mangled.
read_env() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  val="${val%$'\r'}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

PROXY_USER="$(read_env PROXY_USER)"
PROXY_PASS="$(read_env PROXY_PASS)"
PROXY_BIND="$(read_env PROXY_BIND)"
PROXY_MAXCONN="$(read_env PROXY_MAXCONN)"
NATIVE_PORT="$(read_env NATIVE_PORT)"
CONNECT_PORTS="$(read_env NATIVE_CONNECT_PORTS)"

[ -n "$PROXY_USER" ] || die "PROXY_USER is empty or missing in $ENV_FILE"
[ -n "$PROXY_PASS" ] || die "PROXY_PASS is empty or missing in $ENV_FILE"

# tinyproxy's BasicAuth directive is whitespace-delimited, so a credential
# containing whitespace would silently truncate and let the wrong password in.
case "$PROXY_USER$PROXY_PASS" in
  *[[:space:]]*) die "PROXY_USER/PROXY_PASS must not contain whitespace (tinyproxy BasicAuth is space-delimited)" ;;
esac

PORT="${PORT_OVERRIDE:-${NATIVE_PORT:-$DEFAULT_PORT}}"
case "$PORT" in
  ''|*[!0-9]*) die "port must be numeric, got: $PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port out of range: $PORT"

BIND="${PROXY_BIND:-0.0.0.0}"
MAXCONN="${PROXY_MAXCONN:-200}"
CONNECT_PORTS="${CONNECT_PORTS:-$DEFAULT_CONNECT_PORTS}"

if ! command -v tinyproxy >/dev/null 2>&1; then
  info "installing tinyproxy from apt"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tinyproxy
fi
TINYPROXY_BIN="$(command -v tinyproxy)"
id -u "$RUN_USER" >/dev/null 2>&1 || die "service user '$RUN_USER' does not exist (expected from the tinyproxy package)"

# Stop our own instance first so a re-run does not collide with itself on the port.
if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1 \
   && systemctl is-active --quiet "$SERVICE_NAME"; then
  info "stopping existing ${SERVICE_NAME} for reconfiguration"
  systemctl stop "$SERVICE_NAME"
fi

if ss -lnt "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  die "port ${PORT} is already in use by another process - pick another with --port N or NATIVE_PORT in ${ENV_FILE}"
fi

info "writing ${CONF_FILE}"
install -d -m 0755 "$CONF_DIR"
umask 077
{
  printf '# Managed by install.sh - regenerated on every run.\n'
  printf '# Edit %s and re-run the installer instead of editing this file.\n\n' "$ENV_FILE"
  printf 'Port %s\n' "$PORT"
  printf 'Listen %s\n' "$BIND"
  printf 'Timeout 600\n'
  printf 'MaxClients %s\n' "$MAXCONN"
  printf 'PidFile "/run/%s/%s.pid"\n' "$SERVICE_NAME" "$SERVICE_NAME"
  printf 'Syslog On\n\n'
  printf '# No Allow/Deny rules: any source address may connect, but every request\n'
  printf '# must carry these credentials.\n'
  printf 'BasicAuth %s %s\n\n' "$PROXY_USER" "$PROXY_PASS"
  printf '# Restrict CONNECT tunnelling so the proxy cannot be used to reach\n'
  printf '# arbitrary TCP services such as SMTP.\n'
  for p in $CONNECT_PORTS; do printf 'ConnectPort %s\n' "$p"; done
} > "$CONF_FILE"
chown "root:${RUN_USER}" "$CONF_FILE"
chmod 0640 "$CONF_FILE"
umask 022

info "writing ${UNIT_FILE}"
cat > "$UNIT_FILE" <<UNIT
# Managed by install.sh - regenerated on every run.
[Unit]
Description=Authenticated HTTP proxy (tinyproxy)
Documentation=man:tinyproxy(8)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${TINYPROXY_BIN} -d -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2s
RuntimeDirectory=${SERVICE_NAME}
RuntimeDirectoryMode=0750

# Allow binding a privileged port if PROXY_PORT is ever set below 1024.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$UNIT_FILE"

info "enabling and starting ${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable --quiet "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

for _ in $(seq 1 25); do
  ss -lnt "sport = :${PORT}" 2>/dev/null | grep -q LISTEN && break
  sleep 0.2
done

systemctl is-active --quiet "$SERVICE_NAME" \
  || { systemctl --no-pager --full status "$SERVICE_NAME" || true; die "${SERVICE_NAME} failed to start"; }
ss -lnt "sport = :${PORT}" 2>/dev/null | grep -q LISTEN \
  || die "${SERVICE_NAME} is running but nothing is listening on port ${PORT}"

# Hard check: an unauthenticated request must be refused. This is answered by
# tinyproxy itself, so it does not depend on outbound internet access.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "http://127.0.0.1:${PORT}" http://example.com/ 2>/dev/null || true)"
[ "$code" = "407" ] || die "proxy did not require authentication (got HTTP '${code}', expected 407) - refusing to leave an open proxy running"
info "auth check passed: unauthenticated requests are refused (407)"

# Soft check: needs outbound internet, so a failure here is not fatal.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PORT}" https://example.com/ 2>/dev/null || true)"
if [ "$code" = "200" ]; then
  info "end-to-end check passed: HTTPS through the proxy returned 200"
else
  warn "authenticated end-to-end request returned '${code}' instead of 200 - check outbound connectivity"
fi

if systemctl is-active --quiet tinyproxy 2>/dev/null; then
  warn "the distro's separate tinyproxy.service is also running; it was left untouched"
fi

cat <<EOF

${SERVICE_NAME} is installed and running.

  listening   ${BIND}:${PORT}
  user        ${PROXY_USER}
  config      ${CONF_FILE}
  unit        ${UNIT_FILE}

  test        curl -x http://${PROXY_USER}:<password>@${BIND}:${PORT} https://example.com
  logs        journalctl -u ${SERVICE_NAME} -f
  restart     systemctl restart ${SERVICE_NAME}

Re-run this script after editing ${ENV_FILE} to apply credential changes.
EOF
