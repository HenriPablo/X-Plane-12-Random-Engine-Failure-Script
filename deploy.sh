#!/usr/bin/env bash
# Linux/macOS deployment helper for the Random Engine Failure script.
# Mirrors deploy.ps1.
#
# Usage:
#   ./deploy.sh                                 # defaults (~/X-Plane 12)
#   ./deploy.sh --xplane-path "/games/X-Plane 12"
#   ./deploy.sh --script-name random_engine_out.lua
#   ./deploy.sh --dry-run                       # show actions, change nothing
#   ./deploy.sh --force                         # overwrite without a .bak backup
set -euo pipefail

XPLANE_PATH="${HOME}/X-Plane 12"
SCRIPT_NAME="random_engine_out.lua"
FORCE=0
DRY_RUN=0
SELF_TEST=0

info() { printf '[deploy] %s\n' "$1"; }
warn() { printf '[deploy] WARN: %s\n' "$1" >&2; }
err()  { printf '[deploy] ERROR: %s\n' "$1" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xplane-path) XPLANE_PATH="$2"; shift 2 ;;
        --script-name) SCRIPT_NAME="$2"; shift 2 ;;
        --self-test) SELF_TEST=1; shift ;;
        --force)       FORCE=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# Resolve paths
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PATH="${PROJECT_ROOT}/src/main.lua"
SRC_MODULES_DIR="${PROJECT_ROOT}/src/modules"
FWL_PATH="${XPLANE_PATH}/Resources/plugins/FlyWithLua"
TARGET_DIR="${FWL_PATH}/Scripts"
TARGET_PATH="${TARGET_DIR}/${SCRIPT_NAME}"
MODULES_TARGET_DIR="${FWL_PATH}/Modules"

info "Project root: ${PROJECT_ROOT}"
info "Source script: ${SRC_PATH}"
info "X-Plane path: ${XPLANE_PATH}"
info "Target dir: ${TARGET_DIR}"
info "Target file: ${TARGET_PATH}"

if [[ ! -f "${SRC_PATH}" ]]; then
    err "Source script not found at ${SRC_PATH}"
    exit 1
fi

if [[ ! -d "${XPLANE_PATH}" ]]; then
    err "X-Plane path not found: ${XPLANE_PATH}"
    echo "  Tip: Use --xplane-path '/games/X-Plane 12' or your actual install path."
    exit 1
fi

if [[ ! -d "${FWL_PATH}" ]]; then
    warn "FlyWithLua plugin folder not found at ${FWL_PATH}"
    warn "Will still create target Scripts folder so you can copy after installing FlyWithLua."
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "Dry run enabled. No changes will be made."
fi

# Ensure target directory exists
if [[ ! -d "${TARGET_DIR}" ]]; then
    info "Creating directory: ${TARGET_DIR}"
    [[ "${DRY_RUN}" -eq 0 ]] && mkdir -p "${TARGET_DIR}"
fi

# Backup existing target file
if [[ -f "${TARGET_PATH}" ]]; then
    if [[ "${FORCE}" -eq 1 ]]; then
        info "Force enabled: existing file will be overwritten without backup."
    else
        TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
        BACKUP_PATH="${TARGET_PATH}.bak.${TIMESTAMP}"
        info "Backing up existing file to ${BACKUP_PATH}"
        [[ "${DRY_RUN}" -eq 0 ]] && cp -f "${TARGET_PATH}" "${BACKUP_PATH}"
    fi
fi

# Copy source to target
if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "Would copy ${SRC_PATH} -> ${TARGET_PATH}"
else
    info "Copying ${SRC_PATH} -> ${TARGET_PATH}"
    cp -f "${SRC_PATH}" "${TARGET_PATH}"
fi

# Copy the modules the main script requires. Without these it logs a FATAL and
# refuses to arm, so they are not optional.
if [[ -d "${SRC_MODULES_DIR}" ]]; then
    if [[ ! -d "${MODULES_TARGET_DIR}" ]]; then
        info "Creating directory: ${MODULES_TARGET_DIR}"
        [[ "${DRY_RUN}" -eq 0 ]] && mkdir -p "${MODULES_TARGET_DIR}"
    fi
    for mod in "${SRC_MODULES_DIR}"/*.lua; do
        [[ -f "${mod}" ]] || continue
        MOD_NAME="$(basename "${mod}")"
        MOD_TARGET="${MODULES_TARGET_DIR}/${MOD_NAME}"
        if [[ -f "${MOD_TARGET}" && "${FORCE}" -eq 0 ]]; then
            TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
            info "Backing up existing module to ${MOD_TARGET}.bak.${TIMESTAMP}"
            [[ "${DRY_RUN}" -eq 0 ]] && cp -f "${MOD_TARGET}" "${MOD_TARGET}.bak.${TIMESTAMP}"
        fi
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            info "Would copy module ${MOD_NAME} -> ${MOD_TARGET}"
        else
            info "Copying module ${MOD_NAME} -> ${MOD_TARGET}"
            cp -f "${mod}" "${MOD_TARGET}"
        fi
    done
else
    warn "No modules directory at ${SRC_MODULES_DIR} - the script will not run without it."
fi

# Opt-in self-test: runs once at load and writes a PASS/FAIL block to Log.txt.
# Off by default so it never runs during real practice; delete
# Scripts/reo_selftest.lua to remove it.
if [[ "${SELF_TEST}" -eq 1 ]]; then
    SELF_TEST_SRC="${PROJECT_ROOT}/src/selftest/reo_selftest.lua"
    SELF_TEST_TARGET="${TARGET_DIR}/reo_selftest.lua"
    if [[ -f "${SELF_TEST_SRC}" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            info "Would copy self-test reo_selftest.lua -> ${SELF_TEST_TARGET}"
        else
            info "Copying self-test reo_selftest.lua -> ${SELF_TEST_TARGET}"
            cp -f "${SELF_TEST_SRC}" "${SELF_TEST_TARGET}"
        fi
    else
        warn "No self-test found at ${SELF_TEST_SRC}"
    fi
fi

echo ""
echo "Deployment complete."
if [[ "${DRY_RUN}" -eq 1 || -f "${TARGET_PATH}" ]]; then
    echo "Installed script name: ${SCRIPT_NAME}"
    echo "Location: ${TARGET_DIR}"
    echo "Modules: ${MODULES_TARGET_DIR}"
fi

echo ""
echo "Next steps:"
echo "  1) Start X-Plane (or Reload All Lua Scripts from FlyWithLua menu)."
echo "  2) Load a multi-engine aircraft."
echo "  3) Check Log.txt for 'Random Engine Failure script loaded successfully!' and subsequent schedule/trigger logs."
