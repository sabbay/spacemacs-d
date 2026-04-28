# Per-machine macOS setup

Most of the perf config lives in `init.el` / `lisp/perf.el` / `lisp/user-init.el`
and replicates via `git pull`. The steps below can't — they touch macOS
system state (Spotlight DB, Time Machine config, launchd) so they have to
be applied once on each machine.

## 1. Exclude `eln-cache` from Spotlight and Time Machine

Native-comp writes thousands of `.eln` files under `~/.emacs.d/eln-cache/`.
They're regenerable, machine-specific, and rewritten on every package
upgrade. Indexing/backing them up is pure waste.

```sh
# Stop Spotlight from indexing the cache.
# `.metadata_never_index' is Apple's documented per-directory opt-out
# (mdutil -i only works on volume roots in modern macOS).
touch ~/.emacs.d/eln-cache/.metadata_never_index

# Skip the cache in Time Machine backups
tmutil addexclusion ~/.emacs.d/eln-cache
```

GUI alternatives:
- System Settings → Spotlight → Search Privacy → `+` → pick the folder
- System Settings → General → Time Machine → Options → `+` → pick the folder

Reverse by deleting the sentinel file (`rm
~/.emacs.d/eln-cache/.metadata_never_index`) and `tmutil
removeexclusion …`.

## 2. AOT-compile installed packages once

After `SPC f e R` (or the first start on a new machine):

```
M-x native-compile-async RET ~/.emacs.d/elpa RET y RET
```

`y` to recurse, leave the load-after-compile prompt at default. Takes
5–15 minutes in the background. Re-run after major package upgrades or
an Emacs minor-version bump (the `.eln` cache is keyed on Emacs version).

## 3. Daemon + emacsclient

Cold-open `Emacs.app` is 2–5s; `emacsclient -nc` against a running
daemon is ~50ms. Set it up via launchd:

```sh
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/gnu.emacs.daemon.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>gnu.emacs.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/opt/emacs-plus@30/bin/emacs</string>
    <string>--fg-daemon</string>
  </array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>/tmp/emacs.daemon.out</string>
  <key>StandardErrorPath</key> <string>/tmp/emacs.daemon.err</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/gnu.emacs.daemon.plist
```

Then bind a Raycast / Alfred / hotkey to:

```sh
emacsclient -nc
```

(`-n` = don't wait, `-c` = new frame). Don't use `open -a Emacs` — that
spawns a fresh process and bypasses the daemon.

Adjust the `emacs` path if you use a different build (`brew --prefix
emacs-plus@30` to check).

## 4. Optional: rebuild emacs-plus with --with-poll

The default macOS build uses `select()`, which caps at 1024 file
descriptors. With many LSP servers + file watchers + processes you can
hit that cap. `--with-poll` switches to `poll()` (no cap):

```sh
brew reinstall emacs-plus@30 --with-native-comp --with-poll --with-imagemagick --with-xwidgets
```

Skip if you don't run multiple LSP-heavy projects at once.

## 5. Low Power Mode caveat

macOS throttles background native-comp jobs in Low Power Mode (Settings
→ Battery → Low Power Mode). Either keep it off when on AC, or pin the
job count to fit the efficiency cores by adding to `lisp/perf.el`:

```elisp
(setq native-comp-async-jobs-number 2)
```

Default is `nil` (use all cores), which is what you want on AC.
