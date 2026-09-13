#!/usr/bin/env bash
set -Eeuo pipefail

# Fast Cline ChatGPT-subscription auth bridge for remote/headless environments.
#
# Flow:
#   ~/.codex/auth.json  -->  ~/.cline/data/settings/providers.json
#
# Current Cline can consume native openai-codex OAuth credentials from its
# provider settings, so no Cline checkout/build/VSIX patch is required.
#
# Optional environment variables:
#   CODEX_HOME=/custom/codex/home
#   CLINE_DATA_DIR=/custom/cline/data
#   CLINE_PROVIDER_SETTINGS_PATH=/custom/providers.json
#   BACKUP_CLINE_SETTINGS=1     Create a 0600 backup before changing providers.json
#   LOGIN=1                     Intentionally run a fresh Codex device-code login
#   SKIP_CODEX_INSTALL=1        Never install Codex automatically
#   AUTO_RESTART_EXTENSION_HOST=0
#                               Do not restart the VS Code remote extension host
#
# Normal usage:
#   ./setup-cline-device-auth-fast-v5.sh
#
# Fresh authentication:
#   LOGIN=1 ./setup-cline-device-auth-fast-v5.sh

BACKUP_CLINE_SETTINGS="${BACKUP_CLINE_SETTINGS:-0}"
LOGIN="${LOGIN:-0}"
SKIP_CODEX_INSTALL="${SKIP_CODEX_INSTALL:-0}"
AUTO_RESTART_EXTENSION_HOST="${AUTO_RESTART_EXTENSION_HOST:-1}"

BIN_DIR="$HOME/.local/bin"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_AUTH_FILE="$CODEX_HOME_DIR/auth.json"
CLINE_DATA_DIR="${CLINE_DATA_DIR:-$HOME/.cline/data}"
PROVIDERS_FILE="${CLINE_PROVIDER_SETTINGS_PATH:-$CLINE_DATA_DIR/settings/providers.json}"
GLOBAL_STATE_FILE="$CLINE_DATA_DIR/globalState.json"

MIN_VALIDITY_SECONDS=300

mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

install_base_tools() {
    local missing=()
    need python3 || missing+=(python3)
    ((${#missing[@]})) || return 0

    local -a apt_cmd
    if [[ "$(id -u)" -eq 0 ]]; then
        apt_cmd=(apt-get)
    elif need sudo; then
        apt_cmd=(sudo apt-get)
    else
        die "Missing Ubuntu packages (${missing[*]}), but neither root nor sudo is available."
    fi

    DEBIAN_FRONTEND=noninteractive "${apt_cmd[@]}" update
    DEBIAN_FRONTEND=noninteractive "${apt_cmd[@]}" install -y --no-install-recommends \
        ca-certificates "${missing[@]}"
}

install_curl_if_needed() {
    need curl && return 0

    local -a apt_cmd
    if [[ "$(id -u)" -eq 0 ]]; then
        apt_cmd=(apt-get)
    elif need sudo; then
        apt_cmd=(sudo apt-get)
    else
        die "curl is required to install Codex, but neither root nor sudo is available."
    fi

    DEBIAN_FRONTEND=noninteractive "${apt_cmd[@]}" update
    DEBIAN_FRONTEND=noninteractive "${apt_cmd[@]}" install -y --no-install-recommends \
        ca-certificates curl
}

install_base_tools

codex_auth_is_fresh() {
    CODEX_AUTH_FILE="$CODEX_AUTH_FILE" \
    MIN_VALIDITY_SECONDS="$MIN_VALIDITY_SECONDS" \
    python3 - <<'PY' >/dev/null 2>&1
import base64
import json
import os
import time
from pathlib import Path

path = Path(os.environ["CODEX_AUTH_FILE"]).expanduser()
minimum = int(os.environ["MIN_VALIDITY_SECONDS"])

if not path.is_file():
    raise SystemExit(1)

try:
    auth = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

mode = auth.get("auth_mode")
if mode and mode != "chatgpt":
    raise SystemExit(1)

tokens = auth.get("tokens")
if not isinstance(tokens, dict):
    raise SystemExit(1)

access = tokens.get("access_token")
refresh = tokens.get("refresh_token")
if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh:
    raise SystemExit(1)

def claims(token):
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        value = json.loads(base64.urlsafe_b64decode(part.encode()).decode())
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}

payload = claims(access)
exp = payload.get("exp")
if not isinstance(exp, (int, float)):
    id_token = tokens.get("id_token")
    if isinstance(id_token, str) and id_token:
        exp = claims(id_token).get("exp")

if not isinstance(exp, (int, float)):
    raise SystemExit(1)

raise SystemExit(0 if exp - time.time() > minimum else 1)
PY
}

ensure_codex() {
    if need codex; then
        return 0
    fi

    [[ "$SKIP_CODEX_INSTALL" != "1" ]] \
        || die "Codex CLI is required for login but automatic installation is disabled."

    say "Installing Codex CLI"
    install_curl_if_needed
    curl -fsSL https://raw.githubusercontent.com/openai/codex/main/scripts/install/install.sh \
        | CODEX_NON_INTERACTIVE=1 sh
    export PATH="$HOME/.local/bin:$PATH"
    need codex || die "Codex installation finished but 'codex' is not on PATH."
}

if [[ "$LOGIN" == "1" ]]; then
    say "Refreshing ChatGPT authentication with device code"
    ensure_codex
    codex login --device-auth
elif codex_auth_is_fresh; then
    say "Using existing Codex ChatGPT authentication"
    echo "Found a usable OAuth session in $CODEX_AUTH_FILE"
else
    say "Codex ChatGPT authentication is missing or near expiry"
    ensure_codex
    codex login --device-auth
fi

codex_auth_is_fresh \
    || die "Codex authentication is still missing, invalid, or expires within ${MIN_VALIDITY_SECONDS} seconds."

say "Importing credentials into Cline"

CODEX_AUTH_FILE="$CODEX_AUTH_FILE" \
PROVIDERS_FILE="$PROVIDERS_FILE" \
BACKUP_CLINE_SETTINGS="$BACKUP_CLINE_SETTINGS" \
MIN_VALIDITY_SECONDS="$MIN_VALIDITY_SECONDS" \
python3 - <<'PY'
import base64
import json
import os
import shutil
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

codex_path = Path(os.environ["CODEX_AUTH_FILE"]).expanduser()
providers_path = Path(os.environ["PROVIDERS_FILE"]).expanduser()
backup_enabled = os.environ.get("BACKUP_CLINE_SETTINGS") == "1"
min_validity = int(os.environ["MIN_VALIDITY_SECONDS"])

def decode_jwt(token: str) -> dict:
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        value = json.loads(base64.urlsafe_b64decode(part.encode()).decode())
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}

try:
    auth = json.loads(codex_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"ERROR: Could not read Codex auth file: {exc}")

mode = auth.get("auth_mode")
if mode and mode != "chatgpt":
    raise SystemExit(f"ERROR: Codex auth_mode is {mode!r}, not a ChatGPT OAuth session.")

tokens = auth.get("tokens")
if not isinstance(tokens, dict):
    raise SystemExit("ERROR: Codex auth.json does not contain a tokens object.")

access = (tokens.get("access_token") or "").strip()
refresh = (tokens.get("refresh_token") or "").strip()
id_token = (tokens.get("id_token") or "").strip()

if not access or not refresh:
    raise SystemExit("ERROR: Codex auth.json does not contain access_token + refresh_token.")

access_claims = decode_jwt(access)
id_claims = decode_jwt(id_token) if id_token else {}

def get_account_id():
    stored = (tokens.get("account_id") or "").strip()
    if stored:
        return stored

    for claims in (id_claims, access_claims):
        nested = claims.get("https://api.openai.com/auth")
        if isinstance(nested, dict):
            value = nested.get("chatgpt_account_id")
            if isinstance(value, str) and value:
                return value

        value = claims.get("chatgpt_account_id")
        if isinstance(value, str) and value:
            return value

        orgs = claims.get("organizations")
        if isinstance(orgs, list) and orgs and isinstance(orgs[0], dict):
            value = orgs[0].get("id")
            if isinstance(value, str) and value:
                return value
    return None

def get_expiry_ms():
    for claims in (access_claims, id_claims):
        exp = claims.get("exp")
        if isinstance(exp, (int, float)) and exp > 0:
            return int(exp * 1000)
    return None

def get_email():
    for claims in (id_claims, access_claims):
        value = claims.get("email")
        if isinstance(value, str) and value:
            return value
    return None

account_id = get_account_id()
expires_at = get_expiry_ms()
email = get_email()

if not account_id:
    raise SystemExit("ERROR: Could not determine ChatGPT account ID from Codex credentials.")
if not expires_at:
    raise SystemExit("ERROR: Could not determine OAuth expiry from Codex JWT.")
if expires_at <= int((time.time() + min_validity) * 1000):
    raise SystemExit("ERROR: Codex OAuth token is too close to expiry; authenticate again.")

providers_path.parent.mkdir(parents=True, exist_ok=True)

if providers_path.exists():
    try:
        state = json.loads(providers_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"ERROR: Existing {providers_path} is not valid JSON: {exc}")
else:
    state = {"version": 1, "providers": {}}

if not isinstance(state, dict):
    raise SystemExit("ERROR: Cline providers.json root is not an object.")

providers = state.setdefault("providers", {})
if not isinstance(providers, dict):
    raise SystemExit("ERROR: Cline providers.json has a non-object 'providers' field.")

entry = providers.get("openai-codex")
if entry is not None and not isinstance(entry, dict):
    raise SystemExit("ERROR: Existing openai-codex provider entry has an unexpected shape.")

entry = entry or {}
settings = entry.get("settings")
if settings is not None and not isinstance(settings, dict):
    raise SystemExit("ERROR: Existing openai-codex settings field has an unexpected shape.")
settings = settings or {}

existing_auth = settings.get("auth")
if existing_auth is not None and not isinstance(existing_auth, dict):
    raise SystemExit("ERROR: Existing openai-codex auth field has an unexpected shape.")

credentials_changed = True

if isinstance(existing_auth, dict):
    existing_access = existing_auth.get("accessToken")
    existing_refresh = existing_auth.get("refreshToken")
    if isinstance(existing_access, str) and existing_access and isinstance(existing_refresh, str) and existing_refresh:
        existing_account = existing_auth.get("accountId")
        existing_expiry = existing_auth.get("expiresAt")
        same_account = not existing_account or existing_account == account_id

        if not same_account:
            raise SystemExit(
                "ERROR: Cline already contains native OpenAI Codex credentials for a different account.\n"
                "Sign out of OpenAI Codex / ChatGPT Subscription inside Cline first, then rerun this script.\n"
                "The script intentionally will not overwrite credentials because VS Code secret storage may take precedence."
            )

        # Cline may already have rotated its refresh token. Preserve its native
        # credential copy rather than replacing it with the Codex CLI copy.
        credentials_changed = False
        if isinstance(existing_expiry, (int, float)) and existing_expiry >= expires_at:
            print("Cline already has OpenAI Codex credentials for this account that are at least as new.")
        else:
            print("Cline already has OpenAI Codex credentials for this account; preserving Cline's copy.")

if credentials_changed:
    new_auth = {
        "accessToken": access,
        "refreshToken": refresh,
        "expiresAt": expires_at,
        "accountId": account_id,
    }
    if email:
        new_auth["email"] = email

    new_settings = dict(settings)
    new_settings["provider"] = "openai-codex"
    new_settings["auth"] = new_auth

    new_entry = dict(entry)
    new_entry["settings"] = new_settings
    new_entry["tokenSource"] = "oauth"
    new_entry["updatedAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    providers["openai-codex"] = new_entry

state.setdefault("version", 1)

# Make the native ChatGPT-subscription provider the active Cline provider.
# This removes the manual provider-selection / "Sign In" step after import.
provider_changed = state.get("lastUsedProvider") != "openai-codex"
state["lastUsedProvider"] = "openai-codex"

if not credentials_changed and not provider_changed:
    print("Cline is already configured to use OpenAI Codex / ChatGPT Subscription.")
    print("No provider-settings changes were necessary.")
    raise SystemExit(0)

if backup_enabled and providers_path.exists():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = providers_path.with_name(f"{providers_path.name}.{stamp}.bak")
    shutil.copy2(providers_path, backup)
    os.chmod(backup, 0o600)
    print(f"Backup created: {backup}")

payload = json.dumps(state, indent=2, ensure_ascii=False) + "\n"

fd, temp_name = tempfile.mkstemp(prefix=providers_path.name + ".", dir=providers_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temp_name, 0o600)
    os.replace(temp_name, providers_path)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass

try:
    written = json.loads(providers_path.read_text(encoding="utf-8"))
    written_auth = written["providers"]["openai-codex"]["settings"]["auth"]
except Exception as exc:
    raise SystemExit(f"ERROR: Wrote providers.json but read-back validation failed: {exc}")

required = {
    "accessToken": str,
    "refreshToken": str,
    "expiresAt": (int, float),
    "accountId": str,
}
for key, expected in required.items():
    value = written_auth.get(key)
    if not isinstance(value, expected) or (isinstance(value, str) and not value):
        raise SystemExit(f"ERROR: Read-back validation failed for auth.{key}.")

if written_auth["accountId"] != account_id:
    raise SystemExit("ERROR: Read-back validation found a different account ID.")

print(f"Configured Cline native OpenAI Codex provider in: {providers_path}")
print("OpenAI Codex / ChatGPT Subscription is now Cline's active provider.")
print("Read-back validation passed.")
print("OAuth token values were not printed.")
PY

say "Completing Cline onboarding state"

GLOBAL_STATE_FILE="$GLOBAL_STATE_FILE" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

path = Path(os.environ["GLOBAL_STATE_FILE"]).expanduser()
path.parent.mkdir(parents=True, exist_ok=True)

if path.exists():
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"ERROR: Existing {path} is not valid JSON: {exc}")
else:
    state = {}

if not isinstance(state, dict):
    raise SystemExit(f"ERROR: {path} root is not a JSON object.")

already = state.get("welcomeViewCompleted") is True
state["welcomeViewCompleted"] = True

payload = json.dumps(state, indent=2, ensure_ascii=False) + "\n"
fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass

print("Cline welcome/onboarding state was already complete." if already else "Marked Cline welcome/onboarding state complete.")
print(f"Global state: {path}")
PY

restart_extension_host() {
    [[ "$AUTO_RESTART_EXTENSION_HOST" == "1" ]] || return 0

    # VS Code does not expose Developer: Reload Window through its supported
    # shell CLI. In Codespaces/remote VS Code, restarting the remote extension
    # host is sufficient for Cline to reactivate and reread providers.json.
    local -a pids=()
    mapfile -t pids < <(
        python3 - <<'PY'
import os

uid = os.getuid()
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    proc = f"/proc/{name}"
    try:
        if os.stat(proc).st_uid != uid:
            continue
        raw = open(f"{proc}/cmdline", "rb").read()
        cmd = raw.replace(b"\0", b" ").decode("utf-8", "replace")
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue

    # VS Code remote builds have used both forms below. Match only the
    # extension host, not ptyHost/server-main.
    if "extensionHostProcess" in cmd or "--type=extensionHost" in cmd:
        print(name)
PY
    )

    if ((${#pids[@]} == 0)); then
        echo
        echo "No VS Code remote extension-host process was found."
        echo "Cline is configured; if its UI was already open, reload the window manually once."
        return 0
    fi

    echo
    echo "Found ${#pids[@]} VS Code remote extension-host process(es)."
    echo "Restarting extension host immediately..."

    # Restart immediately. Integrated terminals are hosted by ptyHost, not extensionHost,
    # so terminating the extension host should not kill the shell running this script.
    kill -TERM "${pids[@]}" 2>/dev/null || true
}

restart_extension_host

cat <<EOF

Done.

Cline has been configured automatically to use:
  OpenAI Codex / ChatGPT Subscription

Cline onboarding has also been marked complete. The remote VS Code extension
host restart is triggered immediately so Cline rereads both state files.

Do NOT select the Codex CLI provider for this path.

Credential source:
  $CODEX_AUTH_FILE

Cline provider store:
  $PROVIDERS_FILE

Cline global state:
  $GLOBAL_STATE_FILE

Notes:
  - The script is intentionally one-way and import-once.
  - Existing Cline OAuth credentials are never overwritten.
  - Cline's active provider is set automatically to openai-codex.
  - AUTO_RESTART_EXTENSION_HOST=0 disables the automatic extension-host restart.
  - BACKUP_CLINE_SETTINGS=1 creates an explicit plaintext settings backup;
    the default is no backup because providers.json contains OAuth secrets.
  - LOGIN=1 intentionally performs a new Codex device-code login before import.
EOF
