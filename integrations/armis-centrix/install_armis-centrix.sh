#!/usr/bin/env bash
# install_armis-centrix.sh — One-command installer for Armis Centrix → Veza OAA integration
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/pvolu-vz/ArmisAppOaa.git}"
BRANCH="${BRANCH:-main}"
INTEGRATION_SUBDIR="integrations/armis-centrix"
INSTALL_BASE="${INSTALL_DIR:-/opt/VEZA}"
INSTALL_DIR_NAME="armis-centrix-veza"
SCRIPTS_DIR="${INSTALL_BASE}/${INSTALL_DIR_NAME}/scripts"
LOGS_DIR="${INSTALL_BASE}/${INSTALL_DIR_NAME}/logs"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
OVERWRITE_ENV="${OVERWRITE_ENV:-false}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
die()   { echo -e "${RED}✗${NC}  ERROR: $*" >&2; exit 1; }

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --overwrite-env)   OVERWRITE_ENV=true;   shift ;;
        --install-dir)     INSTALL_BASE="$2"; SCRIPTS_DIR="${INSTALL_BASE}/${INSTALL_DIR_NAME}/scripts"; LOGS_DIR="${INSTALL_BASE}/${INSTALL_DIR_NAME}/logs"; shift 2 ;;
        --repo-url)        REPO_URL="$2";        shift 2 ;;
        --branch)          BRANCH="$2";          shift 2 ;;
        *) die "Unknown flag: $1" ;;
    esac
done

# ── OS detection ──────────────────────────────────────────────────────────────
OS_ID="linux"
PKG_MGR=""
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_ID="$(. /etc/os-release && echo "${ID:-linux}")"
fi

if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
fi

# ── Package installer helper ─────────────────────────────────────────────────
_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg}…"
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null || warn "Could not install ${pkg}" ;;
        apt-get) apt-get install -y "${pkg}" >/dev/null 2>&1 || warn "Could not install ${pkg}" ;;
        *) warn "No supported package manager found; please install ${pkg} manually" ;;
    esac
}

# ── System prerequisites ──────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Armis Centrix → Veza OAA Installer ===${NC}\n"

# Python
command -v python3 &>/dev/null || _install_pkg python3
python3 --version &>/dev/null || die "python3 not found after install"

# Check Python >= 3.8
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" \
    || die "Python 3.8+ required. Found: $(python3 --version)"
ok "Python: $(python3 --version)"

# pip
python3 -m pip --version &>/dev/null || _install_pkg python3-pip

# git
command -v git &>/dev/null || _install_pkg git

# curl
if ! command -v curl &>/dev/null; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict)"
    else
        _install_pkg curl
    fi
fi

# venv
if ! python3 -m venv --help &>/dev/null; then
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
        *) warn "Cannot install python venv — please install it manually" ;;
    esac
fi

# ── Clone repository ──────────────────────────────────────────────────────────
info "Cloning integration files from ${REPO_URL} (branch: ${BRANCH})…"
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

GIT_TERMINAL_PROMPT=0 git clone \
    --branch "${BRANCH}" --depth 1 --single-branch \
    "${REPO_URL}" "${tmp_dir}" \
    || die "git clone failed. Check REPO_URL and network connectivity."

# ── Create directory layout ───────────────────────────────────────────────────
info "Creating install directories…"
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"

cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/armis-centrix.py"    "${SCRIPTS_DIR}/"
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/requirements.txt"   "${SCRIPTS_DIR}/"
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/preflight.sh"       "${SCRIPTS_DIR}/" 2>/dev/null || true
chmod +x "${SCRIPTS_DIR}/armis-centrix.py" "${SCRIPTS_DIR}/preflight.sh" 2>/dev/null || true
ok "Files installed to ${SCRIPTS_DIR}"

# ── Python virtual environment ────────────────────────────────────────────────
info "Creating Python virtual environment…"
python3 -m venv "${SCRIPTS_DIR}/venv"
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt"
ok "Dependencies installed"

# ── Generate .env ─────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPTS_DIR}/.env"
if [[ -f "${ENV_FILE}" && "${OVERWRITE_ENV}" != "true" ]]; then
    warn ".env already exists — skipping (use --overwrite-env to replace)"
else
    info "Generating .env file…"

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        # CI/non-interactive: read from environment variables
        ARMIS_TENANT="${ARMIS_TENANT:-}"
        ARMIS_SECRET_KEY="${ARMIS_SECRET_KEY:-}"
        VEZA_URL="${VEZA_URL:-}"
        VEZA_API_KEY="${VEZA_API_KEY:-}"
        [[ -z "${ARMIS_TENANT}" ]]     && warn "ARMIS_TENANT not set"
        [[ -z "${ARMIS_SECRET_KEY}" ]] && warn "ARMIS_SECRET_KEY not set"
        [[ -z "${VEZA_URL}" ]]         && warn "VEZA_URL not set"
        [[ -z "${VEZA_API_KEY}" ]]     && warn "VEZA_API_KEY not set"
    else
        # Interactive: prompt via /dev/tty
        IFS= read -r  -p "Armis tenant subdomain (e.g. demo-veza): "        ARMIS_TENANT     </dev/tty
        IFS= read -rs -p "Armis secret key: "                                ARMIS_SECRET_KEY </dev/tty; echo >/dev/tty
        IFS= read -r  -p "Veza URL (e.g. https://company.vezacloud.com): "  VEZA_URL         </dev/tty
        IFS= read -rs -p "Veza API key: "                                    VEZA_API_KEY     </dev/tty; echo >/dev/tty
    fi

    cat > "${ENV_FILE}" <<EOF
# Armis Centrix Source Configuration
ARMIS_TENANT=${ARMIS_TENANT}
ARMIS_SECRET_KEY=${ARMIS_SECRET_KEY}

# Veza Configuration
VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

# OAA Provider Settings (optional)
# PROVIDER_NAME=Armis
# DATASOURCE_NAME=Armis Centrix
EOF
    chmod 600 "${ENV_FILE}"
    ok ".env created at ${ENV_FILE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo -e "  Install path:   ${SCRIPTS_DIR}"
echo -e "  Logs directory: ${LOGS_DIR}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Review/edit ${ENV_FILE}"
echo "  2. Run a dry-run to validate:"
echo "     cd ${SCRIPTS_DIR}"
echo "     ./venv/bin/python3 armis-centrix.py --dry-run --save-json"
echo "  3. When ready, push to Veza:"
echo "     ./venv/bin/python3 armis-centrix.py --save-json"
