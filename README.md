# Rocrail Home Assistant Add-on

A Home Assistant add-on that runs the [Rocrail](https://wiki.rocrail.net/)
model-railroad control server. Rocweb is available directly in the HA
sidebar via Ingress; Rocview / andRoc / custom integrations connect on
TCP port 8051.

## Quick install

1. **Settings → Add-ons → Add-on Store → ⋮ → Repositories**
2. Paste `https://github.com/magliaral/ha-addon-rocrail` → Add
3. Pick **Rocrail** from the list → **Install** → **Start**

The first start takes ~30–60 s while the add-on downloads the current
Rocrail snapshot from `rocrail.online` into `/data/rocrail/`. Subsequent
starts reuse the local copy.

## How it works

- **Local build.** Your Home Assistant Supervisor builds the container
  from this repository's `Dockerfile`. No prebuilt images on GHCR.
- **Runtime Rocrail fetch.** The Rocrail server itself is downloaded
  from `rocrail.online` by your own container on first start. This repo
  does not ship or redistribute the Rocrail binary.
- **Decoupled updates.** A wrapper update (this repo) rebuilds the
  container but leaves your installed Rocrail revision untouched. A
  Rocrail update happens only when you explicitly trigger it; HA shows
  a persistent notification when a newer upstream revision is available.
- **Ingress Rocweb.** Live updates appear in the HA sidebar — no
  client-side configuration needed.

| HA platform    | Container arch | Rocrail build       |
|----------------|----------------|---------------------|
| HA Yellow, RPi | aarch64        | `debian13-ARM64`    |
| Intel NUC, x86 | amd64          | `debian11-i64`      |

## Configuration

| Option                              | Default   | Description                                                |
|-------------------------------------|-----------|------------------------------------------------------------|
| `log_level`                         | `info`    | trace / debug / info / warning / error                     |
| `workspace`                         | `default` | Workspace folder name directly under `/share/rocrail/`     |
| `rocweb_port`                       | `8080`    | Rocweb HTTP port (Ingress)                                 |
| `client_protocol_port`              | `8051`    | TCP port for Rocview, andRoc, integrations                 |
| `support_key`                       | (empty)   | Paste `lic.dat` contents to unlock unlimited Rocweb        |
| `check_and_install_rocrail_update`  | `false`   | One-shot toggle: fetch + install latest Rocrail on restart |

Full details, workspace tutorial, custom images and SVG themes:
see [`rocrail/README.md`](rocrail/README.md).

## Updating Rocrail

When a newer Rocrail revision becomes available upstream, you get a
persistent notification in Home Assistant. To apply it: enable
`check_and_install_rocrail_update` in the add-on options, restart the
add-on. The toggle is one-shot — the add-on flips it back off after
the install. Your `/data/rocrail/decspecs/` (decoder specs) is
preserved across updates.

## License & legal

The wrapper code in this repository — `Dockerfile`, `run.sh`,
`config.yaml`, scripts, CI workflows — is licensed under the **MIT
License**. See [LICENSE](LICENSE).

The Rocrail server itself is a separate proprietary work:

> Copyright (c) 2002 Robert Jan Versluis, Rocrail.net.
> All rights reserved. Commercial usage needs permission.

See <https://wiki.rocrail.net/doku.php?id=licence-en>. This add-on
does not redistribute the Rocrail binary — your container downloads
it directly from `rocrail.online` when first started.

If you run a model railroad **commercially** (museum, paid demo
layout, commercial event), you need separate permission from
Rocrail.net via their forum. The personal `lic.dat` Support Key
(€12/year donation) is per-user; the add-on neither stores nor
transmits keys, it only passes a locally provided key into the
Rocrail server at startup.
