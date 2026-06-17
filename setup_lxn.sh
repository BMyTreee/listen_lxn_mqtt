#!/usr/bin/env bash
#
# Bootstrap the `lxn` host to run listen_lxn_mqtt.
#   1. ensure Rust toolchain on lxn (via rustup)
#   2. rsync source (excludes target + .env)
#   3. cargo build --release on lxn
#   4. ensure ~/.env on lxn (template only — never overwrite)
#   5. start the binary in a named tmux session
#
# Does NOT read the local .env — you must populate the remote one yourself.
#
set -euo pipefail

# ── env (local .env if present, then defaults) ───────────────────────────────
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${HERE}/.env" ]]; then
    set -a && source "${HERE}/.env" && set +a
fi

# ── ssh target (hardcoded defaults, prompt at runtime) ───────────────────────
SSH_HOST="${LXN_HOST:-lxn}"
read -rp "SSH host [$SSH_HOST]: " _ && [[ -n "$_" ]] && SSH_HOST="$_"

SSH_USER="${LXN_USER:-pi}"
read -rp "SSH user [$SSH_USER]: " _ && [[ -n "$_" ]] && SSH_USER="$_"
readonly REMOTE_DIR="/home/${SSH_USER}/listen_lxn_mqtt"
readonly SESSION_NAME="listen_lxn"

# ── remote service endpoints (hardcoded defaults, prompt at runtime) ─────────
PG_HOST="${PG_HOST:-127.0.0.1}"
read -rp "Postgres host [$PG_HOST]: " _ && [[ -n "$_" ]] && PG_HOST="$_"

PG_PORT="${PG_PORT:-5432}"
read -rp "Postgres port [$PG_PORT]: " _ && [[ -n "$_" ]] && PG_PORT="$_"

PG_USER="${PG_USER:-postgres}"
read -rp "Postgres user [$PG_USER]: " _ && [[ -n "$_" ]] && PG_USER="$_"

PG_PASSWORD="${PG_PASSWORD:-postgres}"
read -rsp "Postgres password [$PG_PASSWORD]: " _ && [[ -n "$_" ]] && PG_PASSWORD="$_"
echo

PG_DB="${PG_DB:-listen_lxn}"
read -rp "Postgres db [$PG_DB]: " _ && [[ -n "$_" ]] && PG_DB="$_"

MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
read -rp "MQTT host [$MQTT_HOST]: " _ && [[ -n "$_" ]] && MQTT_HOST="$_"

MQTT_PORT="${MQTT_PORT:-1883}"
read -rp "MQTT port [$MQTT_PORT]: " _ && [[ -n "$_" ]] && MQTT_PORT="$_"

MQTT_TOPIC="${MQTT_TOPIC:-sensors/+/reading}"
read -rp "MQTT topic [$MQTT_TOPIC]: " _ && [[ -n "$_" ]] && MQTT_TOPIC="$_"

readonly ENV_TEMPLATE="${HERE}/.env.example"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup:err]\033[0m %s\n' "$*" >&2; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
    command -v ssh   >/dev/null || die "ssh not found"
    command -v rsync >/dev/null || die "rsync not found"
    [[ -f "${HERE}/Cargo.toml" ]] || die "must run from the listen_lxn_mqtt repo root"
    log "target=$(remote_target) remote_dir=${REMOTE_DIR}"
}

# ── enable password auth on lxn sshd ─────────────────────────────────────────
ensure_ssh_password_auth() {
    log "enabling password authentication on ${SSH_HOST}"
    local cmd="ssh -o StrictHostKeyChecking=no $(remote_target) 'bash -s'"
    if command -v sshpass >/dev/null 2>&1 && [[ -n "${LXN_SSH_PASS:-}" ]]; then
        cmd="sshpass -p '${LXN_SSH_PASS}' $cmd"
    fi
    eval "$cmd" <<'REMOTE'
set -euo pipefail
SSHD_CONFIG="/etc/ssh/sshd_config"
sudo sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" "$SSHD_CONFIG"
sudo sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" "$SSHD_CONFIG"
sudo systemctl restart sshd || sudo systemctl restart ssh
REMOTE
}

# ── ensure rust on lxn ───────────────────────────────────────────────────────
ensure_rust() {
    log "ensuring rust toolchain on ${SSH_HOST}"
    ssh "$(remote_target)" 'bash -s' <<'REMOTE'
set -euo pipefail
if ! command -v cargo >/dev/null 2>&1; then
    echo "installing rustup + stable toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    # shellcheck disable=SC1090
    source "${HOME}/.cargo/env"
fi
cargo --version
rustc --version
REMOTE
}

# ── sync source ──────────────────────────────────────────────────────────────
sync_source() {
    log "rsync source → ${REMOTE_DIR}"
    ssh "$(remote_target)" "mkdir -p '${REMOTE_DIR}'"
    rsync -azP --delete \
        --exclude='target' \
        --exclude='.env' \
        --exclude='.git' \
        --exclude='.DS_Store' \
        "${HERE}/" "$(remote_target):${REMOTE_DIR}/"
}

# ── build on lxn ─────────────────────────────────────────────────────────────
build_remote() {
    log "cargo build --release on ${SSH_HOST}"
    ssh "$(remote_target)" \
        "cd '${REMOTE_DIR}' && source \"\${HOME}/.cargo/env\" && cargo build --release"
}

# ── write remote .env with service endpoints ────────────────────────────────
ensure_remote_env() {
    log "writing ${REMOTE_DIR}/.env on ${SSH_HOST}"
    local env_content
    env_content=$(cat <<EOF
PG_HOST=${PG_HOST}
PG_PORT=${PG_PORT}
PG_USER=${PG_USER}
PG_PASSWORD=${PG_PASSWORD}
PG_DB=${PG_DB}

MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_TOPIC=${MQTT_TOPIC}
EOF
    )
    ssh "$(remote_target)" "cat > '${REMOTE_DIR}/.env'" <<EOF
${env_content}
EOF
}

# ── tmux ─────────────────────────────────────────────────────────────────────
start_tmux() {
    log "starting tmux session '${SESSION_NAME}'"
    local cmd="cd '${REMOTE_DIR}' && set -a && . ./.env && set +a && ./target/release/listen_lxn_mqtt"
    ssh "$(remote_target)" \
        "tmux has-session -t '${SESSION_NAME}' 2>/dev/null \
            && echo 'session ${SESSION_NAME} already running' \
            || tmux new-session -d -s '${SESSION_NAME}' -c '${REMOTE_DIR}' '${cmd}' \
            && tmux list-sessions"
}

# ── main ─────────────────────────────────────────────────────────────────────
attach_usage() {
    cat <<EOF

next:
    ssh $(remote_target) -t tmux attach -t ${SESSION_NAME}     # attach
    ssh $(remote_target) 'tmux capture-pane -p -t ${SESSION_NAME} -S -50'   # tail
    ssh $(remote_target) 'tmux kill-session -t ${SESSION_NAME}'            # stop
EOF
}

main() {
    preflight
    ensure_ssh_password_auth
    ensure_rust
    sync_source
    build_remote
    ensure_remote_env
    start_tmux
    attach_usage
    log "done."
}

main "$@"
