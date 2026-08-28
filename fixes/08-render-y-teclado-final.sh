export XDG_RUNTIME_DIR=/run/user/1000 PATH=/usr/local/bin:$PATH
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy

echo "=== reinforcement: uwsm env (any app launched by the session) ==="
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
# Under virtio-gpu/virgl, GPU-client windows map but do not
# paint. With llvmpipe they deliver wl_shm buffers and are visible.
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF
systemctl --user set-environment LIBGL_ALWAYS_SOFTWARE=1
cat ~/.config/uwsm/env.d/20-vm-graphics

echo "=== restarting the shell to release the stuck menu ==="
omarchy-restart-shell >/dev/null 2>&1 || { pkill -f "quickshell -n -p"; sleep 2; setsid omarchy-launch-shell >/dev/null 2>&1 & }
sleep 8

echo "=== opening a terminal with the session environment ==="
pkill -x alacritty 2>/dev/null; sleep 1
env LIBGL_ALWAYS_SOFTWARE=1 setsid alacritty >/dev/null 2>&1 &
sleep 8
hyprctl clients 2>/dev/null | grep -E "class:|mapped:|title:" | head -6
grim /tmp/listo.png && ls -l /tmp/listo.png
