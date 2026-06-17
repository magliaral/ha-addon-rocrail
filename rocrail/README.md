# Rocrail Add-on

Home Assistant add-on that runs the [Rocrail](https://wiki.rocrail.net/)
model-railroad control server as a container in HA OS. The Rocrail
server itself is built and maintained upstream at rocrail.net — this
add-on is a thin wrapper that downloads it at runtime onto your HA
machine.

## What is Rocrail?

Rocrail is server/client software for digital model railways:
locomotives, turnouts, signals, sensors and complete routes can be
operated manually or fully automatically. The server talks to command
stations such as Märklin CS2/CS3, Roco z21, ESU ECoS, Lenz or NCE via
DCC, MM, Selectrix or mfx.

## First start

The first time the add-on starts:

1. The Rocrail snapshot matching your CPU architecture is downloaded
   from `rocrail.online` into `/data/rocrail/` (~30–60 s).
2. `/share/rocrail/` is set up with the `_images/`, `_svg/` and
   `_stylesheets/` system folders and your workspace folder (named
   after the `workspace` option, default: `default`).
3. The demo plan is copied into the empty workspace as a starting
   point. Open Rocweb from the HA sidebar to interact with it.

Subsequent starts use the locally installed Rocrail; no further
download happens until you trigger an update yourself.

## Configuration options

| Option                              | Description                                            |
|-------------------------------------|--------------------------------------------------------|
| `log_level`                         | Verbosity of server logs (trace / debug / info / …)   |
| `workspace`                         | Workspace folder name directly under `/share/rocrail/` |
| `rocweb_port`                       | Rocweb HTTP port (Ingress, default 8080)              |
| `client_protocol_port`              | Rocrail client port for Rocview / andRoc (default 8051) |
| `support_key`                       | Rocrail Support Key (optional, see below)             |
| `check_and_install_rocrail_update`  | One-shot toggle to update Rocrail (see below)         |

## Workspaces

A workspace is the folder containing your layout: `plan.xml`,
`rocrail.ini`, `backup/`, etc. Workspaces live under `/share/rocrail/`
and are visible via the Samba or File Editor add-on.

Create a new project by either:

- Setting the `workspace` option to a fresh name (e.g. `cellar_layout`)
  and restarting — the add-on creates the folder and seeds it with the
  Rocrail demo plan.
- Or by creating a folder under `/share/rocrail/` via Samba and pointing
  the `workspace` option to it.

**Reserved workspace names:** anything starting with `_` (`_images`,
`_svg`, `_stylesheets`), plus `lic.dat` and `README.txt`. The add-on
refuses to start if `workspace` is set to one of these.

The `rocrail.ini` is seeded only on the very first start of a new
workspace (with HA-friendly paths and a virtual command station
default). After that it's Rocrail-managed — changes via Rocview /
Rocweb (real command station, mDNS list, clock, etc.) survive
restarts.

## Stopping the add-on

Before pressing **Stop** in the add-on UI, shut the server down cleanly
from **Rocview** or **Rocweb** ("Shutdown Rocrail and Server") so your
plan is saved. A direct add-on **Stop** terminates Rocrail with a signal
within a few seconds — it does **not** save unsaved plan changes (Rocrail
saves only on its own clean shutdown). The add-on stops without an error
either way; the clean-shutdown step is only about persisting your latest
plan edits.

## Updating Rocrail

The add-on checks rocrail.online once per 24 hours for a newer Rocrail
revision. If one is available, you get a **persistent notification** in
Home Assistant. To apply it:

1. Open the add-on **Configuration** tab.
2. Toggle **Rocrail-Update prüfen und installieren** on.
3. Restart the add-on.

The add-on downloads the matching zip, installs it under
`/data/rocrail/` and turns the toggle back off via the Supervisor API.
Your `/data/rocrail/decspecs/` (decoder specs) is preserved
intentionally — if you want a fresh copy from upstream, delete the
folder and re-run the update.

Wrapper updates (this repository) never change the installed Rocrail
revision; the two life-cycles are independent.

## Support Key (license)

Without a Support Key, Rocweb sessions are limited to **5 minutes**.
The Rocrail server itself stays fully functional via Rocview or andRoc
regardless.

Get a key at <https://wiki.rocrail.net/doku.php?id=support-en>
(donation, €12/year). To activate, choose one of:

- **Variant A (UI):** paste the contents of your `lic.dat` into the
  *Rocrail Support Key* option. Included in HA backups.
- **Variant B (file):** place `lic.dat` at `/share/rocrail/lic.dat`
  via Samba or File Editor. Lives outside HA backups.

If both are configured, the UI variant wins.

## Custom content

Drop your own files under `/share/rocrail/`:

| Path                           | Content                                |
|--------------------------------|----------------------------------------|
| `/share/rocrail/<name>/`       | **Your layouts** (plan.xml, etc.)      |
| `/share/rocrail/_images/`      | Loco and car images                    |
| `/share/rocrail/_svg/`         | SVG themes (overrides built-ins)       |
| `/share/rocrail/_stylesheets/` | XSL stylesheets (overrides built-ins)  |
| `/share/rocrail/lic.dat`       | Support Key (file variant, see above)  |

Loco/car images are streamed from the server to Rocview, andRoc and
Rocweb on first display and cached client-side — no per-client copy
needed.

## Built-in SVG themes

Wired into the seeded `rocrail.ini`:

| Theme       | Description                                    |
|-------------|------------------------------------------------|
| SpDrS60     | Classic German signal-box style (default)      |
| Accessories | Outputs, text labels, level crossings          |
| Roads       | Roads (for car modules)                        |

To customize, drop a file with the same name into
`/share/rocrail/_svg/<theme>/<file>.svg` — the user overlay is
searched first (first-found-wins).

## Volume layout

| HA path        | Container path     | Content                                                              | HA backup |
|----------------|--------------------|----------------------------------------------------------------------|-----------|
| (path_data)    | `/data/rocrail/`   | Installed Rocrail binary, libs, web assets, decspecs                 | Yes       |
| `addon_config` | `/config/`         | Tempfiles                                                            | Yes       |
| `share`        | `/share/rocrail/`  | Workspaces (each with their own `backup/`) + system folders + lic.dat | Manual    |

`/share/rocrail/` is **not** part of HA add-on snapshots — back it up
externally (Samba, network share). Rocrail's own plan-rotation backups
live inside each workspace at `<workspace>/backup/` and travel with
the workspace.

## License

Wrapper code: **MIT** (see [the repository LICENSE](https://github.com/magliaral/ha-addon-rocrail/blob/main/LICENSE)).
Rocrail itself is proprietary — Copyright Robert Jan Versluis,
Rocrail.net. "All rights reserved. Commercial usage needs permission."
See <https://wiki.rocrail.net/doku.php?id=licence-en>. This add-on
does not redistribute the Rocrail binary; your container downloads it
directly from rocrail.online.
