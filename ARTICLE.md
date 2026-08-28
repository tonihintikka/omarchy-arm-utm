# Omarchy on an Apple Silicon Mac: when the guide no longer works

How to reconstruct the Omarchy desktop on Arch Linux ARM inside UTM,
why the official path is closed, and the ten obstacles you only discover
by running into them.

---

## The starting point

Omarchy is DHH's desktop distribution: Arch Linux with Hyprland,
carefully designed themes and some 430 first-party utilities. The question was
simple: **can you have that in a virtual machine on an Apple Silicon Mac?**

There is a reference guide, [discussion
#452](https://github.com/basecamp/omarchy/discussions/452) of the
repository, that describes exactly that. The problem is that it is from 2025
and the project moves fast.

### First: check that the guide is still valid

Four checks were enough to discard it. None of them requires installing
anything:

```bash
# 1. The endpoint the guide uses
curl -sI https://omarchy.org/install-bare | head -1
# → HTTP/2 404

# 2. The Omarchy mirror, for aarch64
curl -sI https://stable-mirror.omarchy.org/core/os/aarch64/core.db | head -1
# → HTTP/2 404          (the x86_64 one returns 200)

# 3. The installer guard... on the 3.x branch
curl -s https://raw.githubusercontent.com/basecamp/omarchy/master/install/preflight/guard.sh \
  | grep -A2 'x86 only'
# → if [[ $(uname -m) != "x86_64" ]]; then
# →   abort "x86_64 CPU"

# 4. The actual state of ARM support, in the ISO repository itself
curl -s https://raw.githubusercontent.com/omacom-io/omarchy-iso/main/plans/aarch64-support.md \
  | head -20
# → "Plan: aarch64 ... Target: a parallel generic UEFI aarch64 ISO"
```

That fourth point is the most informative: the Omarchy team **already wrote the
plan** to support aarch64, and in that document they list the blockers they
themselves have. Among others: *"`pkgs.omarchy.org/{stable,edge}/aarch64/`
must serve a real repo. Probed today, both return 404"*.

There is a detail that settles the matter. The Omarchy installer overwrites the
entire mirror list — in quattro, from `install/post-install/pacman.sh` —
with `stable-mirror.omarchy.org/$repo/os/$arch`. On ARM, the first subsequent
`pacman -Syu` fails, because that mirror does not serve aarch64.

### Correction: in quattro that guard no longer exists

Months later I checked again and point 3 **had stopped being true**.
Cloning both branches:

| Branch | `install/preflight/guard.sh` | `uname -m` in the whole repo |
|---|---|---|
| `master` (3.8.x) | exists, line 25 | 1 occurrence |
| **`quattro` (4.x, the default)** | **the `preflight/` directory does not exist** | **0 occurrences** |

Omarchy 4 **does not refuse to run on ARM64**. What is missing is the
repository: the tree is shell, Lua and QML, architecture-agnostic, and the
`omarchy` package itself is declared `arch=('any')`. The blocker moved from
"it refuses" to "there is nowhere to install from", which is a much smaller
problem — publishing some 25 aarch64 packages would close it — and which also
explains why several third-party projects have had to stand up their own
repository separately.

I leave the error in view instead of rewriting history, because it is
representative: **I verified against the wrong branch**. `master` sounds like
the main branch; in this repository the default is `quattro`. The same trap
that had already cost me a boot into emergency mode, again, in another place.

### The decision

If you cannot install Omarchy, you can **reconstruct** it: stand up Arch Linux
ARM with Hyprland and apply the actual contents of the Omarchy repository —
configuration, themes, utilities — which is where 90% of the experience lives.

Before writing a line of code it is worth measuring whether that yields
something usable. You can know without installing anything, by crossing
Omarchy's package list with the Arch Linux ARM index:

```bash
# Arch Linux ARM package index for aarch64
curl -s http://mirror.archlinuxarm.org/aarch64/core/core.db   -o core.db
curl -s http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o extra.db
mkdir db && cd db && tar -xzf ../core.db && tar -xzf ../extra.db
ls -1 | sed -E 's/-[^-]+-[^-]+$//' | sort -u > ../alarm.txt

# Omarchy package list
curl -s https://raw.githubusercontent.com/basecamp/omarchy/quattro/install/omarchy-base.packages \
  | grep -vE '^#|^$' > omarchy.txt

comm -12 <(sort omarchy.txt) ../alarm.txt | wc -l   # available
comm -23 <(sort omarchy.txt) ../alarm.txt           # the ones that are missing
```

Result: **121 of 148 packages exist on ARM** by exact name — 123 if you
substitute `nvim` for `neovim` and `ttf-jetbrains-mono-nerd-basic` for
`ttf-jetbrains-mono-nerd`, which is what the `prepare` phase does. The missing
ones are proprietary apps (1Password, Spotify, Obsidian, Typora) and Omarchy's
own packages. And the important part: `hyprland`, `hyprlock`, `hypridle`,
`waybar`, `quickshell`, `uwsm`, `sddm`, `mesa` and `chromium` are all there,
with up-to-date versions. Arch Linux ARM is **in lockstep** with Arch:
`firefox 154.0-1` on both.

With those numbers, the project makes sense.

---

## The architecture of the build

Three structural decisions, each with its reason.

**Headless construction.** Booting an installer and clicking is not
reproducible. The whole process happens in a QEMU VM driven by `expect`
through the serial console. If something fails, you fix the script and repeat.

**HVF acceleration.** Because the guest is aarch64 and the host is too, you
can use macOS's native hypervisor instead of emulating. The difference is an
order of magnitude:

```bash
qemu-system-aarch64 -accel hvf -cpu host -M virt,highmem=on,gic-version=3 ...
```

**Alpine as the boot environment.** Arch Linux ARM does not publish an
installer ISO, only a rootfs tarball. You need a minimal Linux that partitions
the disk and deploys that tarball. Alpine `virt` weighs 88 MB, boots in
seconds and drops straight to a serial console.

The skeleton is:

```
Alpine live (QEMU + HVF, serial console)
  └─ stage 1: partition, deploy the ALARM rootfs, chroot
       └─ stage 2 (root): kernel, UEFI boot, packages, user
            └─ stage 3 (user): Omarchy, AUR, themes
```

---

## Step by step

### 1 · Dependencies

```bash
brew install qemu expect aria2
brew install --cask utm
```

### 2 · Base images, with verification

```bash
aria2c -x8 https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.1-aarch64.iso
aria2c -x8 http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

# The tarball is rebuilt every few weeks: always verify
curl -s http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5
md5 -q ArchLinuxARM-aarch64-latest.tar.gz
```

### 3 · Partitioning and deploying the rootfs

Inside Alpine. First non-obvious detail: **you have to load the btrfs module
by hand**. Alpine's `virt` kernel ships it as a module but does not autoload
it, and `mkfs.btrfs` works (it is userspace) while `mount` fails with a
baffling *"Invalid argument"*.

```sh
modprobe btrfs vfat
grep -qw btrfs /proc/filesystems || exit 1   # actually check

parted -s /dev/vda mklabel gpt
parted -s /dev/vda mkpart OMBOOT fat32 1MiB 1025MiB
parted -s /dev/vda set 1 esp on
parted -s /dev/vda mkpart OMROOT btrfs 1025MiB 100%
mkfs.vfat -F32 -n OMBOOT /dev/vda1
mkfs.btrfs -f -L OMROOT  /dev/vda2

mount /dev/vda2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o rw,noatime,compress=zstd:3,subvol=@     /dev/vda2 /mnt
mkdir -p /mnt/home
mount -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
```

**Second detail: the ESP is mounted *after* extracting the rootfs.** The ALARM
tarball contains symbolic links in `/boot`, and vfat cannot hold them. If the
ESP is mounted during extraction, `bsdtar` fails. The solution is to extract
first, discard that `/boot` and let pacman repopulate it onto the already-mounted
ESP:

```sh
bsdtar -xpf alarm-rootfs.tgz -C /mnt      # -p preserves permissions and xattr
rm -rf /mnt/boot && mkdir /mnt/boot
mount /dev/vda1 /mnt/boot
```

### 4 · Base system and UEFI boot

Inside the chroot. Arch Linux ARM has **its own keyring**, distinct from
Arch's:

```bash
pacman-key --init
pacman-key --populate archlinuxarm     # not "archlinux"
pacman -Syu --noconfirm
pacman -S --noconfirm --needed base base-devel linux-aarch64 sudo git \
  networkmanager btrfs-progs dosfstools efibootmgr
```

The initramfs needs the virtio modules spelled out, because mkinitcpio's
`autodetect` runs in a chroot where the running kernel is Alpine's:

```bash
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu btrfs)/' \
  /etc/mkinitcpio.conf
mkinitcpio -P
```

And here the **third non-obvious detail**, the one that decides whether the VM
boots or not:

```bash
bootctl --esp-path=/boot --no-variables install
```

`--no-variables` avoids writing entries into UEFI NVRAM. Why? Because the
build VM's NVRAM **does not travel** to the UTM bundle: they are different
variable files. Booting has to depend on the fallback path
`\EFI\BOOT\BOOTAA64.EFI`, which `bootctl` installs anyway. If you rely on
NVRAM, the VM builds fine and then does not boot in UTM.

### 5 · Omarchy: the surprise

This is where the project got truly complicated.

```bash
git clone --depth 1 https://github.com/basecamp/omarchy.git ~/.local/share/omarchy
mkdir -p ~/.config
cp -R ~/.local/share/omarchy/config/* ~/.config/
```

Two lines and you are done, in theory. In practice, Hyprland started in
**emergency mode**:

```
⚠ Emergency mode tripped: A lua config error resulted in no binds being registered.
cannot open /usr/share/omarchy/default/hypr/bootstrap.lua: No such file or directory
```

Two chained discoveries, and both deserve their own section.

---

## The obstacles

### 1 · `git clone` does not fetch `master`

```bash
curl -s https://api.github.com/repos/basecamp/omarchy | jq -r .default_branch
# → quattro

curl -s https://raw.githubusercontent.com/basecamp/omarchy/master/version    # → 3.8.5
curl -s https://raw.githubusercontent.com/basecamp/omarchy/quattro/version   # → 4.0.0.alpha
```

The default branch **is not `master`**. A `git clone` without `--branch`
fetches `quattro`, which is Omarchy 4, a different product from the 3.8.5 that
`master` documents:

| | `master` (3.8.5) | `quattro` (4.x) |
|---|---|---|
| Bar | waybar | **quickshell** (`omarchy-shell`) |
| Hyprland config | `.conf` files | **Lua** (`hyprland.lua`) |
| Distribution | scripts in `$HOME` | **pacman package** in `/usr/share/omarchy` |

Practical consequence: I had installed the package list from `master` — with
waybar — on a system running `quattro` — which uses quickshell. The bar simply
did not exist. And `quickshell 0.3.1` **is** in Arch Linux ARM; you just had
to know that it was needed.

**Lesson:** when a project moves fast, check the default branch before reading
its documentation.

### 2 · Omarchy 4 is a pacman package

Version 4 is distributed as a package, not as scripts in `$HOME`. That
package places files at fixed system paths:

- `/usr/share/omarchy` — the complete tree
- `/usr/bin/omarchy-*` — the binaries on PATH
- `/etc/profile.d/omarchy.sh` — the hook for shells
- `/usr/share/uwsm/env.d/10-omarchy` — the hook for the graphical session

It is worth being precise here, because I wrote it wrong at first: **the
package is not x86_64-only**. Its PKGBUILD declares `arch=('any')` — they are
scripts, Lua and QML — and installs the commands into `/usr/bin`, with links
from `/usr/share/omarchy/bin`. What is x86_64-only is the **repository** it is
published in. On ARM there is nowhere to install it from, and that is where
the problem starts: cloning the repository into `$HOME` leaves `OMARCHY_PATH`
unset, `.bashrc` errors out, Hyprland cannot find its `bootstrap.lua` and
nothing in autostart works.

The solution is to reproduce by hand what the package would do:

```bash
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
for f in "$OMARCHY_PATH"/bin/*; do
  sudo ln -sfn "$f" "/usr/bin/$(basename "$f")"           # 439 binaries
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" \
  /usr/share/uwsm/env.d/10-omarchy
```

This ended up in `/usr/bin`, not in `/usr/local/bin`. I started with
`/usr/local/bin` so as not to step on pacman's territory, which seemed the
clean thing, and it broke things: the Omarchy tree hardcodes
`/usr/bin/omarchy-*` in thirteen places, five of them `.service` files.
`/usr/local/bin` is still used, but only for the ARM-specific wrappers that
need to win on PATH.

A curiosity: Omarchy has a mechanism designed exactly for this,
`omarchy-dev-link`, which writes `/etc/omarchy.conf` to point the system at a
local checkout. It exists for developing Omarchy, but it works just as well
for this case.

### 3 · The Super key, hijacked by macOS

Omarchy uses SUPER for everything. On a Mac, SUPER is Cmd, and **macOS
intercepts Cmd before UTM receives it**: Cmd+Space opens Spotlight, not the
Omarchy menu.

You can fight UTM's input-capture permissions, or solve it inside the guest
in one line:

```lua
-- ~/.config/hypr/input.lua
hl.config({
  input = {
    kb_layout  = "es",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
```

`altwin:swap_lalt_lwin` swaps Alt and Super. Result: the **Option (⌥)** key
acts as SUPER, and macOS does not intercept Option+Space.

While we are here, another detail: Hyprland reads the keyboard layout from
`XKBLAYOUT` in `/etc/vconsole.conf`, not from `KEYMAP`. Setting only
`KEYMAP=es` leaves Hyprland on `us`. You have to write both.

### 4 · Windows that open invisible

The most baffling symptom: the desktop was visible, the keyboard worked, the
menus appeared… but opening a terminal produced nothing. `hyprctl`
confirmed it:

```
Window aaaad1ec7630 -> Alacritty:
    mapped: 1
    size: 1896,1150
    workspace: 1
```

Window mapped, with a size, on the visible workspace. And on screen, only the
wallpaper.

The test that isolated it was comparing two terminals:

```bash
foot       # draws with shared-memory buffers (wl_shm)  → VISIBLE
alacritty  # draws with EGL/GPU (dma-buf)               → NOT VISIBLE
```

That is: under `virtio-gpu` with virgl, clients that use the GPU produce
buffers that Hyprland cannot composite. The compositor renders its own
things — bar, wallpaper, menus — but application windows stay empty.

What does **not** fix it, checked one by one:

- `AQ_NO_MODIFIERS=1` — already active
- `render:explicit_sync` — removed in Hyprland 0.56
- `render:cm_enabled = false` — no effect

What does:

```bash
# /etc/environment.d/90-vm-graphics.conf
LIBGL_ALWAYS_SOFTWARE=1
```

Mesa switches to llvmpipe, clients deliver `wl_shm` buffers and everything
draws. The cost is real: you lose GL acceleration **inside** the VM. As
compensation it is worth disabling blur and shadows, which with CPU rendering
are expensive.

A nuance that cost an hour: when testing it over SSH it seemed not to work.
`/etc/environment.d/` is read by the **systemd session manager**, not by a
login shell. An app launched from SSH does not inherit the variable; one
launched from the graphical session does. The failure was in the test method,
not in the fix.

### 5 · Changing the resolution at runtime breaks rendering

When setting 1920x1200 with `hyprctl reload`, the screen went **blank**. The
layers were still there (`hyprctl layers` listed them, with alpha 1), but they
were not painted. Restarting the shell was not enough; the whole VM had to be
rebooted.

Applied **from boot**, the same resolution works perfectly.

```lua
-- ~/.config/hypr/monitors.lua
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
```

If you touch that file, reboot the VM instead of reloading the configuration.
(The `scale = 1` also matters: Omarchy assumes retina displays and with the
default value everything comes out gigantic in a VM.)

### 6 · `omarchy-update` blew up

On update, the output ended in error. The pacman log told the story:

```
Running 'pacman -Rns --noconfirm dust'      → removed
Running 'pacman -S --noconfirm tensaku'     → does not exist on ARM → error
```

An Omarchy **migration** had removed `dust` to replace it with `tensaku`, a
first-party package that does not exist on ARM. And it left the system with
neither of the two.

The root cause was in the build:

```bash
ls ~/.local/state/omarchy/migrations | wc -l   # 8
ls /usr/share/omarchy/migrations/*.sh | wc -l  # 83
```

A normal Omarchy installer **seals all migrations on completion**, because a
freshly installed system is already born in the final state: migrations exist
to update old installations. By cloning the repository without sealing them,
`omarchy-update` tried to replay 75 historical migrations.

Two fixes. The first, sealing:

```bash
mkdir -p ~/.local/state/omarchy/migrations
for f in /usr/share/omarchy/migrations/*.sh; do
  : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
```

The second is the one that matters long-term. `omarchy-pkg-add` aborts if a
package does not exist, and that takes down the entire update. A wrapper in
`/usr/local/bin` makes it tolerant:

```bash
#!/bin/bash
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf 'Skipped, does not exist on ARM: %s\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
```

Without this, every new package Omarchy introduces would break updates
again.

### 7 · The grey desktop: two failures that no log reported

The last check before packaging was looking at a screenshot of the already
sanitised desktop. It booted, the bar was there, the clock showed the time.
But the wallpaper was flat grey and the notifications, grey boxes with no
style. Not an error in `journalctl`, not a warning on screen. Two independent
causes, and both share the same shape: **the system kept working, just badly**.

**`grep -r` does not see a symbolic link's target.** When renaming the user
from `gabriel` to `omarchy` I checked the result like this:

```bash
grep -rl '\bgabriel\b' /etc /home/omarchy/.config     # → 0 matches
```

Zero. Clean. Except that a symlink's target is not *file content*: `grep`
does not read it. And Omarchy stores the active theme and wallpaper precisely
as links:

```
~/.local/state/omarchy/current/background -> …/theme/backgrounds/1-quattro.webp
```

The correct check is a different tool:

```bash
find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*"
```

**439 dangling links**, including the **431 `omarchy-*` commands** in
`/usr/local/bin`, which pointed at the home that no longer existed. The
desktop booted because quickshell reads from `/usr/share/omarchy`, but any
command from the menu would have failed. The rewrite is trivial once you see
them:

```bash
for l in "${BADLINKS[@]}"; do
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
done
```

And verification now counts three things it did not look at before: links to
the old home, broken links, and whether the active wallpaper resolves.

**I installed four packages that Omarchy 4 retires.** The second failure was
mine at the root. My "infrastructure" package list came from reading Omarchy
3, and it dragged along `mako`, `swayosd`, `walker` and `elephant`. None of
them is in quattro's `omarchy-base.packages`. The repository's own
documentation says it without wrapping, in `docs/notifications.md`:

> The shell is the notification daemon […] There is no dunst or mako.

And `bin/omarchy-upgrade-to-quattro` uninstalls them explicitly, along with
their user units. `mako` is not inert: it activates over D-Bus on the first
`notify-send` and **claims `org.freedesktop.Notifications` before the
shell**. The result is that quickshell loses the bus name and notifications
come out with mako's default style. Those were the grey boxes.

The launcher did not need `walker` either: in quattro the menu is a
quickshell panel (`omarchy-shell shell toggle omarchy.menu`), so my
`fuzzel`-based stand-in for `walker` was dead code from day one.

The lesson is not "a package slipped in". It is that **a distribution's
package list is a claim about its architecture, not an inventory**. I filled
it in with what I remembered from the previous version, and in doing so I
reintroduced a component the new version had deliberately replaced. Crossing
against `omarchy-base.packages` — which is what the `prepare` phase does —
and not adding anything by intuition would have saved the two hours of
diagnosis.

---

## The methodological error: "unavailable" is not a category

When crossing Omarchy's package list with the Arch Linux ARM index, 25
absences came out. I put them all in the same drawer — "unavailable" — and
moved on. It was a mistake, and it took a long time to discover.

That drawer mixed two incomparable things:

- **Impossible**: 1Password, Spotify, Obsidian, Typora. Proprietary binaries
  compiled only for x86_64. Nothing to be done.
- **Nobody has built it yet**: almost everything else.

And I put `pinta` in the first drawer, which is the error inside the error:
Pinta is free software and Microsoft publishes .NET for linux-arm64. Today it
is compiled in the build and travels inside the image. Misclassifying a
single line cost not having an image editor for weeks.

Working reactively — compiling only what breaks something visible — I ended
up resolving `walker` and `elephant` believing that without them there was no
launcher (false: the menu is a quickshell panel, see finding 7),
`xdg-terminal-exec` because it is `$TERMINAL`, and `ttfx` only when the
screensaver errored on screen. The rest stayed in the drawer.

The audit I should have done on day one is this, and it is solved with two
queries to the GitHub API and one to the AUR:

```bash
# Does it exist in the AUR?
curl -s "https://aur.archlinux.org/rpc/v5/info?arg[]=tensaku&arg[]=aether&arg[]=cliamp" \
  | jq -r '.results[] | "\(.Name) \(.Version) \(.URL)"'

# What language is it written in? (decides whether it is portable)
curl -s https://api.github.com/repos/omacom-io/omacalc | jq -r '.language'

# What does its PKGBUILD say?
curl -s https://raw.githubusercontent.com/omacom-io/omarchy-pkgs/master/pkgbuilds/omacalc/PKGBUILD \
  | grep -E '^(arch|makedepends)='
```

The result takes the drawer apart:

| Package | Origin | Language | Why it was missing |
|---|---|---|---|
| `omacalc`, `omacut`, `omawrite` | omacom-io | Qt / C++ | **its PKGBUILD already declares `aarch64`** |
| `aether`, `cliamp` | AUR | Go | portable |
| `herdr`, `tensaku`, `hyprland-preview-share-picker` | AUR / omacom | Rust | `arch=(x86_64)` by default |
| `omarchy-nvim`, `tobi-try` | omarchy-pkgs | — | `arch=any`, they do not even compile |
| `yaru-icon-theme`, `ttf-ia-writer` | AUR | — | icons and fonts |
| `tzupdate`, `ufw-docker`, `mise-bin`, `localsend` | AUR | Python, shell, binary | portable |

**Of the 25 absences, 16 were buildable**, and three of them did not even
require touching anything: just that someone ran `makepkg` on an ARM machine.

### Building them

The key observation is that many PKGBUILDs declare `arch=(x86_64)` because the
maintainer only builds for their machine, not because the code is
incompatible. If it is portable Rust, Go or C++, adding the architecture is
enough:

```bash
build_omarchy_tool() {                 # <aur|omapkgs> <package>
  local src="$1" pkg="$2"
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0

  case "$src" in
    aur) git clone --depth 1 -q "https://aur.archlinux.org/$pkg.git" "$dir" ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo"
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" && rm -rf "$dir/repo" ;;
  esac

  # The point of the matter: declare aarch64 when the code is portable
  grep -qE "^arch=.*(aarch64|'any')" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"

  ( cd "$dir" && makepkg -si --noconfirm --needed )
}
```

They are built in increasing-cost order — data, Go, Qt, Rust — and none is
fatal: if one fails, the rest continues.

```bash
for spec in \
  aur:yaru-icon-theme aur:ttf-ia-writer aur:tzupdate aur:ufw-docker \
  omapkgs:omarchy-nvim omapkgs:tobi-try aur:mise-bin \
  aur:aether aur:cliamp \
  omapkgs:omacalc omapkgs:omacut omapkgs:omawrite \
  aur:herdr omapkgs:tensaku omapkgs:hyprland-preview-share-picker; do
  build_omarchy_tool "${spec%%:*}" "${spec#*:}"
done
```

And `ttfx`, which is not in the AUR, directly from its repository:

```bash
git clone https://github.com/omacom-io/ttfx.git && cd ttfx
cargo build --release && sudo install -Dm755 target/release/ttfx /usr/local/bin/ttfx
```

Compiling it all takes a while — the three Rust projects are the slowest —
but it is machine time, not person time.

> **A bash trap along the way.** The function above started like this:
>
> ```bash
> local src="$1" pkg="$2" dir="/tmp/omabuild/$pkg"    # ← fails with set -u
> ```
>
> Bash **expands all values of a `local` before assigning any of them**, so
> `$pkg` does not exist yet when building `$dir`, and with `set -u` the script
> aborts on the first call. You have to split it into two statements.

### The result

Of the 25 absences, **20 ended up installed**. Only one resisted, and for a
specific reason: `herdr` invokes `zig fetch` with Zig 0.15 semantics and the
repos are on 0.16 — it fails with *"no build.zig file found"*. It is worth
being precise that **this is not an ARM thing**: `zig 0.16.0-1` is the
version on both Arch Linux ARM and x86_64, so anyone would hit the same snag.
Building Zig 0.15 from source is hours, and it is a development tool, not
part of the desktop.

The remaining absences are the genuinely impossible ones: proprietary
binaries compiled only for x86_64.

Four of the five stumbles along the way were defects in my own script, not
real incompatibilities, and all four would break anyone's build:

| Symptom | Cause |
|---|---|
| Dies on the first call with `pkg: unbound variable` | A single `local` expands **all** values before assigning any of them |
| `Can not use 'any' architecture with other architectures` | The PKGBUILD has `arch=(any)` **unquoted** and the guard only looked at the quoted form |
| The AUR clone comes out empty | AUR URLs use the **PackageBase**, which is not always the package name: `yaru-icon-theme` lives in the `yaru` repo |
| `failed to prepare transaction` on install | The PKGBUILD generates **several subpackages** and only one has a missing dependency. You have to compile without installing and install the specific subpackage |

And a final irony: when installing the Yaru icons, `pacman` complained about
two conflicting files… created by Omarchy's own `theme-system.sh`, precisely
because the theme was not installed. It is solved with
`--overwrite '/usr/share/icons/*'` and re-applying the links afterwards.

## What if I press "Update System"?

It is the question that matters most long-term, and the initial answer was
"no". Three things prevented it, and none is obvious until you read the code.

### The Omarchy tree never updated

`omarchy-update` calls `omarchy-update-dev`, whose first line is:

```bash
[[ $OMARCHY_PATH != "/usr/share/omarchy" ]] || exit 0
```

It exits immediately if `OMARCHY_PATH` is the canonical path, because it
assumes the pacman package is in charge there. In an ARM install there is a
**git checkout** there, and nobody updates it. The system would receive new
packages while Omarchy's scripts, themes and configuration stay frozen
forever.

You can see it with two commands:

```bash
git -C /usr/share/omarchy log -1 --format=%h    # ed7bae4  (20 August)
git -C /usr/share/omarchy fetch --dry-run       # ed7bae4..2c247e3  quattro
```

The solution fits Omarchy's own design: a hook in
`~/.config/omarchy/hooks/post-update.d/` that does the `git pull` and links
the new binaries.

```bash
git -C "$TREE" pull --ff-only
for f in "$TREE"/bin/*; do
  t="/usr/bin/$(basename "$f")"
  [ -e "$t" ] && [ ! -L "$t" ] && continue   # respects our own wrappers
  [ -L "$t" ] && continue
  sudo ln -sfn "$f" "$t"
done
sudo find /usr/bin -xtype l -delete
```

### No safety net

`omarchy-snapshot create` returns 127 if snapper is not installed, and
`omarchy-update` treats that as "continue without a snapshot". That is: every
update of a rolling release, with no way back.

`snapper` is in Arch Linux ARM and Omarchy ships its own configurator:

```bash
sudo pacman -S snapper
sudo bash -euo pipefail /usr/share/omarchy/install/config/snapper.sh
```

With systemd-boot there is no snapshot selection in the boot menu — that is
what `limine-snapper-sync` provides — but the snapshots exist and are
recovered with `snapper rollback`.

### An infinite loop hidden in a symlink

This one I introduced myself, and it is the most instructive. The
`omarchy-pkg-add` wrapper was created like this:

```bash
sudo tee /usr/local/bin/omarchy-pkg-add <<'WRAP'
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
...
exec "$REAL" "${avail[@]}"
WRAP
```

It looks correct. The problem is that `/usr/local/bin/omarchy-pkg-add` **was a
symlink into the tree**, and `tee` follows symlinks: it replaced Omarchy's
original script with the wrapper, whose `REAL` then pointed at itself. Every
call executed in a loop until it hung the entire update.

It did not show its face earlier because it only fires when a migration
installs a package, and all of them were sealed. It appeared when the first
new migration arrived. It is detected with `git status` in the tree:

```
 M bin/omarchy-pkg-add        ← modified content, should not be
```

Two lessons: **`tee` follows symlinks and `install` does not**, and a git
checkout is a good detector of accidental writes in places that should be
immutable.

### And a third one that the same `git status` discovered

```
 mode change 100644 => 100755 bin/omarchy-remove-service-dropbox
```

A `chmod +x` on the tree binaries left the checkout dirty, and
`git pull --ff-only` refuses to update with pending changes. It is solved
with `git config core.fileMode false` **before** the chmod.

### Result

With that, a complete cycle goes through prune, snapshot, `git pull` of the
tree, keyring, `pacman -Syu`, migrations, hook, AUR and mise:

```
Omarchy tree:       2c247e3  (0 dirty files)
migrations:         84 sealed, 0 pending
snapshots:          5
failed units:       0
```

Including a new migration that arrived with the pull and applied itself.

---

## The UTM bundle, written by hand

UTM does not let you create machines from the command line: `utmctl` only
manages the life cycle. But the `.utm` format is documented in the source
code and a hand-written `config.plist` works perfectly.

Three things you need to know:

**The ten top-level keys are mandatory.** They are decoded with
`decode()`, not with `decodeIfPresent()`: omitting even an empty `<array/>`
makes UTM reject the bundle. They are `Information`, `System`, `QEMU`,
`Input`, `Sharing`, `Display`, `Drive`, `Network`, `Serial` and `Sound`.

**The VARS half of aarch64 UEFI firmware is `edk2-arm-vars.fd`**, not
`edk2-aarch64-vars.fd`, which does not exist. The CODE half is provided by
UTM at runtime.

**UTM does not watch the machines folder.** `listRefresh()` runs once, at
application launch. A bundle copied there while UTM is open is invisible
until you quit and reopen.

The keys that matter for performance:

```xml
<key>Architecture</key> <string>aarch64</string>
<key>Target</key>       <string>virt</string>
<key>Hypervisor</key>   <true/>                      <!-- HVF, no emulation -->
<key>Hardware</key>     <string>virtio-gpu-gl-pci</string>
<key>UEFIBoot</key>     <true/>
```

---

## Preparing the image for distribution

An image that someone else is going to use carries more inside it than it
seems: SSH keys, the `machine-id`, the SSH server's host keys, git identity,
shell histories, saved wifi networks and logs.

```bash
# machine identity (they regenerate themselves on boot)
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_*

# personal identity
rm -rf /home/$U/.ssh /home/$U/.gnupg /home/$U/.gitconfig /home/$U/.bash_history
rm -f  /etc/NetworkManager/system-connections/*

# logs and caches
rm -rf /var/log/journal/* /var/cache/pacman/pkg/*

# the backups usermod leaves contain the old user and hash
rm -f /etc/passwd- /etc/shadow- /etc/group-

# free unused space so the qcow2 compresses better
fstrim -av
```

A detail that is easy to miss: if `/usr/share/omarchy` is a symbolic link to
a user's `$HOME`, renaming that user breaks the system. Convert it into a
real directory before renaming anything.

And afterwards, compact:

```bash
# -c compresses the clusters inside the qcow2 itself: the image takes half
# the space even after unzipping, at the cost of decompressing on read
qemu-img convert -c -O qcow2 dist.qcow2 slim.qcow2   # 11.6 GB → 6.6 GB
qemu-img check slim.qcow2
zip -r -1 omarchy-arm-utm.zip "Omarchy ARM.utm"
```

And a precaution you only learn by breaking it: **after sanitising, the
image must not be booted again**. The first boot regenerates
`/etc/machine-id`, the randomness seed and the logs; if you boot to check
something, you have to repeat the sanitisation. Verifying without dirtying
is done with an overlay:

```bash
qemu-img create -f qcow2 -b slim.qcow2 -F qcow2 test.qcow2
```

---

## What you get, and what you do not

**It works:** native aarch64 Arch Linux ARM with HVF, `linux-aarch64` 7.2
kernel, btrfs with subvolumes and zstd compression, Hyprland 0.56.1 with the
full Omarchy 4 stack — quickshell as bar, menu, OSD and notification daemon,
hyprlock, hypridle, uwsm, SDDM with autologin —, the themes, the 439
`omarchy-*` commands, and `omarchy-update`.

**It does not work:** GL acceleration inside the VM (software rendering), and
`herdr`, which requires Zig 0.15 semantics when the repositories are already
on 0.16 — on ARM and x86_64 alike. Proprietary apps (1Password, Obsidian,
Typora, LocalSend, Chrome) do not travel inside for licensing reasons, but
they all have an official ARM64 build and `omarchy-arm-extras` fetches them
from their origin.

**And it is worth saying clearly:** this is not Omarchy. It is a
reconstruction of the Omarchy desktop on a different base. Omarchy supports
x86_64; when they publish the aarch64 ISO they already have planned, this
work will stop being necessary.

---

## Auditing the script: 37 defects where I thought there were none

The question was simple: "do we have a single script capable of installing
EVERYTHING from scratch, avoiding every known problem?". My impression was
yes. I could have answered that.

Instead of trusting my impression, I crossed the script against its own
sources of truth — the 16 scripts in `fixes/`, the findings of this article, a
simulated run on a clean Mac — and ran each finding through an independent
refuter whose job was to knock it down. **37** survived, nine of them
blockers. All of them had been there for days. None had shown its face.

They group into three shapes, and all three have something in common: **the
system kept working**.

### 1 · Dead code because of permissions

`stage3` runs as a normal user. It checked like this whether it had to
install the optional-app installer:

```bash
if [ -f /root/prov/omarchy-arm-extras ]; then
```

`/root` is `0750`. An unprivileged user cannot even `stat` inside it, so the
condition **returns false without erroring**. The entire block had been going
days without ever running, in silence. Same with the update hook.

### 2 · Destructive order inside the same script

The sanitiser, in step 7:

```bash
rm -rf /root/prov /root/.bash_history /root/.cache
```

And in steps 8a and 8b, twenty-five lines further down, it reads the hook and
the installer from `/root/prov`. It deleted its own input before using it.
The log said, meekly, "it did not come in the repair ISO", and I had blamed
the filename inside the ISO.

### 3 · Phases structurally incapable of failing

This is the systemic one, and the one that interests me most. The script uses
`set -uo pipefail` **without `-e`**, and each phase is a function that
returns the status of its last command, which is almost always an
`ok "..."`. Result: four of the eight phases could not fail.

| Phase | How it swallowed the error |
|---|---|
| `build` | `su - user -c stage3.sh \|\| warn` — a `stage3` that blew up entirely still reported a correct disk |
| `utm` | `make-utm.sh ... \| tail -4` followed by `ok` — the pipe discards the exit code |
| `verify` | collected `pgrep -c Hyprland` and never compared it with anything |
| `fetch` | announced "MD5 verified" even if the checksum `curl` had failed |

The common shape is recognisable: **a success message that depends on
nothing**. It is worth hunting for it on purpose in any long script:
`grep -n "|| warn\| | tail" build.sh` finds most of them.

### And one in the fix itself

When adding interactive mode I wrote a `confirm` with `${ans,,}` to
lowercase the answer. `bash -n` accepted it. When testing it under a
simulated terminal with `expect`:

```
build-omarchy-arm.sh: line 91: ${ans,,}: bad substitution
```

`${var,,}` is from bash 4. **macOS ships bash 3.2**, and there an expansion
error aborts the entire function: `confirm` did not return "no", it returned
garbage, and the script continued as if you had accepted. A failure of the
same family as the ones I was fixing, committed while fixing them.

The operational lesson: `bash -n` validates syntax, not semantics or
version. For interactive code you have to run it against a real pty.

### And the only test that counts: running it

With the 37 fixes in place, everything verified by reading and with the
payloads synchronised byte for byte, the usual question remained: does it
work? A complete from-scratch build, eight phases, on an M3 Max.

It found **three more failures that no reading had seen**:

| Failure | How it showed up |
|---|---|
| `VM_FULLNAME=Omarchy ARM` unquoted in `config.env` | on `source`, `ARM` was executed as a command → dead chroot with `rc=127` |
| the `verify` heredoc unquoted | the **host** bash expanded the `$(...)`, so the checks ran on the Mac: `systemctl: command not found` |
| `spice-vdagentd` is a `static` unit | `systemctl enable` on it does nothing; you have to enable the `.socket` |

The first two I introduced myself while fixing the other thirty-seven. The
third had been there from the beginning.

And the result, with everything corrected:

```
16/17 tools compiled (only herdr fails, because of the Zig version)
extras=si  menu=si  hook=si          ← the three blockers, resolved
verify inside the guest:
  ### H=1 Q=1 BINS=439 ROTOS=1 UNITS=7 VER=4 CLIP=5/5
  VEREDICTO_OK
final image: 3.6 GB · 76 min from deps to package
```

That verdict is from the certification run, with the builder already
corrected. It is worth looking at it twice, because for months it meant
nothing: the host checked with `grep -qa VEREDICTO_OK` on the log, and the
log contains the **echo** of the command itself, which has `then echo
VEREDICTO_OK` inside it. The phase could not fail. The log of the image I
ended up publishing proves it: line 6 is the echo, line 8 says
`VEREDICTO_KO`, and the builder sang success. Now the token travels split —
`VERED"ICTO_OK"` — which is something the echo cannot contain.

That `extras=si menu=si hook=si` is the proof that matters: they are the
three that had gone days without ever being installed, in silence, and that
no previous run had reported because the script declared itself correct
anyway.

---

## Reproducing it

The complete process is in a single script with resumable phases:

```bash
./build-omarchy-arm.sh              # asks just enough and builds
./build-omarchy-arm.sh --yes        # unattended, with the default values
./build-omarchy-arm.sh --from build # resume from a phase
./build-omarchy-arm.sh --list       # see the phases
```

Phases: `deps`, `fetch`, `prepare`, `build`, `utm`, `verify`, `sanitize`,
`package`.

With a terminal it asks six things, all pre-filled with what it detects from
the Mac — timezone from `/etc/localtime`, keyboard from macOS preferences,
cores and RAM from `sysctl` — so they are answered with Enter. Three change
the result: whether to compile the tools (~40 min), whether to include OBS
Studio and Pinta (~45 min, the most expensive of all) and whether to prepare
the image for distribution. Choosing "VM for you" trims the phases to
`deps…verify` and keeps your user. With no terminal, or with `--yes`, it asks
nothing and builds the complete image, ready to distribute.

Asking only that is deliberate. The other fifteen parameters — Alpine
version, rootfs URL, Omarchy branch, locales — are implementation details,
not decisions: a question nobody wants to answer is noise.

The `prepare` phase deserves a comment. Instead of carrying a fixed package
list, it computes it on every run by crossing Omarchy's live branch with the
Arch Linux ARM index. That way the build does not break when Omarchy changes
packages — which it will — and it reports what was left out.

---

## What this exercise teaches

Almost all of the time went into things you cannot anticipate by reading
documentation: a default branch that is not the one the project documents, a
change of distribution model mid-version, a graphics-composition problem that
is only isolated by comparing two different terminals, and a state machine —
the migrations — that an installer initialises and a git clone does not.

The pattern that paid off most was **building the discriminating test**:
when the windows were not visible, comparing `foot` against `alacritty`
pointed at the cause in a minute, after a good while flailing at environment
variables. And the error that cost the most time was trusting a test method
— launching applications over SSH — that did not reproduce the real
conditions.
