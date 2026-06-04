# Vanilla Tweaks — place your ZIPs here

The Minecraft installer detects ZIPs in this folder and offers to install them
automatically. No manual SCP or unzipping required.

## Naming convention

The installer uses filename patterns, so the name must include the right keyword:

| File type | Pattern (case-insensitive) | Example |
|-----------|---------------------------|---------|
| Datapacks | filename contains `datapack` | `datapacks_1.21.zip` |
| Crafting tweaks | filename contains `craft` | `crafting_tweaks_1.21.zip` |

Include the Minecraft version number in the filename so the installer can warn
you if the ZIP version does not match the server version.

## Where to download

Go to <https://vanillatweaks.net/picker/datapacks/> and
<https://vanillatweaks.net/picker/crafting-tweaks/>, select your MC version,
choose your packs, and download the ZIP.

## What the installer does

- **Datapacks ZIP** — unzipped into `<instance>/datapacks-download/`; the itzg
  image auto-installs the individual `.zip` files from `/datapacks/` on startup.
- **Crafting tweaks ZIP** — copied as-is into `<instance>/datapacks-download/`;
  the itzg image handles it the same way.

## Cleanup

ZIPs in this folder are gitignored so they are never committed to the repo.
Delete them after the server is set up, or keep them for the next fresh install.
