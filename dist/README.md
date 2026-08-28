# Omarchy on Arch Linux ARM — UTM image for Apple Silicon

Image built with
[`build-omarchy-arm.sh`](https://github.com/ggalancs/omarchy-arm-utm).

A **native aarch64** virtual machine (HVF-accelerated, no emulation) with
Arch Linux ARM + Hyprland and the configuration, themes and tooling of
[Omarchy 4](https://omarchy.org).

Defaults: timezone `Europe/Helsinki`, language `en_US.UTF-8`, keyboard `fi`
(Apple Finnish).

## Requirements

- Apple Silicon Mac (M1 or later)
- [UTM](https://mac.getutm.app) 4.7 or later
- ~11 GB free disk: the `.zip` is 3.6 GB and the unpacked image another
  7.2 GB, plus whatever it grows with use

## Install

1. Unzip the `.zip`.
2. Double-click the `.utm` that appears (or **File → Import** in UTM).
3. Start the VM.

It logs in on its own, with no password prompt.

## Credentials

| | |
|---|---|
| User | `omarchy` |
| Password | `omarchy` (also for root) |

**Change the password as soon as you log in:** open a terminal and run `passwd`.

## Keyboard

macOS grabs Cmd before UTM sees it (Cmd+Space opens Spotlight), so the VM
ships with Alt and Super swapped:

| Mac key | In the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Main shortcuts: **⌥+Space** opens the Omarchy menu, **⌥+Return** a
terminal, **⌥+K** the full keybinding list.

If you prefer the original behaviour, remove `altwin:swap_lalt_lwin` from
`~/.config/hypr/input.lua` and enable UTM input capture (requires
Accessibility and Input Monitoring permission for UTM in System Settings →
Privacy & Security).

The layout is **Finnish** (`fi`), matching Apple's "Finnish" keyboard.

## What to expect

It works: the full Hyprland desktop with the Omarchy bar, themes, menu,
terminal, browser, and the 439 `omarchy-*` commands.

It also includes Omarchy's own tools **compiled for aarch64**, which are not
published for ARM: `tensaku` (screenshot annotation), `omacalc`, `omacut`,
`omawrite`, `aether` (themes), `cliamp` (player), `ttfx` (screensaver
effects), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker` and `yay`.

And two free-software apps already built for ARM: **OBS Studio 32.2.2**
(without the browser plugin, whose CEF is x86-only) and **Pinta 3.1.2**
(on Microsoft's official arm64 .NET).

Limitations of running Omarchy on ARM:

- **No GL acceleration inside the VM.** Windows are drawn in software
  (llvmpipe). Under virtio-gpu, GPU clients map but never paint; blur and
  shadows are disabled to compensate. Fine for normal use, not for video or 3D.
- **`herdr` is missing**: it wants Zig 0.15 semantics, and neither ARM nor
  x86_64 packages that version any more (both are on 0.16).
- **The disk is compressed** inside the `.qcow2`. It is half the size and
  decompresses on the fly; if you prefer read speed over space,
  `qemu-img convert -O qcow2 disk.qcow2 uncompressed.qcow2`.

## Clipboard and shared folder

**Clipboard works both ways**: copy on the Mac and paste in the VM, and
the other way around. Text only. Two conditions:

- **Share clipboard enabled** in UTM (*VM Settings → Sharing*).
- **The VM open as a window.** Started without a window (`utmctl start`) there
  is no SPICE client attached, so the channel exists but carries nothing.

If it does not work, this shows which of the three hops is cut — SPICE client →
`spice-vdagentd` → Hyprland session —:

```bash
systemctl is-active spice-vdagentd              # the daemon
systemctl --user status omarchy-arm-vdagent     # your session agent
```

**Shared folder**: pick one in *VM Settings → Sharing* and inside the guest
run `omarchy-arm-share`. It detects whether UTM is in VirtFS or SPICE WebDAV
mode and mounts it at `/mnt/share` accordingly.
`omarchy-arm-share --status` to see how it landed, `--umount` to unmount.

## Apps that are not in the image

1Password, Obsidian, Typora, LocalSend and Google Chrome **are not in the
image**, but not because they do not work: they all have an official ARM64
build. They are not included because they are proprietary and shipping them
in a distributed image would mean redistributing third-party binaries.

The image carries an installer that fetches them from their official source:

```bash
omarchy-arm-extras --list     # see what it can install
omarchy-arm-extras            # interactive menu
omarchy-arm-extras obsidian   # one specific app
omarchy-arm-extras --all      # everything missing
```

The listing marks `[already installed]` what the image already has, and
`--all` skips those.

It is also in the application menu as **Install missing apps (ARM)**.

| Key | What it does |
|---|---|
| `1password` | Official arm64 tarball, with GPG signature check |
| `1password-cli` | The `op` command, official static arm64 binary |
| `obsidian` | Official arm64 tarball |
| `typora` | Official arm64 package via AUR |
| `localsend` | Official arm64 build |
| `chrome` | Brings Widevine for arm64: enables Spotify and Netflix web |
| `spotify-web` | Web launcher + remaps `⌥+Shift+M` |
| `pinta` | Already installed; the key reinstalls it |
| `obs` | Already installed; the key reinstalls it |

**On Spotify**: there is no native ARM client, but the web app works — it
needs Widevine, which ships inside Google Chrome arm64. Install `chrome`
then `spotify-web`. In the terminal you already have `spotify-player`.
- **`omarchy-update` works**, but when Omarchy introduces a new first-party
  package it will skip it with a warning instead of installing it.

## Resolution

Fixed at 1920x1200. To change it, edit `~/.config/hypr/monitors.lua` and
**reboot the VM** — changing the mode at runtime whites out the screen under
virtio-gpu.

## Note

Unofficial image, unaffiliated with Basecamp or the Omarchy project.
Omarchy only supports x86_64; this is an equivalent reconstruction on
Arch Linux ARM.
