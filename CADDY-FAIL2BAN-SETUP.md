# Caddy with Fail2ban Setup Guide

This guide helps you integrate new services with an existing Caddy reverse proxy and set up fail2ban protection.

## Quick Start

For servers with Caddy already installed:

```bash
# Run the automated helper script
./caddy-setup-helper.sh
```

This script will:
- ✅ Detect your Caddy installation
- ✅ Locate and backup your Caddyfile
- ✅ Check for fail2ban configuration
- ✅ Provide examples for adding new services

## Manual Setup

### 1. Backup Your Caddyfile

**IMPORTANT:** Always backup before making changes!

```bash
# Find your Caddyfile location
CADDYFILE=~/docker/caddy/Caddyfile  # Adjust path as needed

# Create backup directory
mkdir -p $(dirname "$CADDYFILE")/backups

# Backup with timestamp
cp "$CADDYFILE" "$(dirname "$CADDYFILE")/backups/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)"
```

### 2. Add New Services to Caddy

Add these blocks to your Caddyfile:

#### ActualBudget (Personal Finance)

```caddy
budget.yourdomain.com {
    log {
        output file /var/log/caddy/actualbudget-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:5006

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
```

#### Authelia (SSO + 2FA auth portal)

```caddy
auth.yourdomain.com {
    log {
        output file /var/log/caddy/authelia-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:9091

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
```

### 3. Reload Caddy Configuration

After editing the Caddyfile:

```bash
# Format the Caddyfile (optional but recommended)
docker exec -w /etc/caddy caddy caddy fmt --overwrite

# Reload Caddy configuration
docker exec -w /etc/caddy caddy caddy reload
```

If you get errors, check Caddy logs:
```bash
docker logs caddy
```

### 4. Restore from Backup (if needed)

If something goes wrong:

```bash
# Find your backup
ls -lah ~/docker/caddy/backups/

# Restore the backup
cp ~/docker/caddy/backups/Caddyfile.backup.YYYYMMDD_HHMMSS ~/docker/caddy/Caddyfile

# Reload Caddy
docker exec -w /etc/caddy caddy caddy reload
docker exec -w /etc/caddy caddy caddy fmt --overwrite
```

## Fail2ban Configuration

### Prerequisites

1. **Enable JSON logging in Caddy** (shown in examples above)
2. **Install fail2ban** on the host:
   ```bash
   sudo apt update
   sudo apt install fail2ban -y
   ```

### Installation Steps

#### Step 1: Install Fail2ban Filter

```bash
# Copy the filter configuration
sudo cp fail2ban-caddy-filter.conf /etc/fail2ban/filter.d/caddy-auth.conf
```

Or create it manually:

```bash
sudo tee /etc/fail2ban/filter.d/caddy-auth.conf > /dev/null <<'EOF'
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(?:401|403|429).*$
            ^.*"remote_addr":"<HOST>.*"status":(?:401|403|429).*$
ignoreregex = ^.*"remote_ip":"(?:127\.0\.0\.1|::1)".*$
datepattern = "ts":%%s
EOF
```

#### Step 2: Install Fail2ban Jail

```bash
# Copy the jail configuration
sudo cp fail2ban-caddy-jail.conf /etc/fail2ban/jail.d/caddy.conf
```

Or create it manually:

```bash
sudo tee /etc/fail2ban/jail.d/caddy.conf > /dev/null <<'EOF'
[caddy-auth]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/access.log
          /var/log/caddy/*-access.log
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-multiport[name=CaddyAuth, port="http,https", protocol=tcp]
backend = auto
EOF
```

#### Step 3: Create Log Directory

```bash
# Create log directory if using Docker Caddy
sudo mkdir -p /var/log/caddy
sudo chmod 755 /var/log/caddy

# If Caddy runs as specific user:
# sudo chown caddy:caddy /var/log/caddy
```

#### Step 4: Update Caddy Docker Compose

Add log volume to your Caddy docker-compose.yml:

```yaml
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./data:/data
      - ./config:/config
      - /var/log/caddy:/var/log/caddy  # Add this line
```

Then restart Caddy:
```bash
cd ~/docker/caddy
docker compose down
docker compose up -d
```

#### Step 5: Restart Fail2ban

```bash
sudo systemctl restart fail2ban
sudo systemctl status fail2ban
```

### Testing Fail2ban

```bash
# Check if jail is running
sudo fail2ban-client status caddy-auth

# Test the filter against your logs
sudo fail2ban-regex /var/log/caddy/access.log /etc/fail2ban/filter.d/caddy-auth.conf

# View banned IPs
sudo fail2ban-client get caddy-auth banip

# Manually ban/unban an IP (for testing)
sudo fail2ban-client set caddy-auth banip 1.2.3.4
sudo fail2ban-client set caddy-auth unbanip 1.2.3.4
```

### Troubleshooting

#### Fail2ban not detecting attacks

1. **Check log format:**
   ```bash
   tail -f /var/log/caddy/access.log
   ```
   Ensure it's JSON format with `remote_ip` or `remote_addr` field.

2. **Test filter manually:**
   ```bash
   sudo fail2ban-regex /var/log/caddy/access.log /etc/fail2ban/filter.d/caddy-auth.conf --print-all-matched
   ```

3. **Check fail2ban logs:**
   ```bash
   sudo tail -f /var/log/fail2ban.log
   ```

#### Caddy configuration errors

1. **Validate Caddyfile:**
   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   ```

2. **Check Caddy logs:**
   ```bash
   docker logs caddy --tail 50
   ```

## Advanced Configuration

### Aggressive Fail2ban Settings

For tighter security:

```ini
[caddy-auth]
maxretry = 3       # Ban after 3 attempts (instead of 5)
findtime = 300     # Within 5 minutes (instead of 10)
bantime = 86400    # Ban for 24 hours (instead of 1)
```

### Ban Time Increment

Ban repeat offenders for longer:

```ini
[caddy-auth]
bantime.increment = true
bantime.factor = 24
bantime.maxtime = 604800  # Maximum 1 week ban
```

### Email Notifications

Get notified when IPs are banned:

```ini
[caddy-auth]
action = iptables-multiport[name=CaddyAuth, port="http,https", protocol=tcp]
         sendmail-whois[name=CaddyAuth, dest=admin@yourdomain.com]
```

### Per-Service Jails

Create separate jails for different services:

```ini
[caddy-actualbudget]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/actualbudget-access.log
maxretry = 3
bantime = 7200

[caddy-authelia]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/authelia-access.log
maxretry = 5
bantime = 3600
```

> **Note:** Authelia already performs its own failed-login *regulation*
> (per-account lockout after repeated failures). This jail is complementary
> defense-in-depth that bans the offending IP at the firewall level, and also
> covers services that don't sit behind Authelia. Neither Authelia nor
> fail2ban provides **geo-blocking** — for country-level blocking or IP
> reputation feeds, consider [CrowdSec](https://www.crowdsec.net/) (a modern
> fail2ban alternative with a Caddy bouncer) or a Caddy GeoIP module.

## Best Practices

1. **Always backup before changes**
2. **Test configuration before reloading** (`caddy validate`)
3. **Monitor fail2ban logs** initially to tune settings
4. **Use strong passwords** for admin interfaces
5. **Keep services updated** (`docker compose pull && docker compose up -d`)
6. **Regular backups** of configuration and data
7. **Use HTTPS** via Caddy for all services
8. **Implement rate limiting** in Caddy for API endpoints

## Quick Reference

### Common Commands

```bash
# Caddy
docker exec -w /etc/caddy caddy caddy reload
docker exec -w /etc/caddy caddy caddy fmt --overwrite
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker logs caddy --tail 50

# Fail2ban
sudo systemctl restart fail2ban
sudo fail2ban-client status caddy-auth
sudo fail2ban-client set caddy-auth unbanip 1.2.3.4
sudo tail -f /var/log/fail2ban.log

# Backup
cp ~/docker/caddy/Caddyfile ~/docker/caddy/Caddyfile.backup
```

### Service Ports

- **ActualBudget**: 5006
- **Authelia**: 9091
- **Caddy**: 80 (HTTP), 443 (HTTPS)

## Support

For issues:
- Caddy documentation: https://caddyserver.com/docs/
- Fail2ban manual: https://www.fail2ban.org/wiki/index.php/MANUAL_0_8
- ActualBudget docs: https://actualbudget.org/docs/
- Authelia docs: https://www.authelia.com/
