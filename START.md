# How to run it

> Also published as a page:
> https://claude.ai/code/artifact/630abf6c-6d3e-4e92-81b2-bfc0a3073c70

Two paths. The first takes ten minutes; the second, between one and two hours.

| | |
|---|---|
| **I just want the VM** | download [`omarchy-arm-utm-v2.zip`](https://archive.org/details/omarchy-arm-utm) (3.6 GB) and double-click → [skip to the end](#if-you-just-want-the-vm) |
| **I want to build it myself** | `./build-omarchy-arm.sh` → keep reading |

---

## 1 · What you need

| Requirement | Why | How to check |
|---|---|---|
| **Apple Silicon Mac** | the VM is native aarch64 with HVF; on Intel you would have to emulate and it would take a day | `uname -m` → `arm64` |
| **macOS with Homebrew** | the script installs `qemu`, `expect` and `aria2` if they are missing | `brew --version` |
| **UTM 4.7 or later** | that is where the VM is registered | `brew install --cask utm` |
| **Command Line Tools** | the script uses `git` and `python3`, which on macOS come from there | `xcode-select -p` |
| **~40 GB free** | the build disk reaches ~13 GB and the packaging phase needs as much again | `df -h ~` |
| **A decent connection** | it downloads ~900 MB and then ~1,500 packages from the Arch Linux ARM repos | |

If something is missing, install it like this:

```bash
xcode-select --install                    # git and python3
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask utm
```

**No `sudo` needed.** The script does not touch anything on the host system:
everything it needs it writes inside its working directory, and the three
Homebrew dependencies are installed as your user.

## 2 · What context the script needs

**None: it is a single file.** `build-omarchy-arm.sh` embeds the fifteen files
it needs — the three install stages, the sanitiser, the repairer, the optional-app
installer, the update hook, the clipboard agent and its bridge, the shared-folder
mounter, the VM configuration, the two `expect` harnesses, the QEMU launcher,
the `.utm` bundle writer and the README that ships inside the zip — and writes
them to disk at startup. You can copy just that file to another Mac and it will
work the same.

The only thing you can give it in advance, to save ~900 MB of download, are the
base images:

```bash
mkdir -p ~/omarchy-arm-build/dl
cp alpine-virt-*-aarch64.iso  ~/omarchy-arm-build/dl/alpine-virt-aarch64.iso
cp ArchLinuxARM-aarch64-*.tar.gz ~/omarchy-arm-build/dl/alarm-rootfs.tgz
```

The working directory is `~/omarchy-arm-build` unless you set another:

```bash
W=/Volumes/External/omarchy ./build-omarchy-arm.sh
```

## 3 · Running it

```bash
./build-omarchy-arm.sh
```

That is it. With a terminal it will first ask six questions **pre-filled with
what it detects from your Mac**, so you answer them with Enter:

```
━━━ configuration ━━━
  Timezone [Europe/Helsinki]:                    ← from /etc/localtime
  Keyboard (console) [fi]:                       ← from macOS preferences
  Keyboard (Hyprland/Wayland) [fi]:
  VM cores [6]:                                  ← half of your performance cores
  VM memory (MiB) [12288]:                       ← based on your RAM
  Disk size [80G]:
```

And then the three that **do change the result**:

- **Compile the 17 Omarchy tools that do not exist for ARM (~40 min)?**
  That is ~40 minutes. If you say no, the desktop works the same but you will
  be missing `ttfx` (the screensaver), `tensaku` (annotate screenshots),
  `omacalc`, `omacut`, `omawrite`, `aether`, `cliamp` and `omarchy-nvim`.
  `aether` and `cliamp` can be added later with `yay -S`; the rest are not in
  the AUR for aarch64 and you would have to compile them by hand, so saying yes
  here is cheap.

- **Include OBS Studio and Pinta (free software, they compile: ~45 min)?**
  They are free software, so they can travel inside the image, and the one that
  is distributed includes them. They cost ~45 minutes: OBS is compiled from
  source (without the browser plugin, whose CEF is x86-only) and Pinta needs
  Microsoft's official arm64 .NET. If you say no, they can be added later from
  inside with `omarchy-arm-extras pinta obs`.

- **Prepare the image for distribution?**
  - **No** (what the prompt proposes: just press Enter): the VM keeps your
    user and your configuration. It skips `sanitize` and `package`, and you
    save ~15 minutes. `sshd` is still disabled, so you do not leave a VM
    listening with a trivial password.
  - **Yes**: renames the user to `omarchy`, deletes SSH keys, git identity
    and histories, and produces a ~3.6 GB `.zip` with its `sha256`.

To answer nothing:

```bash
./build-omarchy-arm.sh --yes        # default values, no questions
```

With no terminal (cron, CI, `nohup`) it does not ask either: it detects that
there is no tty.

## 4 · What happens and how long it takes

Measured on a real build on an M3 Max, with the tools compiled and without OBS
or Pinta:

| Phase | What it does | Time |
|---|---|---|
| `deps` | checks the Mac and installs qemu/expect/aria2 if they are missing | seconds |
| `fetch` | downloads Alpine and the ALARM rootfs, verifying sha256 and MD5 | ~2 min |
| `prepare` | computes the package list by crossing Omarchy's live branch with the ARM index | ~10 s |
| `build` | boots Alpine headless, partitions, deploys the rootfs and runs the three stages in chroot | **~40 min** |
| `utm` | writes the `.utm` bundle and registers it in UTM | ~1 min |
| `verify` | boots the VM and requires seven conditions inside it: Hyprland and quickshell alive, ≥400 commands, ≤5 broken links, ≥6 `omarchy-*` units, version 4 and a complete clipboard. If any fail, the build stops here | ~4 min |
| `sanitize` | copies the disk and cleans it for distribution | ~10 min |
| `package` | compacts the qcow2, creates the bundle and compresses it | ~3 min |

**Total: between 76 and 83 minutes**, measured across two full runs on an M3
Max with the default values — with the 17 tools, with OBS and with Pinta,
which is exactly what the distributed image carries — and the result is a
**3.6 GB** `.zip`. Saying no to OBS and Pinta saves about 45 minutes: OBS is
compiled entirely from source and is, by far, the most expensive part of the
process.

The working directory reaches about **24 GB** at its peak. The script requires
40 GB free because APFS clones can push it higher.

The `build` phase prints almost nothing while it works. To watch it from the
inside:

```bash
tail -f ~/omarchy-arm-build/logs/build.log
```

## 5 · If something fails

Every phase is resumable, so **you do not have to start from scratch**:

```bash
./build-omarchy-arm.sh --from build   # resume from there
./build-omarchy-arm.sh --only package # repeat only one phase
./build-omarchy-arm.sh --list         # see the valid names
```

Resuming **does not ask again**: what you answered is saved in
`~/omarchy-arm-build/respuestas.env` and recovered on its own. Precedence, in
this order, is what you put in the environment, what was saved, what was
detected from your Mac, and the default — so
`UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` honours your 16384. `--from`
and `--only` are mutually exclusive and both require the name of a phase.

Logs land in `~/omarchy-arm-build/logs/`, one per phase. The `build` one is the
one that matters: it carries the full output of the three stages inside the
guest, with the prefixes `[stage1]`, `[stage2]` and `[stage3]`.

Two deliberate behaviours worth knowing:

- If a disk has already been built, `build` **does not delete it**: it moves it
  to `omarchy-arm.qcow2.anterior` and starts a new one.
- If a VM of the same name already exists in UTM, **it does not delete it**:
  it registers the new one with the time appended to the name.

And one that can surprise: for UTM to recognise a new bundle you have to
restart the application, because it only scans `Documents` at launch. If you
have VMs running, the script warns you and lets you decide; in unattended mode
it does not kill them, and tells you to import the bundle by hand with
**File → Import**.

## 6 · When it finishes

The VM appears in UTM. It boots on its own, without asking for a password.

**The Option key (⌥) acts as SUPER**, because macOS keeps Cmd before UTM
receives it. ⌥+Space opens the Omarchy menu, ⌥+Return a terminal, ⌥+K the full
list of shortcuts.

Inside, to install the apps that do not ship (1Password, Obsidian, Typora,
LocalSend, Chrome):

```bash
omarchy-arm-extras --list
omarchy-arm-extras            # interactive menu
```

## 7 · To undo it

```bash
rm -rf ~/omarchy-arm-build           # the entire working directory
```

And delete the VM from UTM's own interface. The script has not touched
anything else on your Mac.

---

## If you just want the VM

Download **`omarchy-arm-utm-v2.zip`** from https://archive.org/details/omarchy-arm-utm (3.6 GB) and:

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

User `omarchy`, password `omarchy` (also for root). **Change it as soon as you
log in with `passwd`.** The rest is in the `README.md` that comes inside the zip.

Its `sha256` is `929eb816194a5cfc…`. Next to it there is an `omarchy-arm-utm.zip`
of 6.5 GB: that is the first release, and it keeps the short name so the links
and checksums published with it still point at the exact bytes they were
written for. That is the only reason the good one has `-v2` in the name.
`VERSIONS.md` compares the two.
