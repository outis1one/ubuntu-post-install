## Getting ntfy notifications to actually fire (multi-user setup)

If `.env` has `SMS_HTTP_URL` set (the ntfy setup above), a Traccar user still
needs two separate things configured on their own account before they'll
receive anything — this trips people up because both are per-user, not
global, and neither is optional:

1. **Their own Phone field set to their ntfy topic.**
   Settings → Users → click the user → Phone field → their topic name.
   Different users can share one topic or each get their own, depending on
   whether you want them to see the same alerts or separate ones.

2. **The notification rule linked to that user.**
   Creating a notification (e.g. "Geofence exited" with the SMS channel
   checked) does not automatically apply to every user — it has to be
   attached. Go to **Settings → Users → click the user → Connections tab**,
   and select which Devices, Geofences, Notifications, and Users are linked
   to that account. A user only gets alerts for notifications, devices, and
   geofences actually selected there.

Both steps are required per account. There's no way to configure this once
for everyone — a non-admin user who can't see a device/geofence/notification
in their own Connections list won't get notified about it, even if the admin
configured everything else correctly.

### Why "TEST CHANNELS" can return success with nothing arriving

The `TEST CHANNELS` button only ever tests the **currently logged-in
session's user** — there's no way for an admin to test "as" another account.
Worse, it can report success (HTTP 204) even when nothing was sent: Traccar's
SMS notificator silently no-ops (no error, no log line) if that user's Phone
field is empty, since `HttpSmsClient` — which is what actually calls out to
ntfy and would throw on failure — never gets invoked in that case. A 204
from this button only proves the request loop completed, not that ntfy was
reached.

To verify a specific account actually works, log in **as that account** and
click the button there, or just trigger a real matching event (e.g. cross a
linked geofence) and watch for the notification.
