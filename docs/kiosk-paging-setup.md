# Auto-answer paging kiosks (baresip)

How to set up a dedicated, always-on auto-answer intercom/paging station for
`services/asterisk.sh`, and how to mix it into a Ring Group alongside phones
that ring normally.

This covers the option that already works today: a lightweight native SIP
client (`baresip`) on a separate small Linux machine. A browser-based
("webpage") auto-answer client is possible in principle — any WebRTC SIP JS
library can answer a call programmatically with none of a mobile phone's
OS-level call-screen restrictions — but this server has no WebRTC/WebSocket
transport configured, and building one is real new work (a `transport-wss`
PJSIP transport, a Caddy WSS passthrough, a custom webpage). Not covered
here.

## What this actually is

Easy Asterisk (the vendor project `services/asterisk.sh` installs) ships a
`kiosk` device category, described in its own source as *"Fixed auto-answer
intercoms"* / *"Fixed wall-mount tablets & intercoms."* Installing it sets
up:

- `baresip` — a real, fully-scriptable Linux SIP user agent, not a phone app.
  Its answer-mode is plain client config, so nothing about the kiosk's OS
  can silently override it into requiring a manual tap the way a mobile
  phone app often does.
- An optional push-to-talk daemon (`kiosk-ptt`) — the mic stays muted by
  default (true one-way intercom behavior) and a PTT button unmutes it to
  talk back.

None of this runs inside the Asterisk container. It runs on a **separate**
machine — an old PC, a Raspberry Pi, a cheap mini-PC, anything running
Ubuntu/Debian with a sound card. The vendor script explicitly refuses to
install baresip when it detects it's running inside Docker
(`install_baresip_packages()`: *"Docker mode: Baresip not applicable"*) —
that check is about wherever you happen to run the script, so make sure
you're running it on the kiosk machine itself, not on the Asterisk server's
droplet.

## Set it up

1. **Create an extension for the kiosk** in the Security Dashboard's
   Extensions tab first (Easy Asterisk device setup section), same as any
   other device. Leave "Mobile" unchecked unless the kiosk is genuinely on a
   cellular connection — a wired/Wi-Fi kiosk on the LAN or a stable remote
   network doesn't need the RTP NAT-keepalive tuning that checkbox adds.
   Note the extension number and the auto-generated password shown once at
   the top of the card.

2. **Get the vendor script onto the kiosk machine.** It's vendored in this
   repo at `vendor/easy-asterisk/easy-asterisk-v0.10.0.sh` — copy it over
   (`scp`, a USB drive, whatever's convenient) and run it there:

   ```bash
   sudo bash easy-asterisk-v0.10.0.sh
   ```

3. **Choose the client-install path** (not server, not full — this machine
   isn't running Asterisk itself). When prompted:
   - **Server (IP or domain)**: your Asterisk box's public IP or domain
     (whatever `asterisk.sh` set up — an FQDN here also turns on TLS
     automatically).
   - **SIP Password**: the password from step 1.
   - **Answer Mode**: choose **1) Auto**.
   - **Extension**: the extension number from step 1.

   It installs `baresip`, PipeWire (for audio), and enables the relevant
   systemd services.

4. **Log out and back in** (or reboot) if audio doesn't work immediately —
   the installer adds the kiosk user to the audio group, which needs a
   fresh session to take effect. Check with `pactl list sources short` if
   in doubt.

5. **(Optional) Configure push-to-talk** from the vendor script's own menu:
   Main Menu → Client Management → Configure PTT Button. Without this, the
   kiosk just stays open-mic (fine for a simple listen-and-respond intercom;
   PTT is for anything noisier or more deliberate about when it transmits).

## Using it in a Ring Group

No special group type needed for the mix — see the Ring Groups card's own
"Ring vs Page, and mixing auto-answer devices" help text for why. Short
version: create (or edit) a plain **Ring**-type group, add the kiosk's
extension as a member alongside regular phones' extensions. Dialing the
group's number rings everyone simultaneously; the kiosk answers instantly
because *it's* configured to, ordinary phones just ring until a person
picks up or the kiosk's already live. `Page`-type groups still exist for
signaling auto-answer to devices you don't control the client config of —
not needed for a kiosk you set up yourself this way.

## Troubleshooting

```bash
journalctl -t kiosk-ptt -f              # PTT daemon logs, if configured
systemctl --user status baresip         # run as the kiosk's own Linux user
pactl list sources short                # confirm the mic is visible to PipeWire
```

If the kiosk never answers: confirm it actually registered (`baresip`'s own
CLI shows registration status), and double check the extension/password
match what the dashboard generated — a stale or mistyped password here
fails silently from the dashboard's side, since it has no visibility into a
device that was never issued through it in the first place.
