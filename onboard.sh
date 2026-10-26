#!/bin/sh
# First-stage host onboarding for Infini Code.
#
# Download this file, inspect it, then run it with `sh onboard.sh`.
# Optional repository arguments use owner/repo, for example infini/infini-ops.
# `--join-domain` is opt-in and requires INFINI_AD_REALM to be set.
set -eu

FORGEJO_URL=${INFINI_CODE_URL:-}
SSH_HOST=${INFINI_CODE_SSH_HOST:-}
SSH_PORT=${INFINI_CODE_SSH_PORT:-2222}
API=
OPS_DIR=${INFINI_OPS_DIR:-"$HOME/infini-ops"}
KEY="$HOME/.ssh/id_ed25519_infini_$(hostname -s | tr -cd 'A-Za-z0-9._-')"
JOIN_DOMAIN=0
REPOS=

usage() {
    cat <<EOF
Usage: sh onboard.sh [--join-domain] [owner/repo ...]

Environment:
  INFINI_CODE_URL       Forgejo HTTPS base URL (default: $FORGEJO_URL)
  INFINI_CODE_SSH_HOST  Forgejo SSH hostname (default: $SSH_HOST)
  INFINI_CODE_SSH_PORT  Forgejo SSH port (default: $SSH_PORT)
  INFINI_OPS_DIR        infini-ops clone path (default: $OPS_DIR)
  INFINI_GIT_NAME       Git author name (default: Liam)
  INFINI_GIT_EMAIL      Git author email (default: malizim@gmail.com)
  INFINI_AD_REALM       AD DNS realm, required with --join-domain
  INFINI_AD_USER        AD account for joining (default: Administrator)
EOF
}

say() { printf '\n== %s\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=; else
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to install host prerequisites and enroll Tailscale"
    SUDO=sudo
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --join-domain) JOIN_DOMAIN=1 ;;
        -h|--help) usage; exit 0 ;;
        --*) fail "unknown option: $1" ;;
        */*) REPOS="$REPOS $1" ;;
        *) fail "repository must be owner/repo: $1" ;;
    esac
    shift
done

say "1. Install prerequisites"
. /etc/os-release
[ "${ID:-}" = debian ] || fail "this bootstrap currently supports Debian hosts only"
[ -n "${VERSION_CODENAME:-}" ] || fail "cannot determine the Debian release codename"
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || \
   ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v update-ca-certificates >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail "install git, curl, ca-certificates, and openssh-client, then rerun"
    $SUDO apt-get update
    $SUDO apt-get install -y git curl ca-certificates openssh-client
fi

say "2. Install and enroll Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
    TS_REPO="https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME"
    TS_KEYRING=$(mktemp)
    TS_LIST=$(mktemp)
    trap 'rm -f "$TS_KEYRING" "$TS_LIST"' EXIT HUP INT TERM
    curl --fail --show-error --location "$TS_REPO.noarmor.gpg" --output "$TS_KEYRING"
    curl --fail --show-error --location "$TS_REPO.tailscale-keyring.list" --output "$TS_LIST"
    $SUDO install -d -m 0755 /usr/share/keyrings
    $SUDO install -o root -g root -m 0644 "$TS_KEYRING" /usr/share/keyrings/tailscale-archive-keyring.gpg
    $SUDO install -o root -g root -m 0644 "$TS_LIST" /etc/apt/sources.list.d/tailscale.list
    rm -f "$TS_KEYRING" "$TS_LIST"
    trap - EXIT HUP INT TERM
    $SUDO apt-get update
    $SUDO apt-get install -y tailscale
fi
$SUDO systemctl enable --now tailscaled
TAILSCALE_IP=$($SUDO tailscale ip -4 2>/dev/null || true)
if [ -z "$TAILSCALE_IP" ]; then
    $SUDO tailscale up || true
    TAILSCALE_IP=$($SUDO tailscale ip -4 2>/dev/null || true)
fi
[ -n "$TAILSCALE_IP" ] || fail "complete the Tailscale sign-in URL above, approve the device if required, then rerun this script"
echo "Tailnet address: $TAILSCALE_IP"

if [ -z "$FORGEJO_URL" ]; then
    printf 'Local site Forgejo HTTPS URL: ' >&2
    IFS= read -r FORGEJO_URL
fi
if [ -z "$SSH_HOST" ]; then
    printf 'Local site Forgejo SSH hostname: ' >&2
    IFS= read -r SSH_HOST
fi
FORGEJO_URL=${FORGEJO_URL%/}
case "$FORGEJO_URL" in
    https://*) ;;
    *) fail "site Forgejo API URL must use HTTPS so credentials stay encrypted" ;;
esac
case "$SSH_HOST" in
    *[!A-Za-z0-9._:-]*) fail "invalid Forgejo SSH host: $SSH_HOST" ;;
esac
API="$FORGEJO_URL/api/v1"

say "3. Create a host-specific SSH key"
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -a 64 -C "$(hostname -s) Infini Code" -N "" -f "$KEY"
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"
    echo "Created $KEY"
else
    echo "Using existing key $KEY"
fi

say "4. Register this host key with your site's Forgejo account"
if ! GIT_SSH_COMMAND="ssh -o IdentitiesOnly=yes -i $KEY -p $SSH_PORT" \
    git ls-remote "ssh://git@$SSH_HOST:$SSH_PORT/infini/infini-ops.git" >/dev/null 2>&1; then
    printf 'Forgejo API token (needs write:user scope; input hidden): ' >&2
    STTY_STATE=$(stty -g 2>/dev/null || true)
    [ -z "$STTY_STATE" ] || stty -echo
    IFS= read -r TOKEN
    [ -z "$STTY_STATE" ] || stty "$STTY_STATE"
    printf '\n' >&2
    [ -n "$TOKEN" ] || fail "no token entered"

    # Keep the short-lived credential out of curl's process arguments and
    # remove its private config immediately after the API request.
    CURL_CONFIG=$(mktemp)
    RESPONSE=$(mktemp)
    trap 'rm -f "$CURL_CONFIG" "$RESPONSE"' EXIT HUP INT TERM
    chmod 600 "$CURL_CONFIG" "$RESPONSE"
    case "$TOKEN" in *[!A-Za-z0-9_-]*) fail "token contains unsupported characters" ;; esac
    printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$CURL_CONFIG"
    unset TOKEN
    PUBKEY=$(awk '{print $1 " " $2}' "$KEY.pub")
    TITLE=$(hostname -s | tr -cd 'A-Za-z0-9._-')
    CODE=$(curl --config "$CURL_CONFIG" --silent --show-error --output "$RESPONSE" \
        --write-out '%{http_code}' --connect-timeout 10 --max-time 30 \
        -H 'Content-Type: application/json' -X POST "$API/user/keys" \
        --data "{\"title\":\"$TITLE\",\"key\":\"$PUBKEY\",\"read_only\":false}") || fail "Forgejo API request failed"
    rm -f "$CURL_CONFIG"
    [ "$CODE" = 201 ] || {
        cat "$RESPONSE" >&2
        fail "Forgejo did not register the key (HTTP $CODE); check token scope and account"
    }
    rm -f "$RESPONSE"
    trap - EXIT HUP INT TERM
fi

echo "Confirm the Forgejo SSH host fingerprint on first connection."
GIT_SSH_COMMAND="ssh -o IdentitiesOnly=yes -i $KEY -p $SSH_PORT" \
    git ls-remote "ssh://git@$SSH_HOST:$SSH_PORT/infini/infini-ops.git" >/dev/null \
    || fail "SSH access to Infini Code is not ready; key registration or host trust failed"
echo "SSH access confirmed. Key: $KEY.pub"

say "5. Configure Git identity"
GIT_NAME=${INFINI_GIT_NAME:-Liam}
GIT_EMAIL=${INFINI_GIT_EMAIL:-malizim@gmail.com}
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
echo "$GIT_NAME <$GIT_EMAIL>"

say "6. Clone or fast-forward infini-ops"
OPS_SSH="ssh://git@$SSH_HOST:$SSH_PORT/infini/infini-ops.git"
if [ -e "$OPS_DIR" ]; then
    [ -d "$OPS_DIR/.git" ] || fail "$OPS_DIR exists but is not a Git checkout; preserve it and choose INFINI_OPS_DIR"
    [ -z "$(git -C "$OPS_DIR" status --porcelain)" ] || fail "$OPS_DIR has local changes; commit or preserve them before updating"
    CURRENT_ORIGIN=$(git -C "$OPS_DIR" remote get-url origin 2>/dev/null || true)
    if [ "$CURRENT_ORIGIN" != "$OPS_SSH" ]; then
        git -C "$OPS_DIR" remote get-url previous-origin >/dev/null 2>&1 \
            && fail "$OPS_DIR already has a previous-origin remote; preserve it and repair the checkout manually"
        if [ -n "$CURRENT_ORIGIN" ]; then
            git -C "$OPS_DIR" remote rename origin previous-origin
        fi
        git -C "$OPS_DIR" remote add origin "$OPS_SSH"
    fi
    git -C "$OPS_DIR" fetch --prune origin
    BRANCH=$(git -C "$OPS_DIR" branch --show-current)
    [ -n "$BRANCH" ] || fail "$OPS_DIR is in detached HEAD state; check it manually"
    git -C "$OPS_DIR" merge --ff-only "origin/$BRANCH"
else
    mkdir -p "$(dirname "$OPS_DIR")"
    git clone "$OPS_SSH" "$OPS_DIR"
fi

say "7. Apply and verify estate time policy from the cloned Infini-Ops repo"
TIME_HELPER="$OPS_DIR/bootstrap/configure-time.sh"
[ -f "$TIME_HELPER" ] || fail "time policy helper is missing at $TIME_HELPER"
INFINI_NTP_SERVER=${INFINI_NTP_SERVER:-} sh "$TIME_HELPER"

say "8. Clone requested estate repositories"
for REPO in $REPOS; do
    case "$REPO" in
        */*/*) fail "repository must contain exactly one slash: $REPO" ;;
        *..*|/*|*/|*[^A-Za-z0-9._/-]*) fail "invalid repository name: $REPO" ;;
    esac
    OWNER=${REPO%%/*}
    NAME=${REPO#*/}
    [ -n "$OWNER" ] && [ -n "$NAME" ] && [ "$OWNER" != "$NAME" ] || fail "repository must be owner/repo: $REPO"
    DEST="$HOME/projects/$NAME"
    [ ! -e "$DEST" ] || fail "$DEST already exists; leaving it untouched"
    mkdir -p "$HOME/projects"
    git clone "ssh://git@$SSH_HOST:$SSH_PORT/$REPO.git" "$DEST"
done

say "9. Check directory membership"
REALMS=
if command -v realm >/dev/null 2>&1; then
    REALMS=$(realm list 2>/dev/null || true)
fi
if [ -n "$REALMS" ]; then
    if [ "$JOIN_DOMAIN" -eq 1 ] && [ -n "${INFINI_AD_REALM:-}" ] && \
        ! printf '%s\n' "$REALMS" | grep -Fqi "$INFINI_AD_REALM"; then
        fail "this host is already joined to a different realm; inspect the realm list before changing membership"
    fi
    printf '%s\n' "$REALMS"
elif [ "$JOIN_DOMAIN" -eq 1 ]; then
    [ -n "${INFINI_AD_REALM:-}" ] || fail "set INFINI_AD_REALM to the Samba AD DNS realm before using --join-domain"
    command -v realm >/dev/null 2>&1 || fail "realmd is not installed; configure DNS and install realmd/SSSD after the Samba DC is ready"
    if [ "$(id -u)" -eq 0 ]; then SUDO=; else SUDO=sudo; fi
    AD_USER=${INFINI_AD_USER:-Administrator}
    $SUDO realm join --user="$AD_USER" "$INFINI_AD_REALM"
else
    echo "Not joined (or realmd is not installed). Domain join is deferred; use --join-domain only after Samba AD DNS and account policy are ready."
fi

say "Done"
echo "Infini-Ops is at $OPS_DIR"
echo "Read $OPS_DIR/AGENTS.md (Codex) or $OPS_DIR/CLAUDE.md, then CONTEXT.md."
