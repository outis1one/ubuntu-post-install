# Security and Infrastructure Improvements

## Summary of Changes

This document describes the comprehensive security and infrastructure improvements made to the Ubuntu post-installation script.

## Issues Fixed

### 1. Docker Directory Ownership
**Problem:** Docker directories were being created as root, causing permission issues when running Docker without sudo.

**Solution:**
- Added `ensure_docker_dir_ownership()` helper function
- Applied to ALL 25+ services (Immich, ActualBudget, Jellyfin, etc.)
- Fixed disaster recovery path (line 309)
- All Docker directories now properly owned by sudo user

**Impact:** Docker containers can now be managed without requiring root/sudo for every command.

---

### 2. Password & Credential Management
**Problem:** Weak default passwords and credentials hardcoded in compose files.

**Solutions Implemented:**

#### Password Requirements
- **Minimum length:** 12 characters (16+ recommended)
- **Character set:** Letters and numbers ONLY (no special characters)
- **Auto-generation:** Press ENTER to generate secure passwords automatically
- **Validation:** Real-time password validation with retry loop

#### Generated Secrets
- Services that need cryptographic secrets generate them automatically (e.g. Authelia's JWT, session, and storage secrets via `openssl rand`).

#### Environment Variables
- All credentials moved to `.env` file
- Passwords and secrets securely stored
- No more hardcoded passwords in docker-compose.yml

---

### 3. Environment Variable Management (.env Files)

**Services Now Using .env Files:**
- ✅ Authelia (JWT/session/storage secrets + SMTP password)
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
- Authelia
- All other internet-facing services

**fail2ban Configuration:**
- Filter: `/etc/fail2ban/filter.d/caddy-auth.conf`
- Jail: `/etc/fail2ban/jail.d/caddy.conf`
- Ban after: 5 failed attempts
- Ban duration: 3600 seconds (1 hour)
- Detection window: 600 seconds

**Note:** When Authelia is in use, it provides its own failed-login regulation
(account lockout after repeated failures). The Caddy fail2ban jail is
complementary defense-in-depth at the HTTP layer. See
`CADDY-FAIL2BAN-SETUP.md` for complete configuration.

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
Validates passwords for compatibility (alphanumeric only).

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

## Password Requirements Reference

### Password Rules
- **Minimum:** 12 characters
- **Recommended:** 16+ characters
- **Format:** Alphanumeric only (a-zA-Z0-9)
- **No special characters:** `!@#$%^&*()` etc. are NOT allowed
- **Generation:** Press ENTER for auto-generated secure passwords

### Why No Special Characters?
Some services and database connection strings mishandle special characters in
certain authentication flows. Restricting to alphanumeric ensures broad
compatibility while remaining cryptographically strong.

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

---

## Troubleshooting

### Permission Denied Errors
```bash
# Fix ownership of all docker directories
sudo chown -R $USER:$USER ~/docker
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
2. **Enable fail2ban:** Monitor and ban malicious IPs
3. **Regular updates:** Keep containers updated (use Watchtower in notify mode)
4. **Backup .env files:** Store securely, separate from compose files
5. **Use HTTPS everywhere:** Configure Caddy2 for all public services
6. **Limit exposed ports:** Only expose necessary ports to the internet
7. **Monitor logs:** Regular review of Caddy and fail2ban logs

---

## Additional Resources

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
