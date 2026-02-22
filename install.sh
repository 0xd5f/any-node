#!/bin/bash
CONFIG_FILE="/etc/hysteria/config.json"

define_colors() {
    green='\033[0;32m'
    cyan='\033[0;36m'
    red='\033[0;31m'
    yellow='\033[0;33m'
    LPurple='\033[1;35m'
    NC='\033[0m'
}

install_hysteria() {
    local port=$1
    local sni=$2
    local sha256
    local obfspassword
    local UUID
    local networkdef
    local panel_url
    local panel_key

    echo "Configuring Panel API..."
    read -p "Enter panel API domain and path (e.g., https://example.com/path/): " panel_url
    read -p "Enter panel API key: " panel_key
    
    if [[ -z "$panel_url" ]] || [[ -z "$panel_key" ]]; then
        echo -e "${red}Error:${NC} Panel URL and API key are required"
        exit 1
    fi
    
    panel_url="${panel_url%/}"

    echo "Cloning ANY Node repository..."
    git clone https://github.com/0xd5f/any-node /etc/hysteria >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to clone ANY Node repository"
        exit 1
    }

    echo "Installing Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
    
    cd /etc/hysteria/

    echo "Installing Python and dependencies..."
    apt-get update 
    apt-get install -qq -y python3 python3-venv python3-pip jq

    echo "Generating CA key and certificate..."
    openssl ecparam -genkey -name prime256v1 -out ca.key >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key ca.key -out ca.crt -subj "/CN=$sni" >/dev/null 2>&1
    
    echo "Downloading geo data and config..."
    wget -O /etc/hysteria/config.json https://raw.githubusercontent.com/0xd5f/ANY/refs/heads/main/config.json >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to download config.json"
        exit 1
    }
    wget -O /etc/hysteria/geosite.dat https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite.dat >/dev/null 2>&1
    wget -O /etc/hysteria/geoip.dat https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip.dat >/dev/null 2>&1

    echo "Generating SHA-256 fingerprint..."
    sha256=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in ca.crt | sed 's/.*=//' | tr '[:lower:]' '[:upper:]')

    if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo -e "${red}Error:${NC} Invalid port number. Please enter a number between 1 and 65535."
        exit 1
    fi
    
    if ss -tuln | grep -q ":$port "; then
        echo -e "${red}Error:${NC} Port $port is already in use. Please choose another port."
        exit 1
    fi

    if ! id -u hysteria &> /dev/null; then
        useradd -r -s /usr/sbin/nologin hysteria
    fi

    echo "Generating passwords and UUID..."
    obfspassword=$(openssl rand -hex 16)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    networkdef=$(ip route | grep "^default" | awk '{print $5}')

    chown hysteria:hysteria /etc/hysteria/ca.key /etc/hysteria/ca.crt
    chmod 640 /etc/hysteria/ca.key /etc/hysteria/ca.crt

    echo "Updating traffic.py script..."
    cat > /etc/hysteria/traffic.py << 'EOF'
import json
import os
import asyncio
import aiohttp
from datetime import datetime
import logging
import psutil
import time
import subprocess

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

CONFIG_FILE = '/etc/hysteria/config.json'
PANEL_API_URL = os.getenv("PANEL_API_URL")
PANEL_TRAFFIC_URL = os.getenv("PANEL_TRAFFIC_URL")
PANEL_HEARTBEAT_URL = os.getenv("PANEL_HEARTBEAT_URL")
PANEL_API_KEY = os.getenv("PANEL_API_KEY")
NODE_NAME = os.getenv("NODE_NAME")
HYSTERIA_API_BASE = "http://127.0.0.1:25413"
SYNC_INTERVAL = int(os.getenv("SYNC_INTERVAL") or 60)

def load_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load config: {e}")
        return {}

def get_secret():
    config = load_config()
    return config.get('trafficStats', {}).get('secret')

# --- Traffic Functions ---

async def fetch_users_from_panel():
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": PANEL_API_KEY, "accept": "application/json"}
            async with session.get(PANEL_API_URL, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    # Determine list structure
                    if isinstance(data, list):
                        return {user.get("username"): user for user in data}
                    elif isinstance(data, dict) and "results" in data:
                        return {u.get("username"): u for u in data.get("results", [])}
                    else:
                        return {}
                else:
                    logger.error(f"Panel API returned status {resp.status}")
                    return {}
    except Exception as e:
        logger.error(f"Failed to fetch users from panel: {e}")
        return {}

async def collect_traffic_from_hysteria(secret):
    if not secret:
        return {}
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": secret}
            # Use clear=1 to reset counters after reading
            async with session.get(f"{HYSTERIA_API_BASE}/traffic?clear=1", headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    traffic_dict = {}
                    for username, stats in data.items():
                        traffic_dict[username] = {
                            "upload_bytes": stats.get("tx", 0),
                            "download_bytes": stats.get("rx", 0)
                        }
                    return traffic_dict
                else:
                    logger.error(f"Hysteria2 API returned status {resp.status}")
                    return {}
    except Exception as e:
        logger.error(f"Failed to collect traffic from Hysteria2: {e}")
        return {}
        
async def collect_online_clients(secret):
    if not secret:
        return 0
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": secret}
            async with session.get(f"{HYSTERIA_API_BASE}/online", headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return len(data) if isinstance(data, list) else 0
    except Exception:
        return 0
    return 0

async def send_traffic_to_panel(users_traffic):
    if not users_traffic:
        return
    try:
        payload = {"users": users_traffic}
        async with aiohttp.ClientSession() as session:
            headers = {
                "Authorization": PANEL_API_KEY,
                "Content-Type": "application/json"
            }
            async with session.post(PANEL_TRAFFIC_URL, json=payload, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                     logger.info(f"Sent traffic for {len(users_traffic)} users")
                else:
                     logger.error(f"Failed to send traffic: {resp.status}")
    except Exception as e:
        logger.error(f"Error sending traffic: {e}")

async def sync_traffic():
    try:
        users = await fetch_users_from_panel()
        if not users:
            return

        secret = get_secret()
        if not secret:
            logger.error("Secret not found in config")
            return

        traffic_data = await collect_traffic_from_hysteria(secret)
        
        users_traffic = []
        for username, user_data in users.items():
            stats = traffic_data.get(username, {"upload_bytes": 0, "download_bytes": 0})
            
            upload_delta = int(stats.get("upload_bytes", 0))
            download_delta = int(stats.get("download_bytes", 0))
            
            online_count = 1 if (upload_delta > 0 or download_delta > 0) else 0
            
            traffic_entry = {
                "username": username,
                "upload_bytes": upload_delta,
                "download_bytes": download_delta,
                "online_count": online_count,
                "status": "Online" if online_count > 0 else user_data.get("status", "Offline")
            }
            
            if (upload_delta > 0 or download_delta > 0):
                 if not user_data.get("account_creation_date"):
                      traffic_entry["account_creation_date"] = datetime.now().strftime("%Y-%m-%d")

            users_traffic.append(traffic_entry)
            
        await send_traffic_to_panel(users_traffic)
        return True

    except Exception as e:
        logger.error(f"Error executing traffic sync: {e}")
        return False

# --- Heartbeat Functions ---

def get_system_stats():
    # Call cpu_percent with interval=None (non-blocking) - we will clarify this
    # Actually, for the loop, we can just grab usage. 
    # But first call to cpu_percent is always 0 if no interval and no previous call.
    # We do a preamble call in main()
    cpu = psutil.cpu_percent(interval=None) 
    
    ram = psutil.virtual_memory()
    uptime = time.time() - psutil.boot_time()
    
    days = int(uptime // 86400)
    hours = int((uptime % 86400) // 3600)
    minutes = int((uptime % 3600) // 60)
    uptime_str = f"{days}d {hours}h {minutes}m"
    
    hysteria_active = False
    for p in psutil.process_iter(['name']):
        try:
            if 'hysteria' in (p.info['name'] or ''):
                hysteria_active = True
                break
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
            
    return {
        "node_name": NODE_NAME or "Unknown",
        "cpu_percent": cpu,
        "ram_percent": ram.percent,
        "ram_used": round(ram.used / (1024**3), 2),
        "ram_total": round(ram.total / (1024**3), 2),
        "uptime": uptime_str,
        "hysteria_active": hysteria_active
    }

async def send_heartbeat(max_retries=5, base_delay=1):
    if not PANEL_HEARTBEAT_URL:
        return
    attempt = 0
    while attempt < max_retries:
        try:
            stats = await asyncio.to_thread(get_system_stats)
            async with aiohttp.ClientSession() as session:
                headers = {
                    "Authorization": PANEL_API_KEY,
                    "Content-Type": "application/json"
                }
                async with session.post(PANEL_HEARTBEAT_URL, json=stats, headers=headers, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        command = data.get("command")
                        if command == "restart":
                            logger.info("Received restart command from panel")
                            subprocess.run(["sudo", "systemctl", "restart", "hysteria-server"])
                        return
                    else:
                        logger.error(f"Heartbeat failed: {resp.status}")
                        return
        except Exception as e:
            logger.error(f"Error sending heartbeat (attempt {attempt+1}): {e}")
        attempt += 1
        delay = base_delay * (2 ** (attempt - 1))
        await asyncio.sleep(delay)
    logger.error(f"All attempts to send heartbeat failed after {max_retries} retries")

async def main():
    logger.info(f"Node Agent started. Name: {NODE_NAME}. Interval: {SYNC_INTERVAL}s")
    psutil.cpu_percent(interval=None)
    DEFAULT_SYNC_INTERVAL = SYNC_INTERVAL
    MAX_SYNC_INTERVAL = 600
    sync_interval = DEFAULT_SYNC_INTERVAL
    while True:
        start = time.time()
        try:
            results = await asyncio.gather(
                asyncio.wait_for(sync_traffic(), timeout=60),
                asyncio.wait_for(send_heartbeat(), timeout=30),
                return_exceptions=True
            )
            had_error = any(isinstance(r, Exception) or r is False for r in results)
            if had_error:
                sync_interval = min(sync_interval * 2, MAX_SYNC_INTERVAL)
                logger.warning(f"Error detected, increasing sync interval to {sync_interval}s")
            else:
                sync_interval = DEFAULT_SYNC_INTERVAL
        except Exception as e:
            sync_interval = min(sync_interval * 2, MAX_SYNC_INTERVAL)
            logger.error(f"Critical error in main loop: {e}. Increasing sync interval to {sync_interval}s")
        elapsed = time.time() - start
        logger.info(f"Cycle completed in {elapsed:.2f}s. Next in {sync_interval}s")
        await asyncio.sleep(sync_interval)

if __name__ == "__main__":
    asyncio.run(main())
EOF

    echo "Customizing config.json..."
    jq --arg port "$port" \
       --arg sha256 "$sha256" \
       --arg obfspassword "$obfspassword" \
       --arg UUID "$UUID" \
       --arg networkdef "$networkdef" \
       '.listen = (":" + $port) |
        .tls.cert = "/etc/hysteria/ca.crt" |
        .tls.key = "/etc/hysteria/ca.key" |
        .tls.pinSHA256 = $sha256 |
        .obfs.salamander.password = $obfspassword |
        .trafficStats.secret = $UUID |
        .outbounds[0].direct.bindDevice = $networkdef' "$CONFIG_FILE" > "${CONFIG_FILE}.temp" && mv "${CONFIG_FILE}.temp" "$CONFIG_FILE" || {
        echo -e "${red}Error:${NC} Failed to customize config.json"
        exit 1
    }

    echo "Updating hysteria-server.service configuration..."
    if [[ -f /etc/systemd/system/hysteria-server.service ]]; then
        sed -i 's|/etc/hysteria/config.yaml|'"$CONFIG_FILE"'|g' /etc/systemd/system/hysteria-server.service
        [[ -f /etc/hysteria/config.yaml ]] && rm /etc/hysteria/config.yaml
    fi

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-server.service >/dev/null 2>&1
    systemctl restart hysteria-server.service >/dev/null 2>&1
    sleep 2

    echo "Setting up Python virtual environment and services..."
    python3 -m venv /etc/hysteria/hysteria2_venv >/dev/null 2>&1
    /etc/hysteria/hysteria2_venv/bin/pip install aiohttp psutil >/dev/null 2>&1
    
    local node_name_val="$(hostname)-$port"

    echo "Creating .env configuration file..."
    cat > /etc/hysteria/.env <<EOF
PANEL_API_URL=${panel_url}/api/v1/users/
PANEL_TRAFFIC_URL=${panel_url}/api/v1/config/ip/nodestraffic
PANEL_HEARTBEAT_URL=${panel_url}/api/v1/config/ip/nodes/heartbeat
PANEL_API_KEY=${panel_key}
SYNC_INTERVAL=35
NODE_NAME=${node_name_val}
EOF
    chown hysteria:hysteria /etc/hysteria/.env
    chmod 600 /etc/hysteria/.env
    
    # Allow hysteria user to restart service
    if ! grep -q "hysteria ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hysteria-server" /etc/sudoers; then
        echo "hysteria ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hysteria-server" >> /etc/sudoers
    fi
    
    cat > /etc/systemd/system/hysteria-auth.service <<EOF
[Unit]
Description=Hysteria2 Auth Service
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=/etc/hysteria
Environment="PATH=/etc/hysteria/hysteria2_venv/bin"
EnvironmentFile=/etc/hysteria/.env
ExecStart=/etc/hysteria/hysteria2_venv/bin/python3 /etc/hysteria/auth.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/hysteria-traffic.service <<EOF
[Unit]
Description=Hysteria2 Traffic Collector
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=/etc/hysteria
Environment="PATH=/etc/hysteria/hysteria2_venv/bin"
EnvironmentFile=/etc/hysteria/.env
ExecStart=/etc/hysteria/hysteria2_venv/bin/python3 /etc/hysteria/traffic.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    chown hysteria:hysteria /etc/hysteria/hysteria2_venv
    chmod 750 /etc/hysteria/hysteria2_venv
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-auth.service hysteria-traffic.service >/dev/null 2>&1
    systemctl start hysteria-auth.service hysteria-traffic.service >/dev/null 2>&1

    if systemctl is-active --quiet hysteria-server.service; then
        echo -e "${green}✓${NC} Hysteria2 installed successfully"
        echo -e "${cyan}Port:${NC} $port"
        echo -e "${cyan}SHA256:${NC} $sha256"
        echo -e "${cyan}Obfs Password:${NC} $obfspassword"
        echo ""
        echo -e "${green}✓${NC} Auth and Traffic services configured"
        echo -e "${green}✓${NC} Configuration saved to /etc/hysteria/.env"
        echo ""
        
        # Auto-register node
        echo "Registering node with panel..."
        panel_url=${panel_url%/}
        local public_ip
        public_ip=$(curl -s4 https://api.ipify.org) || public_ip=$(curl -s4 https://ifconfig.me)

        if [[ -z "$public_ip" ]]; then
            echo -e "${yellow}Warning:${NC} Failed to get public IP. Skipping auto-registration."
        else
            local node_name
            node_name="$(hostname)-$port"
            
            # Construct JSON properly using jq
            local payload
            payload=$(jq -n \
                        --arg name "$node_name" \
                        --arg ip "$public_ip" \
                        --argjson port "$port" \
                        --arg sni "$sni" \
                        --arg pin "$sha256" \
                        --arg obfs "$obfspassword" \
                        '{name: $name, ip: $ip, port: $port, sni: $sni, pinSHA256: $pin, obfs: $obfs, insecure: true}')

            local response
            response=$(curl -s -X POST "${panel_url}/api/v1/config/ip/nodes/add" \
                -H "Content-Type: application/json" \
                -H "Authorization: ${panel_key}" \
                -d "$payload")
            
            if echo "$response" | grep -q "added successfully"; then
                echo -e "${green}✓${NC} Node registered automatically with panel"
            else
                echo -e "${yellow}Warning:${NC} Failed to register node. Response: $response"
            fi
        fi

        echo ""
        echo -e "Check service status:"
        echo -e "  systemctl status hysteria-auth"
        echo -e "  systemctl status hysteria-traffic"
        return 0
    else
        echo -e "${red}✗ Error:${NC} hysteria-server.service is not active"
        journalctl -u hysteria-server.service -n 20 --no-pager
        exit 1
    fi
}

uninstall_hysteria() {
    echo "Uninstalling Hysteria2..."
    
    if systemctl is-active --quiet hysteria-server.service; then
        systemctl stop hysteria-server.service >/dev/null 2>&1
        systemctl disable hysteria-server.service >/dev/null 2>&1
        echo -e "${green}✓${NC} Stopped hysteria-server service"
    fi
    
    for service in hysteria-auth hysteria-traffic; do
        if systemctl is-active --quiet $service.service; then
            systemctl stop $service.service >/dev/null 2>&1
            systemctl disable $service.service >/dev/null 2>&1
            echo -e "${green}✓${NC} Stopped $service service"
        fi
        if [[ -f /etc/systemd/system/$service.service ]]; then
            rm /etc/systemd/system/$service.service >/dev/null 2>&1
        fi
    done
    
    bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1
    echo -e "${green}✓${NC} Removed Hysteria2 binary"
    
    if [[ -d /etc/hysteria ]]; then
        rm -rf /etc/hysteria
        echo -e "${green}✓${NC} Removed /etc/hysteria directory"
    fi
    
    if id -u hysteria &> /dev/null; then
        userdel hysteria >/dev/null 2>&1
        echo -e "${green}✓${NC} Removed hysteria user"
    fi
    
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "${green}✓${NC} Hysteria2 uninstalled successfully"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  install <port> <sni>    Install Hysteria2 with specified port and SNI"
    echo "  uninstall               Uninstall Hysteria2 completely"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install 1239 bts.com"
    echo "  $0 uninstall"
}

define_colors

case "${1:-}" in
    install)
        if [[ -z "$2" ]] || [[ -z "$3" ]]; then
            echo -e "${red}Error:${NC} Port and SNI required"
            show_usage
            exit 1
        fi
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${red}✗ Error:${NC} Hysteria2 is already installed and running"
            exit 1
        fi
        install_hysteria "$2" "$3"
        ;;
    uninstall)
        if ! systemctl is-active --quiet hysteria-server.service && [[ ! -d /etc/hysteria ]]; then
            echo -e "${yellow}⚠${NC} Hysteria2 is not installed"
            exit 0
        fi
        uninstall_hysteria
        ;;
    -h|--help)
        show_usage
        ;;
    *)
        echo -e "${red}Error:${NC} Invalid option"
        show_usage
        exit 1
        ;;
esac
