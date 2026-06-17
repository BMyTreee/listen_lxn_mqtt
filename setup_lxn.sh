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

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup:err]\033[0m %s\n' "$*" >&2; exit 1; }

# prompt VAR "label" [silent] — set VAR from user input or keep default
prompt() {
    local var="$1" label="$2" silent="${3:-}"
    local input
    if [[ "$silent" == "silent" ]]; then
        read -rsp "$label [${!var}]: " input || true
        echo
    else
        read -rp "$label [${!var}]: " input || true
    fi
    if [[ -n "$input" ]]; then
        printf -v "$var" '%s' "$input"
    fi
}

# ── runtime prompts (hardcoded default, customize at runtime) ────────────────
PG_HOST="${PG_HOST:-127.0.0.1}"
prompt PG_HOST "Postgres host"

PG_PORT="${PG_PORT:-5432}"
prompt PG_PORT "Postgres port"

PG_USER="${PG_USER:-postgres}"
prompt PG_USER "Postgres user"

PG_PASSWORD="${PG_PASSWORD:-postgres}"
prompt PG_PASSWORD "Postgres password" silent

PG_DB="${PG_DB:-listen_lxn}"
prompt PG_DB "Postgres db"

MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
prompt MQTT_HOST "MQTT host"

MQTT_PORT="${MQTT_PORT:-1883}"
prompt MQTT_PORT "MQTT port"

MQTT_TOPIC="${MQTT_TOPIC:-sensors/+/reading}"
prompt MQTT_TOPIC "MQTT topic"

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

# ── install C toolchain + tmux + deps via apt ────────────────────────────────
install_deps() {
    log "installing build-essential, curl, tmux via apt"
    apt-get update
    apt-get install -y build-essential curl pkg-config libssl-dev tmux
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
    tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
    # interactive shell stays alive even after the binary crashes
    tmux new-session -d -s "${SESSION_NAME}" -c "${HERE}"
    tmux send-keys -t "${SESSION_NAME}" \
        "source \"\${HOME}/.cargo/env\" && set -a && . ./.env && set +a && ./target/release/listen_lxn_mqtt" Enter
    tmux list-sessions
}

# ── jump into the running session ────────────────────────────────────────────
jump_to_session() {
    if [[ -n "${TMUX:-}" ]]; then
        exec tmux switch-client -t "${SESSION_NAME}"
    else
        exec tmux attach -t "${SESSION_NAME}"
    fi
}

attach_usage() {
    cat <<EOF

┌─ tmux cheat-sheet (session: ${SESSION_NAME}) ─────────────────────────────┐
│ attach / switch into the session:                                            │
│   tmux attach -t ${SESSION_NAME}            # from a normal shell           │
│   tmux switch-client -t ${SESSION_NAME}     # from inside another tmux      │
│                                                                              │
│ once inside the session, all commands start with the prefix Ctrl+b:          │
│   Ctrl+b  d            detach (leave it running in the background)           │
│   Ctrl+b  s            list/switch between sessions                          │
│   Ctrl+b  ( / )        previous / next session                               │
│   Ctrl+b  c            create a new window inside the session                │
│   Ctrl+b  n / p        next / previous window                                │
│   Ctrl+b  0..9         jump to window N                                      │
│   Ctrl+b  %            split left/right    Ctrl+b " split top/bottom         │
│   Ctrl+b  o            cycle panes         Ctrl+b arrows move between panes  │
│   Ctrl+b  [            enter copy-mode (scroll back, q to exit)              │
│                                                                              │
│ from outside the session:                                                    │
│   tmux ls                                   # list sessions                  │
│   tmux capture-pane -p -t ${SESSION_NAME} -S -50  # tail last 50 lines       │
│   tmux kill-session -t ${SESSION_NAME}      # stop the listener             │
└──────────────────────────────────────────────────────────────────────────────┘
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
    jump_to_session
}

main "$@"
