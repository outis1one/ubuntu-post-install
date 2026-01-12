# Keycloak Setup Guide
## Complete Manual and Automated Configuration Guide

This guide explains Keycloak concepts and how to configure it both automatically (via the script) and manually (via the web UI).

---

## Table of Contents
1. [What is Keycloak?](#what-is-keycloak)
2. [Key Concepts](#key-concepts)
3. [Automated Setup (via Script)](#automated-setup)
4. [Manual Setup (via Web UI)](#manual-setup)
5. [Configuring External Services](#configuring-external-services)
6. [Reconfiguration & Adding Realms](#reconfiguration)
7. [Common Use Cases](#common-use-cases)
8. [Troubleshooting](#troubleshooting)

---

## What is Keycloak?

Keycloak is an **Identity and Access Management (IAM)** system that provides:
- **Single Sign-On (SSO)**: Log in once, access all your services
- **User Management**: Create, manage, and authenticate users in one place
- **OAuth2/OIDC**: Industry-standard authentication for web apps
- **Social Login**: Allow login via Google, GitHub, etc.
- **Multi-Factor Authentication (MFA)**: Add extra security with 2FA/TOTP
- **LDAP/Active Directory Integration**: Connect to existing user directories

**Think of Keycloak as:** A centralized login system for all your self-hosted services.

---

## Key Concepts

### 1. **Realm**
A **realm** is an isolated container for users, clients, and configuration.

**Analogy:** Think of a realm like a "company" or "organization" in Keycloak.

**Why you need it:**
- The default `master` realm is for Keycloak admin only
- You create a separate realm (e.g., `homelab`) for your actual users and applications
- Realms are completely isolated - users in one realm can't access another

**Example:**
- `master` realm: Only for Keycloak administrators
- `homelab` realm: For your personal services (ActualBudget, Jellyfin, etc.)
- `family` realm: Separate realm for family members (optional)

### 2. **OAuth2/OpenID Connect (OIDC) Client**
A **client** is an application that uses Keycloak for authentication.

**Analogy:** Each service (ActualBudget, Jellyfin, etc.) is a "client" that asks Keycloak "Is this user allowed to log in?"

**Required information:**
- **Client ID**: Name of the application (e.g., `actualbudget`)
- **Client Secret**: Password for the application (auto-generated, 64-char hex)
- **Redirect URIs**: Where Keycloak sends users after login
  - Example: `https://budget.yourdomain.com/*`
  - Must match EXACTLY or login will fail

**Flow:**
1. User clicks "Login" in ActualBudget
2. ActualBudget redirects to Keycloak: `https://auth.yourdomain.com/login`
3. User logs in with username/password
4. Keycloak redirects back to ActualBudget: `https://budget.yourdomain.com/callback`
5. ActualBudget gets user info and logs them in

### 3. **Users**
A **user** is a person who can log in to your services.

**User attributes:**
- Username (required, unique)
- Email (optional but recommended)
- First name / Last name (optional)
- Password (set via Credentials tab)
- Email verified (set to true to skip verification)
- Enabled (must be true for user to log in)

### 4. **Redirect URIs**
**Critical concept:** The redirect URI is where Keycloak sends the user after successful login.

**Common mistakes:**
- ❌ `http://localhost:5006` (won't work for external services)
- ❌ `https://budget.example.com` (missing wildcard or path)
- ✅ `https://budget.example.com/*` (correct - allows all paths)

**For external services (like Pikapod):**
- Pikapod gives you a URL like: `https://actualbudget-abc123.pikapod.net`
- Your redirect URI: `https://actualbudget-abc123.pikapod.net/*`
- Your Keycloak URL: `https://auth.yourdomain.com` (must be publicly accessible)

---

## Automated Setup (via Script)

The script automates everything for you. Here's what it does:

### Step 1: Install Keycloak
```bash
./ubuntu-post-install.sh
# Select KEYCLOAK in whiptail menu
```

Prompts:
- Admin password (for Keycloak admin console)
- Database password (for PostgreSQL)

### Step 2: Automated Configuration
```
Configure Keycloak with initial realm and clients? (y/n): y
```

This automatically:
1. ✅ Waits for Keycloak to start (health check)
2. ✅ Logs in using admin CLI (`kcadm.sh`)
3. ✅ Creates a realm (e.g., `homelab`)
4. ✅ Creates OAuth client for ActualBudget (if selected)
5. ✅ Creates generic OAuth client template
6. ✅ Saves all credentials to `~/docker/keycloak/*.txt`
7. ✅ Optionally creates initial user

### Step 3: What Gets Created

**Realm:** `homelab` (or your custom name)

**ActualBudget OAuth Client:**
- Client ID: `actualbudget`
- Client Secret: (saved to `actualbudget-oauth.txt`)
- Redirect URIs:
  - `http://localhost:5006/*` (local development)
  - `http://yourdomain.com:5006/*` (local with domain)
  - `https://yourdomain.com/*` (production - any subdomain)
  - `https://budget.yourdomain.com/*` (specific subdomain)

**Generic OAuth Client:**
- Client ID: `generic-app`
- Client Secret: (saved to `generic-oauth.txt`)
- Can be cloned for other services

**Initial User:**
- Username, email, password you provide
- Immediately active
- Can log in to all services

### Step 4: Configuration Files

All credentials saved to:
```
~/docker/keycloak/actualbudget-oauth.txt
~/docker/keycloak/generic-oauth.txt
```

These files contain:
- Client ID
- Client Secret
- Authorization URL
- Token URL
- User Info URL
- Instructions for configuring each service

---

## Manual Setup (via Web UI)

If you prefer to configure Keycloak manually, or want to add services later:

### Access Admin Console
```
URL: http://localhost:8180/admin
Username: admin
Password: [your admin password]
```

### Step 1: Create a Realm

1. **Click dropdown** in top-left corner (shows "Master")
2. **Click "Create Realm"**
3. **Realm name:** `homelab` (or your choice)
4. **Click "Create"**

**Settings to configure:**
- **Login tab:**
  - ✅ User registration: OFF (you create users manually)
  - ✅ Forgot password: ON (allows password resets)
  - ✅ Remember me: ON (convenience)
  - ✅ Login with email: ON (users can use email instead of username)

- **Email tab:** (optional, for password resets)
  - Configure SMTP settings if you want email features

### Step 2: Create an OAuth2 Client (for ActualBudget)

1. **Switch to your realm** (`homelab`) via dropdown
2. **Go to Clients** (left menu)
3. **Click "Create client"**

**General Settings:**
- **Client type:** OpenID Connect
- **Client ID:** `actualbudget`
- **Name:** `ActualBudget`
- **Description:** `Personal Finance Management`
- **Click "Next"**

**Capability config:**
- ✅ Client authentication: ON (creates a secret)
- ✅ Authorization: OFF (not needed)
- ✅ Standard flow: ON (authorization code flow)
- ✅ Direct access grants: ON (allows username/password)
- ❌ Implicit flow: OFF (deprecated)
- ❌ Service accounts: OFF (not needed for web apps)
- **Click "Next"**

**Login settings:**

**Important: Adjust these for your setup!**

**For local ActualBudget:**
```
Root URL: http://localhost:5006
Home URL: http://localhost:5006
Valid redirect URIs:
  http://localhost:5006/*
  http://localhost:5006/callback

Valid post logout redirect URIs: +

Web origins:
  http://localhost:5006
```

**For external ActualBudget (Pikapod, etc.):**
```
Root URL: https://actualbudget-abc123.pikapod.net
Home URL: https://actualbudget-abc123.pikapod.net
Valid redirect URIs:
  https://actualbudget-abc123.pikapod.net/*
  https://actualbudget-abc123.pikapod.net/callback

Valid post logout redirect URIs: +

Web origins:
  https://actualbudget-abc123.pikapod.net
```

**For self-hosted with domain:**
```
Root URL: https://budget.yourdomain.com
Home URL: https://budget.yourdomain.com
Valid redirect URIs:
  https://budget.yourdomain.com/*
  https://budget.yourdomain.com/callback

Valid post logout redirect URIs: +

Web origins:
  https://budget.yourdomain.com
```

4. **Click "Save"**

### Step 3: Get Client Secret

1. **Go to "Credentials" tab**
2. **Copy "Client secret"** (you'll need this for ActualBudget)
3. **Save it somewhere safe!**

### Step 4: Create a User

1. **Go to Users** (left menu)
2. **Click "Create user"**

**User details:**
- **Username:** `john` (required)
- **Email:** `john@example.com` (optional but recommended)
- **Email verified:** ✅ ON (skip email verification)
- **First name:** `John`
- **Last name:** `Doe`
- **Enabled:** ✅ ON (user can log in)
- **Click "Create"**

**Set password:**
1. **Go to "Credentials" tab**
2. **Click "Set password"**
3. **Enter password** (twice)
4. **Temporary:** ❌ OFF (user won't be forced to change it)
5. **Click "Save"**
6. **Confirm** in popup

### Step 5: Test Login

1. **Go to Realm Settings** → **Endpoints**
2. **Click "OpenID Endpoint Configuration"** (opens JSON)
3. **Find:** `authorization_endpoint`
4. **Copy URL** and open in browser
5. **Add:** `?client_id=actualbudget&response_type=code&redirect_uri=http://localhost:5006/callback`
6. **Log in** with your user
7. **You should see:** Redirect to callback URL (may error if ActualBudget not configured, but login works)

---

## Configuring External Services

### Keycloak MUST be Publicly Accessible

**Critical:** For external services like Pikapod, your Keycloak must be accessible from the internet.

### Requirements:
1. ✅ **Domain name** (e.g., `yourdomain.com`)
2. ✅ **DNS A record** pointing to your server
3. ✅ **Caddy reverse proxy** with HTTPS
4. ✅ **Port 80/443 open** in firewall
5. ✅ **Keycloak accessible** at `https://auth.yourdomain.com`

### Setup Caddy for Keycloak

**Add to Caddyfile:**
```caddy
auth.yourdomain.com {
    log {
        output file /var/log/caddy/keycloak-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:8180

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

**Reload Caddy:**
```bash
cd ~/docker/caddy
docker exec -w /etc/caddy caddy caddy reload
```

**Test:**
```
https://auth.yourdomain.com/admin
```

### Configure DNS

**Add A record:**
```
auth.yourdomain.com  →  [Your Server IP]
```

**Or use CNAME:**
```
auth  →  yourdomain.com
```

### Example: ActualBudget on Pikapod

**Scenario:**
- Keycloak: `https://auth.yourdomain.com` (your server)
- ActualBudget: `https://actualbudget-abc123.pikapod.net` (Pikapod)

**In Keycloak:**

1. **Create client:** `actualbudget-pikapod`
2. **Redirect URIs:**
   ```
   https://actualbudget-abc123.pikapod.net/*
   https://actualbudget-abc123.pikapod.net/callback
   ```
3. **Web origins:**
   ```
   https://actualbudget-abc123.pikapod.net
   ```

**In ActualBudget (Pikapod):**

Settings → Authentication:
```
Client ID: actualbudget-pikapod
Client Secret: [from Keycloak credentials tab]

Authorization URL: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/auth
Token URL: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/token
User Info URL: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/userinfo
```

**Flow:**
1. User visits `https://actualbudget-abc123.pikapod.net`
2. Clicks "Login"
3. Redirects to `https://auth.yourdomain.com/realms/homelab/...`
4. User logs in
5. Redirects back to `https://actualbudget-abc123.pikapod.net/callback`
6. User is logged in!

---

## Reconfiguration & Adding Realms

You can re-run the script to add more realms or clients!

### Option 1: Re-run the Script

```bash
cd ~/docker/keycloak
docker compose down
cd ~
./ubuntu-post-install.sh
# Select KEYCLOAK again
# Choose "Configure Keycloak..." → Yes
# Enter new realm name: "family"
# Create new users
```

**This creates:**
- New realm with new users
- New OAuth clients for that realm
- Separate from your existing realm

### Option 2: Add Realm Manually

**Via Web UI:**
1. Go to admin console
2. Click realm dropdown
3. "Create Realm"
4. Name: `family`
5. Repeat client/user creation steps

### Option 3: Use Script Helper

The script can be extended to add a helper:

```bash
cd ~/docker/keycloak

# Login to admin CLI
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password [YOUR_ADMIN_PASSWORD]

# Create new realm
docker exec keycloak /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=family \
  -s enabled=true

# Create new client
docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r family \
  -s clientId=my-new-service \
  -s enabled=true \
  -s clientAuthenticatorType=client-secret \
  -s secret=$(openssl rand -hex 32) \
  -s 'redirectUris=["https://service.yourdomain.com/*"]'

# Create new user
docker exec keycloak /opt/keycloak/bin/kcadm.sh create users -r family \
  -s username=alice \
  -s email=alice@example.com \
  -s enabled=true

# Set password
docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password -r family \
  --username alice \
  --new-password 'AlicePassword123!'
```

---

## Common Use Cases

### Use Case 1: All Local Services
**Setup:**
- Keycloak: `http://localhost:8180`
- ActualBudget: `http://localhost:5006`
- Jellyfin: `http://localhost:8096`

**Configuration:**
- No domain needed
- Use `localhost` URLs everywhere
- Redirect URIs: `http://localhost:PORT/*`

### Use Case 2: Self-Hosted with Domain
**Setup:**
- Keycloak: `https://auth.yourdomain.com`
- ActualBudget: `https://budget.yourdomain.com`
- Jellyfin: `https://jellyfin.yourdomain.com`

**Configuration:**
- Requires domain + Caddy
- Use HTTPS URLs
- Redirect URIs: `https://service.yourdomain.com/*`

### Use Case 3: Mixed (Local + External)
**Setup:**
- Keycloak: `https://auth.yourdomain.com` (self-hosted)
- ActualBudget: `https://actualbudget-abc.pikapod.net` (Pikapod)
- Jellyfin: `https://jellyfin.yourdomain.com` (self-hosted)

**Configuration:**
- Keycloak MUST be publicly accessible
- Each service gets its own client
- ActualBudget redirect: `https://actualbudget-abc.pikapod.net/*`
- Jellyfin redirect: `https://jellyfin.yourdomain.com/*`

---

## Troubleshooting

### Issue: "Invalid redirect URI"
**Cause:** Redirect URI in Keycloak doesn't match what the app is using.

**Fix:**
1. Check error message for actual redirect URI
2. Add EXACT URI to Keycloak client settings
3. Include wildcard: `https://domain.com/*`

### Issue: "Client not found"
**Cause:** Client ID doesn't match.

**Fix:**
1. Check client ID in Keycloak
2. Ensure it matches exactly in application
3. Case-sensitive!

### Issue: "Invalid client secret"
**Cause:** Wrong secret or expired.

**Fix:**
1. Go to Keycloak → Clients → Credentials
2. Copy secret again (or regenerate)
3. Update in application

### Issue: External service can't reach Keycloak
**Cause:** Keycloak not publicly accessible.

**Fix:**
1. Ensure Caddy is running: `docker ps | grep caddy`
2. Check DNS: `dig auth.yourdomain.com`
3. Test URL: `curl https://auth.yourdomain.com`
4. Check firewall: `sudo ufw status` (80/443 open?)

### Issue: Login succeeds but redirect fails
**Cause:** CORS or redirect URI mismatch.

**Fix:**
1. Add domain to "Web Origins" in client settings
2. Check redirect URI includes protocol (https://)
3. Check for typos in domain name

### Issue: Can't login to Keycloak admin console
**Cause:** Container not started or wrong password.

**Fix:**
```bash
# Check if running
docker ps | grep keycloak

# Check logs
docker logs keycloak --tail 50

# Restart
cd ~/docker/keycloak
docker compose restart

# Reset admin password (if needed)
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password NEW_PASSWORD_HERE
```

---

## Quick Reference

### Important URLs

**Local:**
```
Admin Console: http://localhost:8180/admin
Realm Endpoints: http://localhost:8180/realms/{realm-name}/.well-known/openid-configuration
```

**Production:**
```
Admin Console: https://auth.yourdomain.com/admin
Realm Endpoints: https://auth.yourdomain.com/realms/{realm-name}/.well-known/openid-configuration
```

### OAuth URLs (for realm "homelab")

**Local:**
```
Authorization: http://localhost:8180/realms/homelab/protocol/openid-connect/auth
Token: http://localhost:8180/realms/homelab/protocol/openid-connect/token
User Info: http://localhost:8180/realms/homelab/protocol/openid-connect/userinfo
Logout: http://localhost:8180/realms/homelab/protocol/openid-connect/logout
```

**Production:**
```
Authorization: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/auth
Token: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/token
User Info: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/userinfo
Logout: https://auth.yourdomain.com/realms/homelab/protocol/openid-connect/logout
```

### Common Commands

```bash
# Start Keycloak
cd ~/docker/keycloak
docker compose up -d

# Stop Keycloak
docker compose down

# View logs
docker logs keycloak -f

# Access shell
docker exec -it keycloak bash

# Login to admin CLI
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password YOUR_PASSWORD

# Export realm configuration (backup)
docker exec keycloak /opt/keycloak/bin/kc.sh export \
  --dir /opt/keycloak/data/export \
  --realm homelab

# Copy export to host
docker cp keycloak:/opt/keycloak/data/export ./backup/
```

---

## Summary

**Keycloak provides:**
- ✅ Single Sign-On for all your services
- ✅ Centralized user management
- ✅ OAuth2/OIDC authentication
- ✅ Works with local and external services
- ✅ Professional-grade security

**Automated setup does:**
- ✅ Creates realm
- ✅ Creates OAuth clients
- ✅ Creates initial user
- ✅ Saves all credentials
- ✅ Ready to use immediately

**Manual setup allows:**
- ✅ Full control over configuration
- ✅ Multiple realms (family, work, etc.)
- ✅ Custom client settings
- ✅ Advanced features (LDAP, MFA, etc.)

**For external services:**
- ✅ Keycloak must be publicly accessible
- ✅ Use Caddy with HTTPS
- ✅ Configure proper redirect URIs
- ✅ Test OAuth flow before production

For questions or issues, check the Keycloak documentation: https://www.keycloak.org/documentation
