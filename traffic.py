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

async def fetch_users_from_panel(max_retries=5, base_delay=1):
    attempt = 0
    while attempt < max_retries:
        try:
            async with aiohttp.ClientSession() as session:
                headers = {"Authorization": PANEL_API_KEY, "accept": "application/json"}
                async with session.get(PANEL_API_URL, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
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
            logger.error(f"Failed to fetch users from panel (attempt {attempt+1}): {e}")
        attempt += 1
        delay = base_delay * (2 ** (attempt - 1))
        await asyncio.sleep(delay)
    logger.error(f"All attempts to fetch users from panel failed after {max_retries} retries")
    return {}

async def collect_traffic_from_hysteria(secret, max_retries=5, base_delay=1):
    if not secret:
        return {}
    attempt = 0
    while attempt < max_retries:
        try:
            async with aiohttp.ClientSession() as session:
                headers = {"Authorization": secret}
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
            logger.error(f"Failed to collect traffic from Hysteria2 (attempt {attempt+1}): {e}")
        attempt += 1
        delay = base_delay * (2 ** (attempt - 1))
        await asyncio.sleep(delay)
    logger.error(f"All attempts to collect traffic from Hysteria2 failed after {max_retries} retries")
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

async def send_traffic_to_panel(users_traffic, max_retries=5, base_delay=1):
    if not users_traffic:
        return
    attempt = 0
    payload = {"users": users_traffic}
    while attempt < max_retries:
        try:
            async with aiohttp.ClientSession() as session:
                headers = {
                    "Authorization": PANEL_API_KEY,
                    "Content-Type": "application/json"
                }
                async with session.post(PANEL_TRAFFIC_URL, json=payload, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                    if resp.status == 200:
                        logger.info(f"Sent traffic for {len(users_traffic)} users")
                        return
                    else:
                        logger.error(f"Failed to send traffic: {resp.status}")
                        return
        except Exception as e:
            logger.error(f"Error sending traffic (attempt {attempt+1}): {e}")
        attempt += 1
        delay = base_delay * (2 ** (attempt - 1))
        await asyncio.sleep(delay)
    logger.error(f"All attempts to send traffic to panel failed after {max_retries} retries")

async def sync_traffic():
    try:
        users = await fetch_users_from_panel()
        if not users:
            return False

        secret = get_secret()
        if not secret:
            logger.error("Secret not found in config")
            return False

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
