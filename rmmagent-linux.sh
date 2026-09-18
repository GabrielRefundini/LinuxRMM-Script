#!/bin/bash
# Tactical RMM Linux installer/updater/uninstaller
# https://github.com/Nerdy-Technician/LinuxRMM-Script
# Author: Nerdy-Technician <


set -euo pipefail

#--- simple/pretty output ------------------------------------------------------
SIMPLE=false
if [[ "${1:-}" == "--simple" ]]; then
    SIMPLE=true
    shift
fi

# color codes
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

function info_echo() { 
    if $SIMPLE; then
        echo -e "\n[${BLUE}INFO${RESET}] $1\n"
    else
        echo "$1"
    fi
}

function ok_echo() {
    if $SIMPLE; then
        echo -e "[${GREEN}OK${RESET}] ✅ $1\n"
    else
        echo "$1"
    fi
}

function err_echo() {
    if $SIMPLE; then
        echo -e "[${RED}ERROR${RESET}] ❌ $1\n"
    else
        echo "$1"
    fi
}

#--- safety: require root -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g. sudo $0 ...)"
    exit 1
fi

#--- staging directory ----------------------------------------------------------
# Private root-owned directory instead of fixed /tmp paths: a world-writable /tmp
# lets a local user swap a file between verification and use, or pre-plant a
# symlink for wget to follow.
STAGING="$(mktemp -d /tmp/rmmagent-install.XXXXXXXX)"
chmod 700 "$STAGING"

#--- cleanup trap --------------------------------------------------------------
cleanup() {
    info_echo "Cleaning up temporary files..."
    rm -rf "$STAGING" ./go 2>/dev/null || true
    ok_echo "Temporary files cleaned."
}
trap cleanup EXIT

#--- usage / guards -------------------------------------------------------------
if [[ -z "${1:-}" ]]; then
    echo "First argument is empty!"
    echo "Type 'help' for more information"
    exit 1
fi

if [[ "$1" == "help" ]]; then
    cat <<'EOF'
Help available at:
  github.com/Nerdy-Technician/LinuxRMM-Script

Install example:
  sudo bash rmmagent-linux.sh install \
    "https://mesh.example.com/meshagents?id=ENCODED_ID" \
    "https://rmm-api.example.com" \
    1 2 "SuperSecretAuthKey" server

Install with simple output formatting:
  sudo bash rmmagent-linux.sh --simple install \
    "https://mesh.example.com/meshagents?id=ENCODED_ID" \
    "https://rmm-api.example.com" \
    1 2 "SuperSecretAuthKey" server

Uninstall example:
  sudo bash rmmagent-linux.sh uninstall "mesh.example.com" "mesh-id"

Update example:
  sudo bash rmmagent-linux.sh update
EOF
    exit 0
fi

if [[ "$1" != "install" && "$1" != "update" && "$1" != "uninstall" ]]; then
    echo "First argument can only be 'install', 'update', or 'uninstall'!"
    exit 1
fi

# Checked here, before anything touches the system: aborting later would leave an
# orphaned MeshCentral registration behind.
if [[ "$1" != "uninstall" ]] && ! command -v git >/dev/null 2>&1; then
    echo "git not found. It is required to fetch the pinned agent version."
    exit 1
fi

#--- arch detection -------------------------------------------------------------

function detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        i386|i686) echo "x86" ;;
        aarch64) echo "arm64" ;;
        armv6l|armv7l) echo "armv6" ;;
        *) echo "unsupported" ;;
    esac
}


#--- inputs --------------------------------------------------------------------
mesh_url="${2:-}"
rmm_url="${3:-}"
rmm_client_id="${4:-}"
rmm_site_id="${5:-}"
rmm_auth="${6:-}"
rmm_agent_type="${7:-}"

# uninstall inputs
mesh_fqdn="${2:-}"
mesh_id="${3:-}"

#--- versions / URLs -----------------------------------------------------------
go_version="1.26.5"
go_url_amd64="https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"
go_url_x86="https://go.dev/dl/go${go_version}.linux-386.tar.gz"
go_url_arm64="https://go.dev/dl/go${go_version}.linux-arm64.tar.gz"
go_url_armv6="https://go.dev/dl/go${go_version}.linux-armv6l.tar.gz"

# Official sha256 sums from https://go.dev/dl/?mode=json (update when bumping go_version)
go_sha_amd64="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
go_sha_x86="88c162b204e6eefcc32499453b492e80209f4a4c78c33092636901c540fb0d05"
go_sha_arm64="fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49"
go_sha_armv6="6dae9edab81c13bccf962dec15f1fd2ec26c14a6821b4d2c92dab4130c289d7a"

# Pinned agent version. The commit is the real integrity anchor: a git SHA covers
# the whole tree, so a tag rewritten upstream is caught here.
# Must match LATEST_AGENT_VER of the TRMM server (v1.5.2 expects 2.11.0).
# Override per-run with AGENT_TAG/AGENT_COMMIT (both required together).
agent_tag="${AGENT_TAG:-v2.11.0}"
agent_commit="${AGENT_COMMIT:-e6b61ba540af2df9d13247f96538397daa3c4f1f}"

if [[ -n "${AGENT_TAG:-}${AGENT_COMMIT:-}" && ( -z "${AGENT_TAG:-}" || -z "${AGENT_COMMIT:-}" ) ]]; then
    echo "AGENT_TAG and AGENT_COMMIT must be set together."
    exit 1
fi

mesh_amd64="&installflags=0&meshinstall=6"
mesh_arm6l="&installflags=0&meshinstall=25"
mesh_arm64="&installflags=0&meshinstall=26"

#--- helpers -------------------------------------------------------------------
function verify_sha256() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        err_echo "Invalid checksum for $file"
        err_echo "  expected: $expected"
        err_echo "  got:      $actual"
        exit 1
    fi
    ok_echo "Checksum verified: $(basename "$file")"
}

function go_install() {
    system=$(detect_arch)
    if ! command -v go >/dev/null 2>&1; then
        info_echo "Installing Go $go_version for $system..."
        case "$system" in
            amd64) url="$go_url_amd64"; sha="$go_sha_amd64" ;;
            x86)   url="$go_url_x86";   sha="$go_sha_x86" ;;
            arm64) url="$go_url_arm64"; sha="$go_sha_arm64" ;;
            armv6) url="$go_url_armv6"; sha="$go_sha_armv6" ;;
            *) err_echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
        esac
        if $SIMPLE; then
            wget -q -O "$STAGING/golang.tar.gz" "$url" 2>/dev/null
        else
            wget -q --show-progress -O "$STAGING/golang.tar.gz" "$url"
        fi
        verify_sha256 "$STAGING/golang.tar.gz" "$sha"
        rm -rf /usr/local/go/
        tar -xzf "$STAGING/golang.tar.gz" -C /usr/local/ 2>/dev/null

        export PATH=/usr/local/go/bin:$PATH
        if ! grep -q "/usr/local/go/bin" /etc/profile; then
            echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
        fi
        ok_echo "Go $go_version installed."
    fi
}

function update_agent() {
    systemctl stop tacticalagent
    install -m 0755 "$STAGING/temp_rmmagent" /usr/local/bin/rmmagent
    systemctl start tacticalagent
}

function agent_fetch() {
    info_echo "Fetching agent $agent_tag ($agent_commit)..."
    rm -rf "$STAGING/rmmagent-src"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$agent_tag" \
        https://github.com/amidaware/rmmagent.git "$STAGING/rmmagent-src"

    local actual
    actual=$(git -C "$STAGING/rmmagent-src" rev-parse HEAD)
    if [[ "$actual" != "$agent_commit" ]]; then
        err_echo "Agent commit mismatch - the tag may have been rewritten upstream."
        err_echo "  expected: $agent_commit"
        err_echo "  got:      $actual"
        exit 1
    fi
    ok_echo "Agent $agent_tag verified at commit $agent_commit"
}

function agent_compile() {
    agent_fetch
    info_echo "Compiling Tactical RMM agent for $system..."
    cd "$STAGING/rmmagent-src"

    case "$system" in
        amd64) goarch="amd64" ;;
        x86)   goarch="386" ;;
        arm64) goarch="arm64" ;;
        armv6) goarch="arm" ;;
        *) err_echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    if $SIMPLE; then
        env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
            go build -ldflags "-s -w" -o "$STAGING/temp_rmmagent" >/dev/null 2>&1
    else
        env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
            go build -ldflags "-s -w" -o "$STAGING/temp_rmmagent"
    fi

    cd "$STAGING"
    ok_echo "Tactical RMM agent compiled."
}

function install_agent() {
    info_echo "Installing Tactical Agent service..."
    
    # Remove old binary and config if present
    rm -f /usr/local/bin/rmmagent
    if [ -d /etc/tacticalagent ]; then
        rm -rf /etc/tacticalagent
        info_echo "Old /etc/tacticalagent removed."
    fi

    install -m 0755 "$STAGING/temp_rmmagent" /usr/local/bin/rmmagent

    if $SIMPLE; then
        echo
        if /usr/local/bin/rmmagent -m install \
            -api "$rmm_url" \
            -client-id "$rmm_client_id" \
            -site-id "$rmm_site_id" \
            -agent-type "$rmm_agent_type" \
            -auth "$rmm_auth" >/dev/null 2>&1; then
            ok_echo "Tactical RMM Agent installed successfully."
        else
            err_echo "Tactical RMM Agent failed to install. Check logs or run without --simple."
            exit 1
        fi
    else
        /usr/local/bin/rmmagent -m install \
            -api "$rmm_url" \
            -client-id "$rmm_client_id" \
            -site-id "$rmm_site_id" \
            -agent-type "$rmm_agent_type" \
            -auth "$rmm_auth"
    fi

    # systemd service
    cat >/etc/systemd/system/tacticalagent.service <<'EOF'
[Unit]
Description=Tactical RMM Linux Agent
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rmmagent -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tacticalagent
    ok_echo "Tactical RMM Agent service installed and started."
}

function install_mesh() {
    info_echo "Installing MeshCentral agent for $system..."
    case "$system" in
        amd64) mesh_param="$mesh_amd64" ;;
        armv6) mesh_param="$mesh_arm6l" ;;
        arm64) mesh_param="$mesh_arm64" ;;
        x86)   mesh_param="$mesh_amd64" ;;
        *) echo "No Mesh installer flag for this architecture: $system"; exit 1 ;;
    esac

    full_mesh_url="${mesh_url}${mesh_param}"
    if $SIMPLE; then
        wget -q -O "$STAGING/meshagent" "$full_mesh_url" 2>/dev/null
    else
        wget -q --show-progress -O "$STAGING/meshagent" "$full_mesh_url"
    fi
    chmod +x "$STAGING/meshagent"
    mkdir -p /opt/tacticalmesh
    if $SIMPLE; then
        "$STAGING/meshagent" -install --installPath="/opt/tacticalmesh" >/dev/null 2>&1
    else
        "$STAGING/meshagent" -install --installPath="/opt/tacticalmesh"
    fi
    ok_echo "Mesh agent installed."
}


function uninstall_agent() {
    info_echo "Uninstalling Tactical Agent..."
    systemctl stop tacticalagent || true
    systemctl disable tacticalagent || true
    rm -f /etc/systemd/system/tacticalagent.service
    systemctl daemon-reload
    rm -f /usr/local/bin/rmmagent
    rm -rf /etc/tacticalagent
    ok_echo "Tactical Agent uninstalled."
}

function uninstall_mesh() {
    info_echo "Uninstalling MeshCentral agent..."
    if [[ -z "$mesh_fqdn" || -z "$mesh_id" ]]; then
        err_echo "Mesh FQDN and Mesh ID are required for uninstall."
        exit 1
    fi

    if $SIMPLE; then
        wget "https://${mesh_fqdn}/meshagents?script=1" -O "$STAGING/meshinstall.sh" 2>/dev/null \
            || wget "https://${mesh_fqdn}/meshagents?script=1" --no-proxy -O "$STAGING/meshinstall.sh" 2>/dev/null
    else
        wget "https://${mesh_fqdn}/meshagents?script=1" -O "$STAGING/meshinstall.sh" \
            || wget "https://${mesh_fqdn}/meshagents?script=1" --no-proxy -O "$STAGING/meshinstall.sh"
    fi

    chmod 755 "$STAGING/meshinstall.sh"
    if $SIMPLE; then
        "$STAGING/meshinstall.sh" uninstall "https://${mesh_fqdn}" "$mesh_id" >/dev/null 2>&1 || true
    else
        "$STAGING/meshinstall.sh" uninstall "https://${mesh_fqdn}" "$mesh_id" || true
    fi
    ok_echo "Mesh agent uninstall attempted."
}

#--- dispatcher ----------------------------------------------------------------
case "$1" in
    install)
        go_install
        install_mesh
        agent_compile
        install_agent
        ok_echo "Tactical Agent Install is done. ✅ "
        ;;
    update)
        go_install
        agent_compile
        update_agent
        ok_echo "Tactical Agent Update is done. ✅ "
        ;;
    uninstall)
        uninstall_agent
        uninstall_mesh
        ok_echo "Tactical Agent Uninstall is done. ✅ "
        ;;
esac
