# Security and Infrastructure Improvements

## Summary of Changes

This document describes the comprehensive security and infrastructure improvements made to the Ubuntu post-installation script.

## Issues Fixed

### 1. Docker Directory Ownership
**Problem:** Docker directories were being created as root, causing permission issues when running Docker without sudo.

**Solution:**
- Added `ensure_docker_dir_ownership()` helper function
- Applied to ALL 25+ services (Immich, Keycloak, ActualBudget, Jellyfin, etc.)
- Fixed disaster recovery path (line 309)
- All Docker directories now properly owned by sudo user

**Impact:** Docker containers can now be managed without requiring root/sudo for every command.

---

### 2. Keycloak Security Overhaul
**Problem:** Weak default passwords, special characters causing issues, development mode in production.

**Solutions Implemented:**

#### Password Requirements
- **Minimum length:** 12 characters (16+ recommended)
- **Character set:** Letters and numbers ONLY (no special characters)
- **Auto-generation:** Press ENTER to generate secure passwords automatically
- **Validation:** Real-time password validation with retry loop

#### Production vs Development Mode
- **Production mode:** Uses `start` command, requires hostname configuration
- **Development mode:** Uses `start-dev` command, relaxed security for testing
- **Hostname support:** Proper `KC_HOSTNAME` configuration for public deployment

#### Environment Variables
- All credentials moved to `.env` file
- Admin password and database password securely stored
- No more hardcoded passwords in docker-compose.yml

**Example Keycloak .env file structure:**
```env
# Keycloak Environment Variables
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=<secure-20-char-password>
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=<secure-32-char-password>
KC_PROXY=edge
KC_HTTP_ENABLED=true
KC_HOSTNAME=auth.yourdomain.com  # (if production mode)
```

---

### 3. Environment Variable Management (.env Files)

**Services Now Using .env Files:**
- ✅ Keycloak (admin + database passwords)
- ✅ ActualBudget (timezone and config)
- ✅ Immich (already had .env)
- ✅ FindMyDevice (already had .env)
- ✅ wg-easy (already had .env)
- ✅ Kopia (already had .env)

**Benefits:**
- Passwords not visible in docker-compose.yml files
- Easy to backup separately from compose files
- Can be excluded from version control
- Easier credential rotation

---

### 4. Caddy2 Reverse Proxy Integration

**Existing Integration:**
All services already include Caddy2 reverse proxy configuration via the `configure_caddy_for_service()` function.

**Features:**
- Automatic HTTPS via Let's Encrypt
- HTTP/2 support
- Security headers (HSTS, X-Frame-Options, etc.)
- JSON logging for fail2ban
- Automatic certificate renewal

**Example Caddy Configuration:**
```
photos.yourdomain.com {
    reverse_proxy localhost:2283

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/photos-access.log
        format json
    }
}
```

---

### 5. Fail2ban Integration

**Existing fail2ban Labels:**
All services already include fail2ban monitoring labels:

```yaml
labels:
  - "io.podman.annotations.label/fail2ban.enable=true"
  - "io.podman.annotations.label/fail2ban.filter=caddy-auth"
```

**Services with fail2ban monitoring:**
- ActualBudget
- Keycloak
- All other internet-facing services

**fail2ban Configuration:**
- Filter: `/etc/fail2ban/filter.d/caddy-auth.conf`
- Jail: `/etc/fail2ban/jail.d/caddy.conf`
- Ban after: 5 failed attempts
- Ban duration: 3600 seconds (1 hour)
- Detection window: 600 seconds

**Detailed Setup:** See `CADDY-FAIL2BAN-SETUP.md` for complete configuration.

---

## Helper Functions Added

### `ensure_docker_dir_ownership(dir1 [dir2 ...])`
Ensures Docker directories are owned by the actual user (not root).

**Usage:**
```bash
mkdir -p "$SERVICE_DIR"
ensure_docker_dir_ownership "$SERVICE_DIR"
```

### `generate_password([length])`
Generates secure alphanumeric passwords (no special characters).

**Usage:**
```bash
PASSWORD=$(generate_password 20)  # 20-character password
```

### `validate_password(password [min_length])`
Validates passwords for Keycloak compatibility.

**Validation Rules:**
- Minimum length (default: 12 characters)
- Alphanumeric only (a-zA-Z0-9)
- Returns 0 if valid, 1 if invalid

**Usage:**
```bash
if validate_password "$USER_PASSWORD" 12; then
    echo "Password accepted"
fi
```

---

## Keycloak Setup Guide

### For ActualBudget on Pikapods

1. **Install Keycloak with production mode:**
   ```bash
   sudo bash ubuntu-post-install.sh
   # Select Keycloak from menu
   # Choose production mode (y)
   # Enter hostname: auth.yourdomain.com
   # Press ENTER to auto-generate secure passwords
   ```

2. **Configure Caddy2:**
   - Script automatically prompts for Caddy configuration
   - Enter your domain (e.g., auth.yourdomain.com)
   - Ensure DNS A record points to your server

3. **Configure DNS:**
   ```
   auth.yourdomain.com  →  Your Server IP
   ```

4. **Access Keycloak:**
   ```
   https://auth.yourdomain.com
   ```

5. **Set up ActualBudget OAuth:**
   - The script automatically creates an OAuth client for ActualBudget
   - Client details saved to: `~/docker/keycloak/actualbudget-oauth.txt`
   - Use these credentials in your Pikapod ActualBudget instance

6. **Configure ActualBudget on Pikapods:**
   - Go to your ActualBudget settings
   - Enable OpenID Connect
   - Enter your Keycloak details:
     - Issuer: `https://auth.yourdomain.com/realms/homelab`
     - Client ID: (from actualbudget-oauth.txt)
     - Client Secret: (from actualbudget-oauth.txt)

### For Other Self-Hosted Services

The script can create generic OAuth clients for other services. After Keycloak installation, you can:

1. Access Keycloak admin console
2. Create new OAuth2/OIDC clients
3. Configure redirect URIs for your services
4. Use the client credentials in your service configuration

**Generic Client Template:**
- Client ID: your-service-name
- Client Type: Confidential
- Standard Flow Enabled: Yes
- Valid Redirect URIs: https://your-service.com/*

---

## Password Requirements Reference

### Keycloak Passwords
- **Minimum:** 12 characters
- **Recommended:** 16+ characters
- **Format:** Alphanumeric only (a-zA-Z0-9)
- **No special characters:** `!@#$%^&*()` etc. are NOT allowed
- **Generation:** Press ENTER for auto-generated secure passwords

### Why No Special Characters?
Keycloak has issues with special characters in certain authentication flows and database connection strings. Restricting to alphanumeric ensures compatibility.

### Password Strength with Alphanumeric Only
- 12 characters: ~62^12 = 3.2 × 10^21 combinations
- 16 characters: ~62^16 = 4.7 × 10^28 combinations
- 20 characters: ~62^20 = 7.0 × 10^35 combinations

This is cryptographically secure for all practical purposes.

---

## Verification Checklist

After running the updated script:

### Docker Ownership
```bash
# Check docker directory ownership
ls -la ~/docker/
# All directories should be owned by your user, not root

# Test docker without sudo
docker ps
# Should work without permission errors
```

### Keycloak
```bash
# Check .env file exists
cat ~/docker/keycloak/.env
# Should contain KEYCLOAK_ADMIN_PASSWORD and POSTGRES_PASSWORD

# Check production mode
cat ~/docker/keycloak/docker-compose.yml | grep command
# Should show "start" for production or "start-dev" for development

# Test access
curl http://localhost:8180/health
# Should return health status
```

### Caddy2
```bash
# Check Caddy is running
docker ps | grep caddy

# Check logs
docker logs caddy

# Test HTTPS redirect
curl -I http://yourdomain.com
# Should redirect to HTTPS
```

### fail2ban
```bash
# Check fail2ban status
sudo fail2ban-client status caddy-auth

# Test ban
# (Make 5 failed login attempts)
sudo fail2ban-client status caddy-auth
# Should show banned IP
```

---

## Migration Guide

If you have existing services:

### Existing ActualBudget
1. Backup existing data: `cp -r ~/docker/actualbudget ~/docker/actualbudget.backup`
2. Run updated script and select "Reconfigure" when prompted
3. New .env file will be created
4. Verify ownership: `ls -la ~/docker/actualbudget`
5. Restart container: `cd ~/docker/actualbudget && docker compose restart`

### Existing Keycloak
1. **IMPORTANT:** Backup your data first!
   ```bash
   cp -r ~/docker/keycloak ~/docker/keycloak.backup
   ```
2. Stop existing container:
   ```bash
   cd ~/docker/keycloak && docker compose down
   ```
3. Run updated script and select Keycloak
4. Choose whether to keep existing data or start fresh
5. If keeping data, manually update .env with your existing passwords
6. Restart: `docker compose up -d`

---

## Troubleshooting

### Permission Denied Errors
```bash
# Fix ownership of all docker directories
sudo chown -R $USER:$USER ~/docker
```

### Keycloak Won't Start
```bash
# Check logs
docker logs keycloak

# Common issues:
# 1. Missing KC_HOSTNAME in production mode
# 2. Database connection failed (check postgres container)
# 3. Port 8180 already in use

# Fix: Edit .env and docker-compose.yml as needed
```

### Caddy Certificate Errors
```bash
# Check Caddy logs
docker logs caddy

# Common issues:
# 1. DNS not pointing to server
# 2. Ports 80/443 not open
# 3. Firewall blocking Let's Encrypt

# Test DNS:
dig auth.yourdomain.com

# Test port accessibility:
sudo ufw status
```

---

## Security Best Practices

1. **Change default passwords:** Even with auto-generation, review and update if needed
2. **Use production mode for Keycloak:** Never use development mode for internet-facing deployments
3. **Enable fail2ban:** Monitor and ban malicious IPs
4. **Regular updates:** Keep containers updated (use Watchtower in notify mode)
5. **Backup .env files:** Store securely, separate from compose files
6. **Use HTTPS everywhere:** Configure Caddy2 for all public services
7. **Limit exposed ports:** Only expose necessary ports to the internet
8. **Monitor logs:** Regular review of Caddy and fail2ban logs

---

## Additional Resources

- **Keycloak Setup Guide:** `KEYCLOAK-SETUP-GUIDE.md`
- **Caddy + fail2ban Setup:** `CADDY-FAIL2BAN-SETUP.md`
- **Main Script:** `ubuntu-post-install.sh`
- **Caddy Helper:** `caddy-setup-helper.sh`

---

## Support

If you encounter issues:

1. Check logs: `docker logs <container-name>`
2. Verify ownership: `ls -la ~/docker`
3. Review this document for troubleshooting steps
4. Check existing documentation in repository

---

**Last Updated:** 2026-01-13
**Script Version:** Latest (with security improvements)
