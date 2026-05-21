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
set -e

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
    : "${ADAPTIX_TEAMSERVER_PASSWORD:=$(openssl rand -hex 24)}"
    : "${ADAPTIX_OPERATORS:=operator1:$(openssl rand -hex 16)}"

    ops_file="$(mktemp)"
    IFS=','
    for kv in $ADAPTIX_OPERATORS; do
        printf '    %s: "%s"\n' "${kv%%:*}" "${kv#*:}" >> "$ops_file"
    done
    unset IFS

    sed -e "s|__ADAPTIX_TEAMSERVER_PASSWORD__|${ADAPTIX_TEAMSERVER_PASSWORD}|" \
        -e "/__ADAPTIX_OPERATORS_BLOCK__/r ${ops_file}" \
        -e "/__ADAPTIX_OPERATORS_BLOCK__/d" \
        /app/profile.yaml.tmpl > /app/data/profile.yaml
    rm -f "$ops_file"
    chmod 600 /app/data/profile.yaml

    {
        echo "teamserver_password=${ADAPTIX_TEAMSERVER_PASSWORD}"
        echo "operators=${ADAPTIX_OPERATORS}"
    } > /app/data/credentials.txt
    chmod 600 /app/data/credentials.txt

    echo "[+] Wrote /app/data/profile.yaml and /app/data/credentials.txt"
    echo "[+] Teamserver password: ${ADAPTIX_TEAMSERVER_PASSWORD}"
fi

# Hand /app/data (directory + anything we just created above + anything from
# prior runs) to the unprivileged runtime user, then drop privileges.
chown -R "${RUNTIME_USER}:${RUNTIME_USER}" /app/data

echo "[+] Launching Adaptix Server as ${RUNTIME_USER}..."
exec gosu "${RUNTIME_USER}" "$@"
