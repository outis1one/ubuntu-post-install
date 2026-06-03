# Install Script Variants

This repo ships the post-install script in three tiers, for both Ubuntu 24.04
and 26.04. Pick **one** and run it — they are mutually exclusive (each is a
complete, standalone script).

| File | Keycloak | SSO | Intrusion prevention |
|------|----------|-----|----------------------|
| `ubuntu-post-install-<ver>.sh` | ✅ included | Keycloak **or** Authelia | fail2ban (SSH + Caddy) |
| `ubuntu-post-install-<ver>-no-keycloak.sh` | ❌ removed | Authelia | fail2ban (SSH + Caddy) |
| `ubuntu-post-install-<ver>-crowdsec.sh` | ❌ removed | Authelia | **CrowdSec** (replaces fail2ban) |

`<ver>` is `24.04` or `26.04`.

> New services are added to the **`-crowdsec`** tier only (the current tip of
> the evolution); the original and `-no-keycloak` scripts are frozen as
> historical snapshots. For example, **Home Assistant** (home-automation hub,
> port 8123) is available in the `-crowdsec` variants. It ships with a
> `trusted_proxies` config pre-seeded so it works behind the Caddy reverse
> proxy out of the box.

## Which one?

- **Original (`.sh`)** — unchanged baseline, kept for fallback. Still offers
  Keycloak in the menu.
- **`-no-keycloak`** — same as original but with Keycloak fully removed.
  Authelia is the SSO + 2FA option. Use this if you never got Keycloak running
  and have standardized on Authelia.
- **`-crowdsec`** — builds on `-no-keycloak` and swaps fail2ban out for
  [CrowdSec](https://www.crowdsec.net/):
  - SSH brute-force protection (CrowdSec reads `/var/log/auth.log` via the
    `crowdsecurity/sshd` collection)
  - Caddy HTTP auth abuse (the `crowdsecurity/caddy` collection + a log
    acquisition at `/etc/crowdsec/acquis.d/caddy.yaml`)
  - Enforcement via `crowdsec-firewall-bouncer-iptables`
  - **Geo-blocking + community IP-reputation blocklists** — the capability
    that fail2ban and Authelia both lack
  - **Optional ntfy alerts on bans** — when configuring CrowdSec the script
    can wire up an [ntfy](https://ntfy.sh/) push notification (via CrowdSec's
    HTTP notification plugin). It writes `/etc/crowdsec/notifications/ntfy.yaml`
    and references it from the default profile in
    `/etc/crowdsec/profiles.yaml`. The same script can also install a
    self-hosted **ntfy server** (separate menu option), so alerts can stay on
    your own infrastructure.

### A note on "notification of failed attempts"

CrowdSec alerts fire on a **ban decision** — i.e. once an IP crosses the
failed-attempt threshold for a scenario (e.g. `crowdsecurity/ssh-bf`), not on
every individual failed login. That gives you one actionable "X banned for Y"
push instead of a flood. To alert on a single failed login you'd lower the
scenario threshold or write a custom scenario, but the ban-level alert is the
recommended default.

Authelia, by contrast, only sends **email/SMTP** notifications (for password
reset and 2FA device registration) — it has no built-in "failed login" push,
which is why CrowdSec → ntfy is the path used here.

## Notes on the security layers

- **Authelia** handles per-account failed-login *regulation* (lockout). It does
  **not** do geo-blocking.
- **fail2ban** bans IPs at the firewall based on Caddy log patterns
  (401/403/429). No geo-blocking, not credential-aware.
- **CrowdSec** covers SSH + Caddy from a single agent, adds geo/ASN enrichment
  and crowd-sourced reputation, and is the modern successor to fail2ban.

Useful CrowdSec commands after install:

```bash
sudo cscli metrics              # overview / parsing health
sudo cscli decisions list       # current bans
sudo cscli alerts list          # detections
sudo cscli decisions delete --ip <IP>   # unban
```
