## Features
- Automatic Hysteria2 installation & configuration
- User authentication via Panel API
- Real-time traffic reporting
- Systemd service management

## Installation

### Prerequisites
- Ubuntu 20.04+ / Debian 11+
- Root access
- Active Panel URL and API Key

### Quick Start

1. **Clone the repository**
   ```bash
   git clone https://github.com/0xd5f/any-node.git
   cd any-node
   ```

2. **Run Instructions**
   Make the installer executable and run it:
   ```bash
   chmod +x install.sh
   ./install.sh install <PORT> <SNI_DOMAIN>
   ```

   *Example:*
   ```bash
   ./install.sh install 443 google.com
   ```

3. **Configuration**
   During installation, you will be prompted to enter:
   - **Panel URL**: The base URL of your web panel (e.g., `https://panel.example.com/your-path/`).
   - **Panel Key**: The Secret API Key from your panel settings.

## API Integration

The node communicates with the panel via the following endpoints:
- **Authentication**: `GET /api/v1/users/` (Validation of authorized users)
- **Traffic Logging**: `POST /api/v1/config/ip/nodestraffic` (Usage reporting)

## Management

**Uninstall:**
```bash
bash install.sh uninstall
```

**Check Service Status:**
```bash
systemctl status hysteria-server.service
```