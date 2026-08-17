## Inviting additional OpenID users

Enabling OpenID lets any Authelia user on the instance *authenticate*, but
ActualBudget still gates actual access separately: only the account that
completes the very first OpenID login becomes the server owner. Every other
Authelia user has to be invited from inside ActualBudget before their login
is accepted — Authelia successfully authenticating them isn't enough on its
own, and the failure looks the same as a config problem if you don't know
this step exists.

To invite one:
1. Log in as the owner account (the one that did the first OpenID login).
2. Click the **"Server Online"** indicator — the user-management screen only
   opens from there, not from the general Settings page, which is easy to
   miss.
3. Invite the new user by the **exact email address** set for them in
   Authelia's `config/users.yml` — ActualBudget matches the OpenID identity
   to an invited member by email, so any mismatch (typo, casing, different
   domain) fails silently the same way as not being invited at all.
4. Have them log in via OpenID again.
