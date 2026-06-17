# Changelog

## Version 1.0.1 - (17.06.2026)

> fix(rocrail): cap shutdown wait below supervisor stop grace

## Version 1.0.0 - (12.05.2026)

> Initial public release.

Highlights:

- **Wrapper-only architecture.** The container is built locally by your
  Home Assistant Supervisor from this repository's `Dockerfile`. No
  prebuilt image is published — this repository neither contains nor
  redistributes the Rocrail server binary.
- **Runtime Rocrail fetch.** On first start the add-on downloads the
  current Rocrail snapshot for your architecture from `rocrail.online`
  into `/data/rocrail/`. Subsequent starts reuse the installed copy.
- **Decoupled update lifecycle.** Add-on (wrapper) updates do not touch
  the installed Rocrail revision. A new Rocrail revision is applied
  only when you enable the `check_and_install_rocrail_update` option
  and restart the add-on (one-shot, auto-resets via the Supervisor API).
- **Home Assistant persistent notification** when upstream has a newer
  Rocrail revision than what's installed locally — throttled to once
  per 24 hours and suppressed once you've been told about that specific
  revision.
- **Rocweb via Home Assistant Ingress** with same-path WebSocket
  routing patched in at startup, so live updates show up directly in
  the HA sidebar without round-tripping through `homeassistant:8123`.
- **Workspace + share-tree under `/share/rocrail/`** — manageable via
  the Samba or File Editor add-ons. Each workspace gets its own
  `backup/` for Rocrail's plan-rotation snapshots.
- **Decoder specs preserved across updates.** `/data/rocrail/decspecs/`
  is seeded on first install and never overwritten on later Rocrail
  updates, so user customizations survive.
- **MIT-licensed wrapper code.** Rocrail itself remains proprietary
  (Copyright Robert Jan Versluis, Rocrail.net — Commercial usage needs
  permission) and is downloaded by your container directly from
  rocrail.online.
