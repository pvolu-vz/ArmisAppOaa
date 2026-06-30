#!/usr/bin/env bash
# preflight.sh — Pre-flight validation for Armis Centrix → Veza OAA integration
# Run before deploying armis-centrix.py to confirm all prerequisites are met.
#
# Usage:
#   ./preflight.sh          — interactive menu
#   ./preflight.sh --all    — run all checks non-interactively (CI mode)
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
ENV_FILE="${SCRIPT_DIR}/.env"
MAIN_SCRIPT="${SCRIPT_DIR}/armis-centrix.py"
VENV_DIR="${SCRIPT_DIR}/venv"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"

# ── Colors & counters ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'
TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0

print_success() { local msg="$1"; echo -e "${GREEN}✓${NC} ${msg}"; echo "[PASS] ${msg}" >> "${LOG_FILE}"; ((TESTS_PASSED++)); }
print_fail()    { local msg="$1"; echo -e "${RED}✗${NC} ${msg}";   echo "[FAIL] ${msg}" >> "${LOG_FILE}"; ((TESTS_FAILED++)); }
print_warning() { local msg="$1"; echo -e "${YELLOW}⚠${NC} ${msg}"; echo "[WARN] ${msg}" >> "${LOG_FILE}"; ((TESTS_WARNING++)); }
print_info()    { local msg="$1"; echo -e "${BLUE}ℹ${NC} ${msg}";  echo "[INFO] ${msg}" >> "${LOG_FILE}"; }
print_header()  { echo -e "\n${BOLD}── $* ──${NC}"; echo "=== $* ===" >> "${LOG_FILE}"; }

# ── Python binary (prefer local venv) ─────────────────────────────────────────
PYTHON_BIN="python3"
[[ -x "${VENV_DIR}/bin/python" ]] && PYTHON_BIN="${VENV_DIR}/bin/python"
[[ -x "${VENV_DIR}/bin/python3" ]] && PYTHON_BIN="${VENV_DIR}/bin/python3"

# ── Helper: check env var ─────────────────────────────────────────────────────
check_env_var() {
    local var_name=$1 var_value=$2 optional=${3:-required}
    if [[ -z "${var_value}" ]]; then
        if [[ "${optional}" == "optional" ]]; then
            print_info "${var_name} not set (optional)"
        else
            print_fail "${var_name} is not set"
        fi
    elif [[ "${var_value}" =~ ^your_.* ]]; then
        print_warning "${var_name} contains placeholder value"
    elif [[ "${var_value}" =~ ^https://your-.* ]]; then
        print_warning "${var_name} contains placeholder URL"
    else
        if [[ "${var_name}" =~ PASSWORD|KEY|TOKEN|SECRET ]]; then
            print_success "${var_name} set (${var_value:0:8}...)"
        else
            print_success "${var_name} = ${var_value}"
        fi
    fi
}

# ── Section 1: System Requirements ───────────────────────────────────────────
check_system_requirements() {
    print_header "1 — System Requirements"

    # Python version
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print('.'.join(map(str,sys.version_info[:3])))")
        if python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)" 2>/dev/null; then
            print_success "Python ${PY_VER} (>= 3.9)"
        else
            print_fail "Python ${PY_VER} installed — 3.9+ required"
        fi
    else
        print_fail "python3 not found"
    fi

    # pip
    if command -v pip3 &>/dev/null || "${PYTHON_BIN}" -m pip --version &>/dev/null 2>&1; then
        print_success "pip available"
    else
        print_fail "pip3 not found"
    fi

    # venv module
    if python3 -m venv --help &>/dev/null 2>&1; then
        print_success "python3 venv module available"
    else
        print_warning "python3-venv not available — install python3-venv or python3-virtualenv"
    fi

    # OS detection
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
        print_info "OS: ${OS_NAME}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        print_info "OS: macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
    fi

    # curl (needed for API auth tests)
    if command -v curl &>/dev/null; then
        print_success "curl $(curl --version | head -1 | awk '{print $2}')"
    else
        print_fail "curl not found — required for API connectivity tests"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        print_success "jq $(jq --version)"
    else
        print_warning "jq not found (optional — install for formatted JSON output)"
    fi
}

# ── Section 2: Python Dependencies ───────────────────────────────────────────
check_python_dependencies() {
    print_header "2 — Python Dependencies"

    if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
        print_fail "requirements.txt not found at ${REQUIREMENTS_FILE}"
        return
    fi

    print_info "Using Python: ${PYTHON_BIN}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip comments and version specifiers for import check
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        pkg=$(echo "${line}" | sed 's/[>=<!\[].*//' | tr -d ' ')
        # Map package name to import name
        import_name="${pkg//-/_}"
        case "${pkg}" in
            oaaclient)       import_name="oaaclient" ;;
            python-dotenv)   import_name="dotenv" ;;
            urllib3)         import_name="urllib3" ;;
        esac
        if "${PYTHON_BIN}" -c "import ${import_name}; print(getattr(__import__('${import_name}'), '__version__', 'ok'))" 2>/dev/null; then
            ver=$("${PYTHON_BIN}" -c "import ${import_name}; print(getattr(__import__('${import_name}'), '__version__', 'installed'))" 2>/dev/null)
            print_success "${pkg} (${ver})"
        else
            print_fail "${pkg} not installed — run: ${VENV_DIR}/bin/pip install -r ${REQUIREMENTS_FILE}"
        fi
    done < "${REQUIREMENTS_FILE}"
}

# ── Section 3: Configuration File ────────────────────────────────────────────
check_configuration() {
    print_header "3 — Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env not found at ${ENV_FILE} — run option 10 to generate a template"
        return
    fi
    print_success ".env exists at ${ENV_FILE}"

    # Check permissions
    perms=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%OLp" "${ENV_FILE}" 2>/dev/null)
    if [[ "${perms}" == "600" ]]; then
        print_success ".env permissions: 600"
    else
        print_warning ".env permissions: ${perms} (should be 600 — run: chmod 600 ${ENV_FILE})"
    fi

    # Source and validate
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a

    check_env_var "ARMIS_TENANT"     "${ARMIS_TENANT:-}"
    check_env_var "ARMIS_SECRET_KEY" "${ARMIS_SECRET_KEY:-}"
    check_env_var "VEZA_URL"         "${VEZA_URL:-}"
    check_env_var "VEZA_API_KEY"     "${VEZA_API_KEY:-}"
    check_env_var "PROVIDER_NAME"    "${PROVIDER_NAME:-}"    "optional"
    check_env_var "DATASOURCE_NAME"  "${DATASOURCE_NAME:-}"  "optional"
}

# ── Section 4: Network Connectivity ──────────────────────────────────────────
check_network_connectivity() {
    print_header "4 — Network Connectivity"

    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a

    # Armis API endpoint
    if [[ -n "${ARMIS_TENANT:-}" ]]; then
        ARMIS_HOST="${ARMIS_TENANT}.armis.com"
        print_info "Testing HTTPS to ${ARMIS_HOST}…"
        result=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "https://${ARMIS_HOST}/api/v1/" 2>/dev/null)
        http_code="${result%%|*}"; latency="${result##*|}"
        if [[ "${http_code}" =~ ^[23] ]]; then
            print_success "Armis API reachable (HTTP ${http_code}, ${latency}s)"
        elif [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
            print_success "Armis API reachable — auth required (HTTP ${http_code}, ${latency}s)"
        else
            print_fail "Armis API unreachable (HTTP ${http_code}) at https://${ARMIS_HOST}"
        fi
    else
        print_warning "ARMIS_TENANT not set — skipping Armis connectivity test"
    fi

    # Veza endpoint
    if [[ -n "${VEZA_URL:-}" ]]; then
        VEZA_HOST="${VEZA_URL#https://}"; VEZA_HOST="${VEZA_HOST%%/*}"
        print_info "Testing HTTPS to ${VEZA_HOST}…"
        result=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "${VEZA_URL}/api/v1/" 2>/dev/null)
        http_code="${result%%|*}"; latency="${result##*|}"
        if [[ "${http_code}" =~ ^[234] ]]; then
            print_success "Veza reachable (HTTP ${http_code}, ${latency}s)"
        else
            print_fail "Veza unreachable (HTTP ${http_code}) at ${VEZA_URL}"
        fi
    else
        print_warning "VEZA_URL not set — skipping Veza connectivity test"
    fi
}

# ── Section 5: API Authentication ─────────────────────────────────────────────
check_api_authentication() {
    print_header "5 — API Authentication"

    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a

    # Armis auth test
    if [[ -n "${ARMIS_TENANT:-}" && -n "${ARMIS_SECRET_KEY:-}" ]]; then
        print_info "[DEBUG] POST https://${ARMIS_TENANT}.armis.com/api/v1/access_token/ (secret_key=***)"
        auth_resp=$(curl -s -o /tmp/armis_auth_resp.json -w "%{http_code}" -m 15 \
            -X POST "https://${ARMIS_TENANT}.armis.com/api/v1/access_token/" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "secret_key=${ARMIS_SECRET_KEY}" 2>/dev/null)
        if [[ "${auth_resp}" == "200" ]]; then
            if command -v jq &>/dev/null; then
                success=$(jq -r '.success' /tmp/armis_auth_resp.json 2>/dev/null)
            else
                success=$(python3 -c "import json,sys; d=json.load(open('/tmp/armis_auth_resp.json')); print(d.get('success',''))" 2>/dev/null)
            fi
            if [[ "${success}" == "true" ]]; then
                print_success "Armis authentication successful (HTTP 200)"
            else
                print_fail "Armis API returned 200 but success=false — check secret key"
            fi
        else
            print_fail "Armis authentication failed (HTTP ${auth_resp})"
            cat /tmp/armis_auth_resp.json 2>/dev/null | head -5
        fi
    else
        print_warning "ARMIS_TENANT or ARMIS_SECRET_KEY not set — skipping Armis auth test"
    fi

    # Veza auth test
    if [[ -n "${VEZA_URL:-}" && -n "${VEZA_API_KEY:-}" ]]; then
        print_info "[DEBUG] GET ${VEZA_URL}/api/v1/providers (Authorization: Bearer ***)"
        veza_resp=$(curl -s -o /tmp/veza_auth_resp.json -w "%{http_code}" -m 15 \
            -H "Authorization: Bearer ${VEZA_API_KEY}" \
            "${VEZA_URL}/api/v1/providers" 2>/dev/null)
        if [[ "${veza_resp}" == "200" ]]; then
            print_success "Veza API key valid (HTTP 200)"
        else
            print_fail "Veza API authentication failed (HTTP ${veza_resp})"
            python3 -c "import json,sys; print(json.dumps(json.load(open('/tmp/veza_auth_resp.json')),indent=2))" 2>/dev/null | head -20
        fi
    else
        print_warning "VEZA_URL or VEZA_API_KEY not set — skipping Veza auth test"
    fi
}

# ── Section 6: API Endpoint Access ────────────────────────────────────────────
check_api_endpoints() {
    print_header "6 — API Endpoint Access"

    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a

    # Armis users endpoint (needs auth token first)
    if [[ -n "${ARMIS_TENANT:-}" && -n "${ARMIS_SECRET_KEY:-}" ]]; then
        # Get token
        token=$(curl -s -m 15 \
            -X POST "https://${ARMIS_TENANT}.armis.com/api/v1/access_token/" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "secret_key=${ARMIS_SECRET_KEY}" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('access_token',''))" 2>/dev/null)

        if [[ -n "${token}" ]]; then
            # Test /api/v1/users/
            users_resp=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
                -H "Authorization: ${token}" \
                "https://${ARMIS_TENANT}.armis.com/api/v1/users/?length=1&from=0" 2>/dev/null)
            if [[ "${users_resp}" == "200" ]]; then
                print_success "GET /api/v1/users/ (HTTP 200)"
            else
                print_fail "GET /api/v1/users/ returned HTTP ${users_resp}"
            fi

            # Test /api/v1/roles/
            roles_resp=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
                -H "Authorization: ${token}" \
                "https://${ARMIS_TENANT}.armis.com/api/v1/roles/" 2>/dev/null)
            if [[ "${roles_resp}" == "200" ]]; then
                print_success "GET /api/v1/roles/ (HTTP 200)"
            else
                print_fail "GET /api/v1/roles/ returned HTTP ${roles_resp}"
            fi
        else
            print_warning "Could not obtain Armis token — skipping endpoint checks"
        fi
    else
        print_warning "Armis credentials not set — skipping endpoint checks"
    fi

    # Veza query endpoint
    if [[ -n "${VEZA_URL:-}" && -n "${VEZA_API_KEY:-}" ]]; then
        veza_query_resp=$(curl -s -o /tmp/veza_query_resp.json -w "%{http_code}" -m 15 \
            -X POST "${VEZA_URL}/api/v1/assessments/query_spec:nodes" \
            -H "Authorization: Bearer ${VEZA_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"query":"nodes{InstanceId first:1}"}' 2>/dev/null)
        if [[ "${veza_query_resp}" == "200" ]]; then
            print_success "Veza query endpoint accessible (HTTP 200)"
        else
            print_warning "Veza query endpoint returned HTTP ${veza_query_resp} (may need specific permissions)"
            python3 -c "import json,sys; print(json.dumps(json.load(open('/tmp/veza_query_resp.json')),indent=2))" 2>/dev/null | head -10
        fi
    else
        print_warning "VEZA credentials not set — skipping Veza query endpoint test"
    fi
}

# ── Section 7: Deployment Structure ──────────────────────────────────────────
check_deployment_structure() {
    print_header "7 — Deployment Structure"

    # Main script
    if [[ -f "${MAIN_SCRIPT}" ]]; then
        print_success "armis-centrix.py found and readable"
    else
        print_fail "armis-centrix.py not found at ${MAIN_SCRIPT}"
    fi

    # requirements.txt
    if [[ -f "${REQUIREMENTS_FILE}" ]]; then
        print_success "requirements.txt present"
    else
        print_fail "requirements.txt not found"
    fi

    # logs/ directory
    LOGS_DIR="${SCRIPT_DIR}/logs"
    if [[ -d "${LOGS_DIR}" ]]; then
        if [[ -w "${LOGS_DIR}" ]]; then
            print_success "logs/ directory exists and is writable"
        else
            print_warning "logs/ directory exists but is not writable"
        fi
    else
        print_info "logs/ directory not found — will be auto-created on first run"
    fi

    # Check --help works
    if "${PYTHON_BIN}" "${MAIN_SCRIPT}" --help &>/dev/null 2>&1; then
        print_success "armis-centrix.py --help exits cleanly"
    else
        print_warning "armis-centrix.py --help failed — check Python dependencies (section 2)"
    fi

    # Current user
    CURRENT_USER="$(whoami)"
    print_info "Running as: ${CURRENT_USER}"
    if [[ "${CURRENT_USER}" != "root" ]]; then
        print_info "Not running as root (recommended — use a dedicated service account)"
    fi

    # Recommended path
    RECOMMENDED_PATH="/opt/VEZA/armis-centrix-veza/scripts"
    if [[ "${SCRIPT_DIR}" == "${RECOMMENDED_PATH}" ]]; then
        print_success "Running from recommended install path"
    else
        print_info "Script is at ${SCRIPT_DIR} (recommended: ${RECOMMENDED_PATH})"
    fi
}

# ── Section 8: Summary ────────────────────────────────────────────────────────
print_summary() {
    print_header "Validation Summary"
    echo -e "${GREEN}Passed:${NC}   ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC}   ${TESTS_FAILED}"
    echo -e "${YELLOW}Warnings:${NC} ${TESTS_WARNING}"
    echo ""
    if [[ ${TESTS_FAILED} -eq 0 ]]; then
        echo -e "${GREEN}All required checks passed.${NC} Recommended dry-run command:"
        echo ""
        echo "  cd ${SCRIPT_DIR}"
        echo "  ${VENV_DIR}/bin/python3 armis-centrix.py --dry-run --save-json --log-level DEBUG"
        echo ""
        return 0
    else
        echo -e "${RED}✗ Some checks failed. Please address the issues above before deployment.${NC}"
        return 1
    fi
}

# ── Utility: display config ────────────────────────────────────────────────────
display_config() {
    print_header "Current Configuration"
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a
    echo "  ARMIS_TENANT:    ${ARMIS_TENANT:-<not set>}"
    echo "  ARMIS_SECRET_KEY: ${ARMIS_SECRET_KEY:0:8}...  (masked)"
    echo "  VEZA_URL:        ${VEZA_URL:-<not set>}"
    echo "  VEZA_API_KEY:    ${VEZA_API_KEY:0:8}...  (masked)"
    echo "  PROVIDER_NAME:   ${PROVIDER_NAME:-Armis (default)}"
    echo "  DATASOURCE_NAME: ${DATASOURCE_NAME:-Armis Centrix (default)}"
}

# ── Utility: generate .env template ──────────────────────────────────────────
generate_env_template() {
    print_header "Generate .env Template"
    TARGET="${SCRIPT_DIR}/.env"
    if [[ -f "${TARGET}" ]]; then
        echo "  .env already exists at ${TARGET}"
        IFS= read -r -p "  Overwrite? [y/N]: " yn </dev/tty
        [[ "${yn}" != [yY] ]] && echo "  Skipped." && return
    fi
    cat > "${TARGET}" <<'EOF'
# Armis Centrix Source Configuration
ARMIS_TENANT=your-tenant-subdomain
ARMIS_SECRET_KEY=your_armis_secret_key_here

# Veza Configuration
VEZA_URL=https://your-company.vezacloud.com
VEZA_API_KEY=your_veza_api_key_here

# OAA Provider Settings (optional)
# PROVIDER_NAME=Armis
# DATASOURCE_NAME=Armis Centrix
EOF
    chmod 600 "${TARGET}"
    echo -e "${GREEN}✓${NC}  Template written to ${TARGET} (permissions: 600)"
}

# ── Utility: install dependencies ─────────────────────────────────────────────
install_dependencies() {
    print_header "Install Python Dependencies"
    [[ ! -d "${VENV_DIR}" ]] && python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install -r "${REQUIREMENTS_FILE}"
    print_success "Dependencies installed into ${VENV_DIR}"
}

# ── Run all checks ────────────────────────────────────────────────────────────
run_all_checks() {
    echo "" >> "${LOG_FILE}"
    echo "Preflight log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
    check_system_requirements
    check_python_dependencies
    check_configuration
    check_network_connectivity
    check_api_authentication
    check_api_endpoints
    check_deployment_structure
    print_summary
}

# ── Interactive menu ──────────────────────────────────────────────────────────
show_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}Armis Centrix → Veza OAA — Pre-flight Checks${NC}"
        echo "──────────────────────────────────────────────"
        echo "  1) System Requirements       7) Deployment Structure"
        echo "  2) Python Dependencies       8) Run ALL Checks (recommended)"
        echo "  3) Configuration File        9) Display Current Configuration"
        echo "  4) Network Connectivity     10) Generate Template .env File"
        echo "  5) API Authentication       11) Install Python Dependencies"
        echo "  6) API Endpoint Access       0) Exit"
        echo ""
        IFS= read -r -p "Select option: " opt </dev/tty
        case "${opt}" in
            1)  check_system_requirements ;;
            2)  check_python_dependencies ;;
            3)  check_configuration ;;
            4)  check_network_connectivity ;;
            5)  check_api_authentication ;;
            6)  check_api_endpoints ;;
            7)  check_deployment_structure ;;
            8)  run_all_checks ;;
            9)  display_config ;;
            10) generate_env_template ;;
            11) install_dependencies ;;
            0)  echo "Exiting."; exit 0 ;;
            *)  echo "Invalid option: ${opt}" ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    echo "Preflight log → ${LOG_FILE}"
    if [[ "${1:-}" == "--all" ]]; then
        run_all_checks
        exit $?
    fi
    show_menu
}

main "$@"
