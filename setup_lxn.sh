#!/usr/bin/env bash
#
# Bootstrap listen_lxn_mqtt on THIS host (run locally).
#   1. open local sshd for password access
#   2. ensure Rust toolchain
#   3. write .env with PG + MQTT endpoints
#   4. cargo build --release
#   5. start the binary in a named tmux session
#
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SESSION_NAME="listen_lxn"

# ── runtime prompts (hardcoded default, customize at runtime) ────────────────
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

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup:err]\033[0m %s\n' "$*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
    [[ -f "${HERE}/Cargo.toml" ]] || die "must run from the listen_lxn_mqtt repo root"
    log "dir=${HERE}"
}

# ── open local sshd for password auth (so external clients can access) ───────
open_local_ssh() {
    log "enabling password authentication on local sshd"
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    systemctl restart sshd || systemctl restart ssh
}

# ── install C toolchain + deps via apt ───────────────────────────────────────
install_deps() {
    log "installing build-essential + curl via apt"
    apt-get update
    apt-get install -y build-essential curl pkg-config libssl-dev
}

# ── ensure rust ──────────────────────────────────────────────────────────────
ensure_rust() {
    log "ensuring rust toolchain"
    if ! command -v cargo >/dev/null 2>&1; then
        echo "installing rustup + stable toolchain"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    # persist cargo PATH for tmux + future shells
    grep -q '.cargo/env' "${HOME}/.bashrc" \
        || echo 'source "${HOME}/.cargo/env"' >> "${HOME}/.bashrc"
    # shellcheck disable=SC1090
    source "${HOME}/.cargo/env"
    cargo --version
    rustc --version
}

# ── write local .env ─────────────────────────────────────────────────────────
write_env() {
    log "writing ${HERE}/.env"
    cat > "${HERE}/.env" <<EOF
PG_HOST=${PG_HOST}
PG_PORT=${PG_PORT}
PG_USER=${PG_USER}
PG_PASSWORD=${PG_PASSWORD}
PG_DB=${PG_DB}

MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_TOPIC=${MQTT_TOPIC}
EOF
}

# ── build ────────────────────────────────────────────────────────────────────
build() {
    log "cargo build --release"
    (cd "${HERE}" && cargo build --release)
}

# ── tmux ─────────────────────────────────────────────────────────────────────
start_tmux() {
    log "starting tmux session '${SESSION_NAME}'"
    # keep pane alive after binary exits so crash logs are readable
    local cmd="cd '${HERE}' && source \"\${HOME}/.cargo/env\" && set -a && . ./.env && set +a && ./target/release/listen_lxn_mqtt; echo '--- process exited (code: '$?) ---'; exec bash"
    tmux has-session -t "${SESSION_NAME}" 2>/dev/null \
        && echo "session ${SESSION_NAME} already running" \
        || tmux new-session -d -s "${SESSION_NAME}" -c "${HERE}" "${cmd}"
    tmux list-sessions
}

attach_usage() {
    cat <<EOF

next:
    tmux attach -t ${SESSION_NAME}                              # attach
    tmux capture-pane -p -t ${SESSION_NAME} -S -50              # tail
    tmux kill-session -t ${SESSION_NAME}                        # stop
EOF
}

main() {
    preflight
    open_local_ssh
    install_deps
    ensure_rust
    write_env
    build
    start_tmux
    attach_usage
    log "done."
}

main "$@"
