#!/usr/bin/env bashio
# Rocrail Add-on startup

set -e

MIN_KEY_SIZE=50
SHARE_ROOT="/share/rocrail"

# ===========================================================
# Runtime Rocrail-install layout (post-2.0.0)
# -----------------------------------------------------------
# The container image ships NO Rocrail binary. On first start the
# add-on downloads the Rocrail server zip for the current architecture
# directly from rocrail.online and unpacks it under /data/rocrail/.
# Subsequent starts reuse the installed copy. Updates are explicit and
# user-triggered via the "check_and_install_rocrail_update" toggle.
#
# See LICENSE / README for why we don't redistribute Rocrail binaries.
# ===========================================================
ROCRAIL_HOME="/data/rocrail"
ROCRAIL_BIN_DIR="${ROCRAIL_HOME}/bin"
INSTALLED_REV_FILE="${ROCRAIL_HOME}/.installed-revision"
LAST_CHECK_FILE="${ROCRAIL_HOME}/.last-upstream-check"
LAST_NOTIFIED_FILE="${ROCRAIL_HOME}/.last-notified-revision"
UPSTREAM_INDEX_URL="https://rocrail.net/rocrail-snapshot/"
HISTORY_URL_FMT="https://rocrail.net/rocrail-snapshot/history/Rocrail-%s-%s.zip"
WIKI_LICENCE_URL="https://wiki.rocrail.net/doku.php?id=licence-en"
CHECK_TTL_SECONDS=86400

# ----- Read HA add-on options -----
LOG_LEVEL=$(bashio::config 'log_level')
WORKSPACE=$(bashio::config 'workspace')
ROCWEB_PORT=$(bashio::config 'rocweb_port')
CLIENT_PORT=$(bashio::config 'client_protocol_port')
SUPPORT_KEY_INLINE=$(bashio::config 'support_key' '')
ADDON_VERSION=$(bashio::addon.version 2>/dev/null || echo "dev")
USER_AGENT="ha-addon-rocrail/${ADDON_VERSION} (+https://github.com/magliaral/ha-addon-rocrail)"

# ----- Workspace name validation -----
case "${WORKSPACE}" in
    _*|lic.dat|README.txt|"")
        bashio::log.fatal "Workspace name '${WORKSPACE}' is reserved or empty. Choose another."
        exit 1
        ;;
esac

# ===========================================================
# Helpers
# ===========================================================

# uname -m -> upstream Linux dist tag used in the Rocrail snapshot
# filenames. Mirrors the platform table in detect-latest-revs.py (now
# retired) and rocrail/Dockerfile (legacy).
detect_arch_dist() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)
            echo "debian11-i64"
            ;;
        aarch64|arm64)
            echo "debian13-ARM64"
            ;;
        *)
            return 1
            ;;
    esac
}

# Query rocrail.online for the highest available revision for the
# given dist. Caches result in LAST_CHECK_FILE with epoch+rev. With
# force=true the cache is bypassed (used when the user explicitly
# requests an update via the toggle).
fetch_latest_revision() {
    local dist="$1"
    local force="${2:-false}"
    local now cached_ts cached_rev age html rev

    if [ "${force}" != "true" ] && [ -f "${LAST_CHECK_FILE}" ]; then
        cached_ts=$(awk 'NR==1{print $1}' "${LAST_CHECK_FILE}" 2>/dev/null || echo 0)
        cached_rev=$(awk 'NR==1{print $2}' "${LAST_CHECK_FILE}" 2>/dev/null || echo "")
        now=$(date +%s)
        age=$(( now - cached_ts ))
        if [ "${age}" -lt "${CHECK_TTL_SECONDS}" ] && [ -n "${cached_rev}" ]; then
            echo "${cached_rev}"
            return 0
        fi
    fi

    if ! html=$(curl -fsSL --max-time 30 -A "${USER_AGENT}" "${UPSTREAM_INDEX_URL}" 2>/dev/null); then
        return 1
    fi
    rev=$(echo "${html}" \
        | grep -oE "Rocrail-[0-9]+-${dist}\\.zip" \
        | grep -oE '[0-9]+' \
        | sort -n | tail -1)
    if [ -z "${rev}" ]; then
        return 1
    fi

    mkdir -p "$(dirname "${LAST_CHECK_FILE}")"
    printf '%s %s\n' "$(date +%s)" "${rev}" > "${LAST_CHECK_FILE}"
    echo "${rev}"
    return 0
}

# Download + install a specific Rocrail revision into ROCRAIL_HOME.
# decspecs/ is treated as user data: copied on first install only, and
# preserved across re-installs even when the zip ships an updated copy.
install_rocrail() {
    local rev="$1"
    local dist="$2"
    local zip_url tmp_dir bin_count
    zip_url=$(printf "${HISTORY_URL_FMT}" "${rev}" "${dist}")

    tmp_dir=$(mktemp -d /tmp/rocrail-install.XXXXXX)

    bashio::log.info "Fetching ${zip_url}"
    # curl's interactive progress meter uses \r redraws and the HA add-on
    # log pipe turns every redraw into a separate line — ugly. Run silent
    # (-sS = no progress, errors still shown) and log a one-line summary
    # with size / duration / throughput after the transfer completes.
    local dl_start dl_end dl_bytes dl_elapsed dl_size_mib dl_rate_kib
    dl_start=$(date +%s)
    if ! curl -fsSL --max-time 600 -A "${USER_AGENT}" \
        -o "${tmp_dir}/rocrail.zip" "${zip_url}"; then
        bashio::log.error "Download failed: ${zip_url}"
        rm -rf "${tmp_dir}"
        return 1
    fi
    dl_end=$(date +%s)
    dl_bytes=$(stat -c%s "${tmp_dir}/rocrail.zip" 2>/dev/null || echo 0)
    dl_elapsed=$(( dl_end - dl_start ))
    [ "${dl_elapsed}" -lt 1 ] && dl_elapsed=1
    dl_size_mib=$(( dl_bytes / 1048576 ))
    dl_rate_kib=$(( dl_bytes / dl_elapsed / 1024 ))
    bashio::log.info "Downloaded ${dl_size_mib} MiB in ${dl_elapsed}s (${dl_rate_kib} KiB/s)"

    bashio::log.info "Unpacking Rocrail r${rev} (${dist}) ..."
    mkdir -p "${tmp_dir}/extract"
    if ! unzip -q "${tmp_dir}/rocrail.zip" -d "${tmp_dir}/extract"; then
        bashio::log.error "Unzip failed for ${zip_url}"
        rm -rf "${tmp_dir}"
        return 1
    fi

    mkdir -p "${ROCRAIL_HOME}"

    # decspecs/ are user-modifiable. Once a user has them locally we
    # never overwrite — they may have edited or added their own files.
    if [ -d "${ROCRAIL_HOME}/decspecs" ]; then
        bashio::log.info "Preserving existing ${ROCRAIL_HOME}/decspecs/ (user data)"
        rm -rf "${tmp_dir}/extract/decspecs"
    fi

    cp -rT "${tmp_dir}/extract" "${ROCRAIL_HOME}/"

    # Make the binary executable. Upstream zips have shipped the
    # rocrail binary at either /bin/rocrail or the install root.
    if [ -f "${ROCRAIL_HOME}/bin/rocrail" ]; then
        chmod +x "${ROCRAIL_HOME}/bin/rocrail"
    elif [ -f "${ROCRAIL_HOME}/rocrail" ]; then
        chmod +x "${ROCRAIL_HOME}/rocrail"
    fi
    find "${ROCRAIL_HOME}" -maxdepth 2 -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

    bin_count=$(find "${ROCRAIL_HOME}" -maxdepth 3 -name "rocrail" -type f | wc -l)
    if [ "${bin_count}" -eq 0 ]; then
        bashio::log.error "No rocrail binary found after extraction"
        rm -rf "${tmp_dir}"
        return 1
    fi

    echo "${rev}" > "${INSTALLED_REV_FILE}"
    rm -rf "${tmp_dir}"
    bashio::log.info "Rocrail r${rev} installed in ${ROCRAIL_HOME}"
    return 0
}

# Low-level: POST a JSON body to a Supervisor proxy endpoint and log
# the response on failure. Returns the curl exit-code via $?, with
# 0 = HTTP 2xx, anything else = error (HTTP body + status code is
# logged at warning level for diagnosis). Previous version piped curl
# stderr to /dev/null which produced opaque "Failed to ..." warnings
# with no way to see what the Supervisor actually returned.
supervisor_post() {
    local path="$1"
    local body="$2"
    local label="${3:-supervisor request}"
    local response http_code body_response

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.debug "SUPERVISOR_TOKEN missing; skipping ${label}"
        return 1
    fi

    response=$(curl -sS -w $'\n%{http_code}' -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "http://supervisor${path}" 2>&1) || true

    http_code=$(printf '%s' "${response}" | tail -n1)
    body_response=$(printf '%s' "${response}" | sed '$d')

    case "${http_code}" in
        2*)
            return 0
            ;;
        *)
            # Supervisor responds with a structured JSON error
            # ({"result":"error","message":"...","error_key":"...",
            # "extra_fields":{...}}). Surface the human-readable
            # "message" on a second log line; fall back to the raw
            # body if the response is not JSON or has no "message".
            local pretty
            pretty=$(printf '%s' "${body_response}" \
                | jq -r '.message // empty' 2>/dev/null)
            bashio::log.warning "${label}: HTTP ${http_code} from ${path}"
            if [ -n "${pretty}" ]; then
                bashio::log.warning "  ${pretty}"
            else
                bashio::log.warning "  ${body_response}"
            fi
            return 1
            ;;
    esac
}

# POST a persistent_notification through HA Core via the Supervisor proxy.
# Requires homeassistant_api: true in config.yaml + SUPERVISOR_TOKEN
# injected by the Supervisor at runtime.
notify_ha() {
    local title="$1"
    local message="$2"
    local nid="${3:-rocrail_addon}"
    local body

    body=$(jq -nc \
        --arg title   "${title}" \
        --arg message "${message}" \
        --arg nid     "${nid}" \
        '{title: $title, message: $message, notification_id: $nid}')

    supervisor_post "/core/api/services/persistent_notification/create" \
        "${body}" "HA persistent_notification (${nid})"
}

# Reset one of the add-on's own options via the Supervisor API. Used
# to turn the check_and_install_rocrail_update toggle back to false
# after a successful update cycle, so it becomes a true one-shot.
#
# We send the FULL options dict (current state + the single override),
# not a partial. Some Supervisor versions reject partial bodies with
# voluptuous schema-validation errors ("required key not provided"),
# and "options" is a full-replace field on the Supervisor side anyway.
reset_addon_option_bool() {
    local key="$1"
    local value="$2"   # "true" or "false"
    local info_resp info_code info_body new_options body

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.debug "SUPERVISOR_TOKEN missing; cannot reset add-on option"
        return 1
    fi

    info_resp=$(curl -sS -w $'\n%{http_code}' \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons/self/info" 2>&1) || true
    info_code=$(printf '%s' "${info_resp}" | tail -n1)
    info_body=$(printf '%s' "${info_resp}" | sed '$d')

    case "${info_code}" in
        2*) ;;
        *)
            bashio::log.warning "reset add-on option '${key}': could not read current options (HTTP ${info_code}): ${info_body}"
            return 1
            ;;
    esac

    # Merge new value into the existing options dict so we send a full,
    # schema-valid POST body.
    new_options=$(printf '%s' "${info_body}" \
        | jq -c --arg k "${key}" --argjson v "${value}" \
            '.data.options | .[$k] = $v')

    if [ -z "${new_options}" ]; then
        bashio::log.warning "reset add-on option '${key}': failed to build new options payload"
        return 1
    fi

    body=$(jq -nc --argjson o "${new_options}" '{options: $o}')

    if supervisor_post "/addons/self/options" \
        "${body}" "reset add-on option '${key}'"; then
        bashio::log.info "Add-on option '${key}' reset to ${value}"
        return 0
    fi
    return 1
}

# ===========================================================
# Rocrail install / update flow
# ===========================================================

DIST=$(detect_arch_dist) || {
    bashio::log.fatal "Unsupported architecture: $(uname -m). Supported: amd64, aarch64."
    exit 1
}

INSTALLED_REV=$(cat "${INSTALLED_REV_FILE}" 2>/dev/null || echo "")
LATEST_REV=""

if [ ! -x "${ROCRAIL_BIN_DIR}/rocrail" ] && [ ! -x "${ROCRAIL_HOME}/rocrail" ]; then
    # First install: no binary on disk yet. We must reach upstream
    # right now or we cannot start the server. Bypass the 24h cache.
    bashio::log.info "First install — fetching Rocrail from rocrail.online"
    bashio::log.info "By starting this add-on you accept the Rocrail license"
    bashio::log.info "(see ${WIKI_LICENCE_URL})."
    if ! LATEST_REV=$(fetch_latest_revision "${DIST}" "true"); then
        bashio::log.fatal "Cannot reach ${UPSTREAM_INDEX_URL} for first install."
        bashio::log.fatal "Check the HA host's internet connection and retry."
        exit 1
    fi
    if ! install_rocrail "${LATEST_REV}" "${DIST}"; then
        bashio::log.fatal "Initial Rocrail install failed; cannot continue."
        exit 1
    fi
    INSTALLED_REV="${LATEST_REV}"

elif bashio::config.true 'check_and_install_rocrail_update'; then
    # User explicitly asked for an update on next start.
    bashio::log.info "User-requested Rocrail update check (force-refresh)"
    if LATEST_REV=$(fetch_latest_revision "${DIST}" "true"); then
        if [ "${LATEST_REV}" != "${INSTALLED_REV}" ]; then
            bashio::log.info "Installing Rocrail r${LATEST_REV} (was r${INSTALLED_REV:-none})"
            if install_rocrail "${LATEST_REV}" "${DIST}"; then
                INSTALLED_REV="${LATEST_REV}"
                rm -f "${LAST_NOTIFIED_FILE}"
                reset_addon_option_bool "check_and_install_rocrail_update" "false" || true
                notify_ha "Rocrail aktualisiert" \
                    "Rocrail r${LATEST_REV} wurde installiert." \
                    "rocrail_update_done" || true
            else
                bashio::log.error "Update failed; keeping installed r${INSTALLED_REV}."
                bashio::log.error "Toggle stays on; will retry on next start."
            fi
        else
            bashio::log.info "Already on the latest Rocrail revision (r${INSTALLED_REV})."
            reset_addon_option_bool "check_and_install_rocrail_update" "false" || true
        fi
    else
        bashio::log.warning "Could not reach ${UPSTREAM_INDEX_URL}; skipping update."
        bashio::log.warning "Toggle stays on; will retry on next start."
    fi

else
    # Normal start: throttled check. If upstream has advanced past the
    # installed rev, notify HA (idempotent by notification_id, and we
    # also suppress repeats once the user has been told about this rev).
    if LATEST_REV=$(fetch_latest_revision "${DIST}" "false"); then
        LAST_NOTIFIED=$(cat "${LAST_NOTIFIED_FILE}" 2>/dev/null || echo "")
        if [ -n "${INSTALLED_REV}" ] && [ "${LATEST_REV}" -gt "${INSTALLED_REV}" ] 2>/dev/null \
           && [ "${LATEST_REV}" != "${LAST_NOTIFIED}" ]; then
            bashio::log.info "Newer Rocrail revision available: r${LATEST_REV} (installed: r${INSTALLED_REV})"
            if notify_ha "Rocrail-Update verfügbar" \
"Rocrail r${LATEST_REV} ist verfügbar (installiert: r${INSTALLED_REV}). \
Aktiviere 'Rocrail-Update prüfen und installieren' in den Add-on-Optionen \
und starte das Add-on neu, um zu aktualisieren." \
                "rocrail_update_available"; then
                echo "${LATEST_REV}" > "${LAST_NOTIFIED_FILE}"
            fi
        fi
    fi
fi

# ===========================================================
# Binary + library path detection (always runs)
# ===========================================================
if [ -x "${ROCRAIL_HOME}/bin/rocrail" ]; then
    ROCRAIL_BIN="${ROCRAIL_HOME}/bin/rocrail"
    ROCRAIL_DIR="${ROCRAIL_HOME}/bin"
elif [ -x "${ROCRAIL_HOME}/rocrail" ]; then
    ROCRAIL_BIN="${ROCRAIL_HOME}/rocrail"
    ROCRAIL_DIR="${ROCRAIL_HOME}"
else
    bashio::log.fatal "rocrail binary not found under ${ROCRAIL_HOME}"
    ls -la "${ROCRAIL_HOME}" >&2 || true
    exit 1
fi

LIB_DIR=""
for candidate in "${ROCRAIL_HOME}" "${ROCRAIL_HOME}/bin" "${ROCRAIL_HOME}/lib"; do
    if ls "${candidate}"/*.so >/dev/null 2>&1; then
        LIB_DIR="${candidate}"
        break
    fi
done
[ -z "${LIB_DIR}" ] && LIB_DIR="${ROCRAIL_DIR}"

REVISION=$(cat "${INSTALLED_REV_FILE}" 2>/dev/null || echo "unknown")

# ===========================================================
# Workspace + share-tree seed (unchanged behaviour, paths only)
# ===========================================================
if [ ! -d "${SHARE_ROOT}" ]; then
    bashio::log.info "Creating fresh ${SHARE_ROOT}/ tree"
fi
mkdir -p "${SHARE_ROOT}/_images"
mkdir -p "${SHARE_ROOT}/_svg"
mkdir -p "${SHARE_ROOT}/_stylesheets"

if [ ! -f "${SHARE_ROOT}/README.txt" ]; then
    cat > "${SHARE_ROOT}/README.txt" <<'EOF'
Rocrail user data
=================

System folders (managed by the add-on, "_" prefix is reserved):

  _images/        Loco and car images (defaults are seeded on first start)
  _svg/           Your own SVG themes; a file here overrides the built-in
                  theme of the same name (first-found-wins)
  _stylesheets/   Your own XSL stylesheets (overlays the built-ins)

File:

  lic.dat         Support Key from rocrail.net (unlocks Rocweb)

Workspaces (your layouts) live directly under /share/rocrail/, e.g.:

  default/        Default workspace (seeded with the demo plan on first start)
  CellarLayout/   Example of your own workspace

Switching workspaces: change the "Workspace" option in the add-on
settings to match a folder name under /share/rocrail/.

Built-in SVG themes (wired into the seeded rocrail.ini):
  - SpDrS60       Classic German signal-box style (default)
  - Accessories   Outputs, labels, level crossings
  - Roads         Roads (for car modules)

Support Key:
  - Variant A: place lic.dat here (/share/rocrail/lic.dat)
  - Variant B: paste the lic.dat contents into the add-on options

Access via the Samba or File Editor add-on.
Rocview/andRoc connection: homeassistant.local:8051
EOF
fi

# Seed default images / stylesheets from the installed Rocrail tree.
# `cp -n` skips existing files so user customisations survive. We log
# the file-count delta so it's visible in the add-on log what (if
# anything) was actually added — previously this block was silent and
# made fresh installs look like seeding never happened.
seed_count() {
    # arg1: dir, returns number of regular files (0 if dir missing).
    [ -d "$1" ] && find "$1" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0
}

if [ -d "${ROCRAIL_HOME}/images" ]; then
    before=$(seed_count "${SHARE_ROOT}/_images")
    cp -n "${ROCRAIL_HOME}/images/"*.png "${SHARE_ROOT}/_images/" 2>/dev/null || true
    cp -n "${ROCRAIL_HOME}/images/"*.gif "${SHARE_ROOT}/_images/" 2>/dev/null || true
    cp -n "${ROCRAIL_HOME}/images/"*.jpg "${SHARE_ROOT}/_images/" 2>/dev/null || true
    after=$(seed_count "${SHARE_ROOT}/_images")
    if [ "${after}" -gt "${before}" ]; then
        bashio::log.info "Seeded $((after - before)) default image(s) into ${SHARE_ROOT}/_images/"
    fi
else
    bashio::log.warning "${ROCRAIL_HOME}/images/ missing - default loco/car images not seeded"
fi

if [ -d "${ROCRAIL_HOME}/stylesheets" ]; then
    before=$(seed_count "${SHARE_ROOT}/_stylesheets")
    cp -rn "${ROCRAIL_HOME}/stylesheets/"* "${SHARE_ROOT}/_stylesheets/" 2>/dev/null || true
    after=$(seed_count "${SHARE_ROOT}/_stylesheets")
    if [ "${after}" -gt "${before}" ]; then
        bashio::log.info "Seeded $((after - before)) default stylesheet(s) into ${SHARE_ROOT}/_stylesheets/"
    fi
else
    bashio::log.warning "${ROCRAIL_HOME}/stylesheets/ missing - default XSL stylesheets not seeded"
fi

# ----- Workspace directory -----
WS_DIR="${SHARE_ROOT}/${WORKSPACE}"
mkdir -p "${WS_DIR}/trace"

if [ -z "$(ls -A "${WS_DIR}" 2>/dev/null | grep -vE '^trace$')" ]; then
    bashio::log.info "Workspace '${WORKSPACE}' empty - seeding from demo plan"
    cp -r "${ROCRAIL_HOME}/demo/"* "${WS_DIR}/" 2>/dev/null || \
        bashio::log.warning "Demo plan not found at ${ROCRAIL_HOME}/demo/"
    # Drop the demo's bundled rocrail.ini so our own seed below (with
    # HA-friendly paths) takes over.
    rm -f "${WS_DIR}/rocrail.ini"
fi

# ============================================================
# Support Key lookup
# ============================================================
KEY_PATH=""
KEY_SOURCE_DESC=""
INLINE_TMP="/tmp/lic-inline.dat"

if [ -n "${SUPPORT_KEY_INLINE}" ]; then
    printf '%s\n' "${SUPPORT_KEY_INLINE}" > "${INLINE_TMP}"
    INLINE_SIZE=$(wc -c < "${INLINE_TMP}")
    if [ "${INLINE_SIZE}" -ge "${MIN_KEY_SIZE}" ]; then
        KEY_PATH="${INLINE_TMP}"
        KEY_SOURCE_DESC="UI option (${INLINE_SIZE}b)"
    else
        bashio::log.warning "UI Support Key looks too short (${INLINE_SIZE}b < ${MIN_KEY_SIZE}b) - ignoring"
        rm -f "${INLINE_TMP}"
    fi
fi

if [ -z "${KEY_PATH}" ] && [ -f "${SHARE_ROOT}/lic.dat" ]; then
    SHARE_SIZE=$(wc -c < "${SHARE_ROOT}/lic.dat")
    if [ "${SHARE_SIZE}" -ge "${MIN_KEY_SIZE}" ]; then
        KEY_PATH="${SHARE_ROOT}/lic.dat"
        KEY_SOURCE_DESC="${SHARE_ROOT}/lic.dat (${SHARE_SIZE}b)"
    else
        bashio::log.warning "${SHARE_ROOT}/lic.dat looks too short (${SHARE_SIZE}b) - ignoring"
    fi
fi

# ============================================================
# Seed rocrail.ini ONLY if missing
# ============================================================
RR_INI="${WS_DIR}/rocrail.ini"
if [ ! -f "${RR_INI}" ]; then
    bashio::log.info "Seeding new rocrail.ini at ${RR_INI}"
    DEBUG_BOOL="false"
    case "${LOG_LEVEL}" in
        debug|trace) DEBUG_BOOL="true" ;;
    esac

    cat > "${RR_INI}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rocrail planfile="plan.xml"
         backuppath="backup"
         imgpath="${SHARE_ROOT}/_images"
         libpath="${LIB_DIR}"
         stylesheetpath="${SHARE_ROOT}/_stylesheets"
         keypath="lic.dat"
         maxbackup="100"
         backup="true"
         shutdownonexit="true">
  <trace rfile="rocrail"
         protpath="trace"
         nr="3"
         size="100"
         debug="${DEBUG_BOOL}"
         byte="false"
         parse="false"
         meminfo="false"
         routing="false"
         develop="false"
         ctc="false"
         automatic="false"
         info="false"
         calc="true"/>
  <digint lib="virtual"
          iid="vcs-1"
          onthefly="false"
          stress="false"
          supportkey="true"
          desc="Default virtual Command Station (HA Add-on seed)"/>
  <http port="8008">
    <webclient port="${ROCWEB_PORT}"
               webpath="${ROCRAIL_HOME}/web"
               imgpath="${SHARE_ROOT}/_images"
               svgpath1="${SHARE_ROOT}/_svg"
               svgpath2="${ROCRAIL_HOME}/svg/themes/SpDrS60"
               svgpath3="${ROCRAIL_HOME}/svg/themes/Accessories"
               svgpath4="${ROCRAIL_HOME}/svg/themes/Roads"/>
  </http>
</rocrail>
EOF
else
    bashio::log.info "Existing rocrail.ini found at ${RR_INI} - leaving Rocrail-managed"
    if grep -qF 'backuppath="/backup/rocrail"' "${RR_INI}"; then
        bashio::log.notice "Migrating legacy backuppath in ${RR_INI}: /backup/rocrail -> backup"
        OLD='backuppath="/backup/rocrail"' \
        NEW='backuppath="backup"' \
        awk 'BEGIN{old=ENVIRON["OLD"]; new=ENVIRON["NEW"]} {gsub(old,new); print}' \
            "${RR_INI}" > "${RR_INI}.tmp" && mv "${RR_INI}.tmp" "${RR_INI}"
        if grep -qF 'backuppath="backup"' "${RR_INI}"; then
            bashio::log.info "backuppath migrated"
        else
            bashio::log.warning "backuppath migration verification failed - check ${RR_INI} manually"
        fi
    fi

    # 1.x -> 2.x path migration. Pre-2.0.0 add-ons baked Rocrail into
    # /opt/rocrail/; the seeded rocrail.ini referenced webpath, libpath
    # and svgpath2..4 under that prefix. With runtime-fetched Rocrail
    # under /data/rocrail/, those paths return 404 (the user-visible
    # symptom was Rocweb logging "file [/opt/rocrail/web/index.html]
    # not found" on every connect).
    #
    # Strategy: any "/opt/rocrail" prefix in the ini is rewritten to
    # "${ROCRAIL_HOME}". Idempotent: re-running matches nothing.
    if grep -qF '"/opt/rocrail' "${RR_INI}"; then
        bashio::log.notice "Migrating legacy /opt/rocrail/* paths in ${RR_INI} -> ${ROCRAIL_HOME}/*"
        OLD='/opt/rocrail' \
        NEW="${ROCRAIL_HOME}" \
        awk 'BEGIN{old=ENVIRON["OLD"]; new=ENVIRON["NEW"]} {gsub(old,new); print}' \
            "${RR_INI}" > "${RR_INI}.tmp" && mv "${RR_INI}.tmp" "${RR_INI}"
        if grep -qF '"/opt/rocrail' "${RR_INI}"; then
            bashio::log.warning "/opt/rocrail path migration verification failed - check ${RR_INI} manually"
        else
            bashio::log.info "/opt/rocrail/* paths migrated to ${ROCRAIL_HOME}/*"
        fi
    fi
fi

# ----- Patch Rocweb worker for HA Ingress (idempotent) -----
# Same four-state detector as before; only the path moves from
# /opt/rocrail/web to /data/rocrail/web. awk+ENVIRON is mandatory:
# sed strips backslashes in the replacement and produces a JS line
# comment (//), silently killing the WebSocket constructor.
ROCWEB_WORKER="${ROCRAIL_HOME}/web/rocwebworker.js"

if [ -f "${ROCWEB_WORKER}" ]; then
    if grep -qF 'ws = new WebSocket(proto+"//"+host+":"+location.port, "rcp");' "${ROCWEB_WORKER}"; then
        ROCWEB_STATE="original"
    elif grep -qF 'location.pathname.replace(/\/[^/]*$/,' "${ROCWEB_WORKER}"; then
        ROCWEB_STATE="patched"
    elif grep -qF 'location.pathname.replace(//[^/]*$/,' "${ROCWEB_WORKER}"; then
        ROCWEB_STATE="broken"
    else
        ROCWEB_STATE="unknown"
    fi

    case "${ROCWEB_STATE}" in
        original)
            bashio::log.info "Patching ${ROCWEB_WORKER} for HA-Ingress WebSocket routing"
            ;;
        patched)
            bashio::log.info "rocwebworker.js already patched"
            ;;
        broken)
            bashio::log.warning "rocwebworker.js has broken patch (// instead of \\/) - healing"
            ;;
        unknown)
            bashio::log.warning "rocwebworker.js: WebSocket pattern not recognized - upstream Rocrail may have changed it. Live-Updates may not work."
            ;;
    esac

    if [ "${ROCWEB_STATE}" = "original" ] || [ "${ROCWEB_STATE}" = "broken" ]; then
        export ROCWEB_PATCH='  ws = new WebSocket(proto+"//"+location.host+location.pathname.replace(/\/[^/]*$/,"/"), "rcp");'
        awk '
            /^[[:space:]]*ws = new WebSocket\(proto\+"\/\/"\+/ {
                print ENVIRON["ROCWEB_PATCH"]
                next
            }
            { print }
        ' "${ROCWEB_WORKER}" > "${ROCWEB_WORKER}.tmp" \
            && mv "${ROCWEB_WORKER}.tmp" "${ROCWEB_WORKER}"
        unset ROCWEB_PATCH
    fi
else
    bashio::log.warning "${ROCWEB_WORKER} not found"
fi

# ----- Banner -----
bashio::log.info "================================================="
bashio::log.info " Rocrail Add-on starting"
bashio::log.info " Add-on:       v${ADDON_VERSION}"
bashio::log.info " Rocrail:      r${REVISION} (${DIST})"
bashio::log.info " Binary:       ${ROCRAIL_BIN}"
bashio::log.info " Lib dir:      ${LIB_DIR}"
bashio::log.info " Workspace:    ${WS_DIR}"
bashio::log.info " Client Port:  ${CLIENT_PORT}"
bashio::log.info " Rocweb Port:  ${ROCWEB_PORT}"
if [ -n "${KEY_PATH}" ]; then
    bashio::log.info " SupportKey:   ${KEY_PATH}"
    bashio::log.info "  (source:     ${KEY_SOURCE_DESC})"
else
    bashio::log.info " SupportKey:   (none - Rocweb runs in 5min demo mode)"
fi
bashio::log.info "================================================="

if [ -d "${ROCRAIL_HOME}/svg/themes" ]; then
    bashio::log.info "Available SVG themes:"
    for theme in "${ROCRAIL_HOME}/svg/themes/"*/; do
        bashio::log.info "  - $(basename "${theme}")"
    done
fi

# ----- Hassio discovery -----
if ! bashio::services.available "rocrail" 2>/dev/null; then
    bashio::discovery "rocrail" \
        "{\"host\":\"${HOSTNAME}\",\"port\":${CLIENT_PORT}}" \
        > /dev/null 2>&1 || true
fi

# ----- Start Rocrail -----
cd "${WS_DIR}"

DEBUG_FLAG=""
case "${LOG_LEVEL}" in
    debug|trace) DEBUG_FLAG="-debug" ;;
esac

bashio::log.info "Starting Rocrail server..."
bashio::log.info "  Workspace dir:    ${WS_DIR}"
bashio::log.info "  Listening on:     0.0.0.0:${CLIENT_PORT} (Client Protocol)"
bashio::log.info "  Rocweb on:        0.0.0.0:${ROCWEB_PORT} (Ingress)"

# ----- Graceful shutdown handler -----
# The total shutdown budget must stay UNDER the Supervisor's ~10s docker-stop
# grace period. Otherwise the Supervisor SIGKILLs the whole container (exit 137)
# before our own `exit 0` runs, and HA flags the add-on as errored / "not stopped
# cleanly". A clean Rocrail shutdown saves the plan within ~1.5s but then idles
# ~15s in a track power-off delay (irrelevant in a container) — we do not wait
# that out. The clean plan-save is the user's job via Rocview/Rocweb before stop.
SHUTDOWN_EXIT_TIMEOUT=7

wait_for_rocrail_exit() {
    local timeout="${1:-30}"
    local waited=0
    while kill -0 "${ROCRAIL_PID}" 2>/dev/null && [ "${waited}" -lt "${timeout}" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "${ROCRAIL_PID}" 2>/dev/null; then
        bashio::log.warning "Rocrail still running after ${waited}s - sending SIGKILL"
        kill -KILL "${ROCRAIL_PID}" 2>/dev/null || true
    else
        bashio::log.info "Rocrail exited cleanly after ${waited}s"
    fi
}

shutdown_handler() {
    bashio::log.notice "Received termination signal - forwarding SIGTERM to Rocrail"
    if kill -TERM "${ROCRAIL_PID}" 2>/dev/null; then
        # NOTE: SIGTERM does NOT guarantee a clean Rocrail plan-save. For an
        # unsaved plan, shut down via Rocview/Rocweb before stopping the add-on.
        bashio::log.info "SIGTERM sent to Rocrail (PID ${ROCRAIL_PID}) - stopping"
    fi
    wait_for_rocrail_exit "${SHUTDOWN_EXIT_TIMEOUT}"
    exit 0
}

trap shutdown_handler TERM INT

if [ -n "${KEY_PATH}" ]; then
    "${ROCRAIL_BIN}" \
        -w "${WS_DIR}" \
        -l "${LIB_DIR}" \
        -img "${SHARE_ROOT}/_images" \
        -p "${CLIENT_PORT}" \
        -lic "${KEY_PATH}" \
        ${DEBUG_FLAG} &
else
    "${ROCRAIL_BIN}" \
        -w "${WS_DIR}" \
        -l "${LIB_DIR}" \
        -img "${SHARE_ROOT}/_images" \
        -p "${CLIENT_PORT}" \
        ${DEBUG_FLAG} &
fi
ROCRAIL_PID=$!

wait "${ROCRAIL_PID}"
