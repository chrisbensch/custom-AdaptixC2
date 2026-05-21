#!/bin/bash
# Entrypoint for the adaptixc2-omni runtime image.
#
# First-start bootstrap:
#   - Self-signed TLS cert + key generated into /app/data/ if missing.
#   - profile.yaml rendered from /app/profile.yaml.tmpl into /app/data/profile.yaml.
#     Teamserver password is taken from ADAPTIX_TEAMSERVER_PASSWORD or randomly
#     generated. Operators are taken from ADAPTIX_OPERATORS (comma-separated
#     user:pass pairs) or default to one randomly-credentialed operator1.
#   - Generated credentials are persisted to /app/data/credentials.txt (0600).
#
# Subsequent starts reuse /app/data/profile.yaml verbatim. To rotate credentials,
# edit that file directly and restart, or delete it and re-launch with the env
# vars set.
set -euo pipefail
trap 'echo "[-] entrypoint failed at line ${LINENO}" >&2' ERR

echo "[*] Starting Adaptix C2 Server..."

mkdir -p /app/data

# Take ownership of the bind mount as root before doing any cert/profile writes.
# The host directory's ownership doesn't match UID 0 (in CI it's the runner's
# UID; on a real host it's whoever ran `mkdir -p data`). Our cap set is
# deliberately missing CAP_DAC_OVERRIDE, so without this step root can't write
# into /app/data. We chown the directory only — files already inside (from
# prior runs) stay adaptix-owned and aren't touched. Idempotent.
RUNTIME_USER="${RUNTIME_USER:-adaptix}"
chown root:root /app/data

if [ ! -f /app/data/server.rsa.crt ] || [ ! -f /app/data/server.rsa.key ]; then
    echo "[*] Generating self-signed certificates..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /app/data/server.rsa.key -out /app/data/server.rsa.crt \
        -days 3650 -subj "/C=US/ST=State/L=City/O=AdaptixC2/CN=localhost"
    chmod 600 /app/data/server.rsa.key
    echo "[+] Certificates generated"
fi

if [ ! -f /app/data/profile.yaml ]; then
    # Reject explicit empty overrides. Without this guard, `ADAPTIX_OPERATORS=`
    # (typo in compose) would silently fall through to the random default,
    # which can mask broken configuration.
    if [ "${ADAPTIX_TEAMSERVER_PASSWORD+set}" = "set" ] && [ -z "${ADAPTIX_TEAMSERVER_PASSWORD}" ]; then
        echo "[-] ADAPTIX_TEAMSERVER_PASSWORD is set but empty; refusing to start" >&2
        exit 1
    fi
    if [ "${ADAPTIX_OPERATORS+set}" = "set" ] && [ -z "${ADAPTIX_OPERATORS}" ]; then
        echo "[-] ADAPTIX_OPERATORS is set but empty; refusing to start" >&2
        exit 1
    fi

    : "${ADAPTIX_TEAMSERVER_PASSWORD:=$(openssl rand -hex 24)}"
    : "${ADAPTIX_OPERATORS:=operator1:$(openssl rand -hex 16)}"

    ops_file="$(mktemp)"
    trap 'rm -f "${ops_file}"' EXIT

    # Bash array iteration via IFS+read avoids the word-splitting/globbing
    # hazards of `for kv in $unquoted_var`. Validate each entry up front so a
    # malformed list (missing colon, empty user, empty pass) fails fast with a
    # clear message rather than rendering a broken profile.
    IFS=',' read -ra ops_arr <<< "${ADAPTIX_OPERATORS}"
    for kv in "${ops_arr[@]}"; do
        case "${kv}" in
            *:*) ;;
            *)
                echo "[-] ADAPTIX_OPERATORS entry missing ':' separator: '${kv}'" >&2
                exit 1
                ;;
        esac
        user="${kv%%:*}"
        pass="${kv#*:}"
        if [ -z "${user}" ] || [ -z "${pass}" ]; then
            echo "[-] ADAPTIX_OPERATORS entry has empty user or password: '${kv}'" >&2
            exit 1
        fi
        printf '    %s: "%s"\n' "${user}" "${pass}" >> "${ops_file}"
    done

    sed -e "s|__ADAPTIX_TEAMSERVER_PASSWORD__|${ADAPTIX_TEAMSERVER_PASSWORD}|" \
        -e "/__ADAPTIX_OPERATORS_BLOCK__/r ${ops_file}" \
        -e "/__ADAPTIX_OPERATORS_BLOCK__/d" \
        /app/profile.yaml.tmpl > /app/data/profile.yaml
    chmod 600 /app/data/profile.yaml

    {
        echo "teamserver_password=${ADAPTIX_TEAMSERVER_PASSWORD}"
        echo "operators=${ADAPTIX_OPERATORS}"
    } > /app/data/credentials.txt
    chmod 600 /app/data/credentials.txt

    # The teamserver password is recoverable from /app/data/credentials.txt
    # (mode 600). Don't echo it to stdout — Docker captures stdout/stderr in
    # the container log forever, so a `docker logs` reader could otherwise
    # pull historic credentials out of the log even after rotation.
    echo "[+] Rendered /app/data/profile.yaml; credentials persisted to /app/data/credentials.txt"
fi

# Hand /app/data (directory + anything we just created above + anything from
# prior runs) to the unprivileged runtime user, then drop privileges.
chown -R "${RUNTIME_USER}:${RUNTIME_USER}" /app/data

echo "[+] Launching Adaptix Server as ${RUNTIME_USER}..."
exec gosu "${RUNTIME_USER}" "$@"
