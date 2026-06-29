# Workstation / server setup (Ansible)

Two playbooks, run **locally** on each machine (no control node):

- `fedora.yml` — Fedora workstation (full GUI desktop). Docs below.
- `raspbian.yml` — Raspberry Pi OS headless server: core CLI packages,
  Neovim built from source (apt's is too old), Meslo Nerd Font, dotfiles +
  stow, zsh, and Tailscale. No GUI/desktop/tray.

  ```bash
  ansible-playbook raspbian.yml --ask-become-pass
  ansible-playbook raspbian.yml --ask-become-pass --tags dotfiles,shell
  ```

  Tags: `system`, `tools`, `fonts`, `neovim`, `dotfiles`, `shell`, `services`.
  Toggles in the `vars:` block: `install_nerd_font`, `enable_tailscale`,
  `enable_docker`.
  Pinned: `nerd_font_version`, `neovim_version`. Tailscale login is still
  manual (`sudo tailscale up`).

---

# Fedora workstation setup (Ansible)

Reproducibly provisions a Fedora machine to match my setup: CLI tooling,
GUI apps, fonts, dotfiles, shell, and services. Replaces the old NixOS config.

A single playbook (`fedora.yml`), run **locally** on each machine (no control
node needed).

## What it does

| Step (tag)    | Result |
|---------------|--------|
| `system`      | Core CLI packages (zsh, neovim, tmux, stow, fzf, zoxide, bat, git, build tools…). Locale/timezone/keyboard are left to the Fedora installer. |
| `repos`       | Adds official vendor RPM repos: VS Code, Google Chrome, Tailscale, and the `scottames/ghostty` COPR |
| `packages`    | GUI apps via RPM: firefox, ghostty, code, google-chrome-stable. Obsidian + Zen Browser via Flatpak (no official RPM). Sets Zen as the default browser |
| `fonts`       | Meslo Nerd Font (pinned release) into `~/.local/share/fonts` |
| `gnome`       | GNOME prefs via dconf: key repeat, touchpad scroll/speed, dark theme, background |
| `dev`         | bun and pnpm via official install scripts (no RPM exists) |
| `dotfiles`    | Clones this repo + submodules and `stow`s it into `$HOME` |
| `shell`       | Sets zsh as the default shell |
| `services`    | Enables Tailscale (`tailscaled`) and Syncthing (`syncthing@user`); installs the Tailscale and Syncthing GNOME system-tray applets (AppIndicator extension + autostart). Installs Docker Engine (CLI only, official repo) and adds you to the `docker` group |

## Prerequisites on a fresh machine

1. **Ansible**: `sudo dnf install ansible git`
2. **SSH key registered with GitHub** — the dotfiles repo and several submodules
   use `git@github.com:` URLs, so cloning needs a working key. Generate with
   `ssh-keygen -t ed25519` and add the public key to GitHub.

## Usage

```bash
# Get this repo (or skip if you cloned the whole dotfiles repo already)
git clone git@github.com:alastairgarner/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles/ansible

# Install the one Galaxy collection used (flatpak + copr modules)
ansible-galaxy collection install -r requirements.yml

# Dry run to preview changes
ansible-playbook fedora.yml --ask-become-pass --check

# Apply
ansible-playbook fedora.yml --ask-become-pass
```

`--ask-become-pass` prompts for your sudo password (needed for dnf, repos,
services, and setting the shell).

### Run only part of it

```bash
ansible-playbook fedora.yml --ask-become-pass --tags dotfiles,shell
ansible-playbook fedora.yml --ask-become-pass --tags packages
```

Tags: `system`, `repos`, `packages`, `fonts`, `gnome`, `dev`, `dotfiles`, `shell`, `services`.

> The `gnome` tag uses per-user dconf, so run the playbook **from inside your
> GNOME session** (not a TTY/SSH-only context) or those tasks will have no
> session bus to write to.

### Deferring SSH (run packages before sorting GitHub auth)

The only part that needs GitHub SSH is `dotfiles`. To install everything else
first, then come back for dotfiles once your key is set up:

```bash
ansible-playbook fedora.yml --ask-become-pass --skip-tags dotfiles
# ... set up the SSH key, add it to GitHub ...
ansible-playbook fedora.yml --ask-become-pass --tags dotfiles
```

## Per-machine customisation

Edit the `vars:` block at the top of `fedora.yml` (or override on the CLI with
`-e`). Toggles:

```yaml
install_gui_apps: true       # set false on a headless box
install_dev_runtimes: true   # bun + pnpm
enable_tailscale: true
enable_syncthing: true
enable_docker: true          # Docker Engine, CLI only
```

Example — a headless server without GUI apps or syncthing:

```bash
ansible-playbook fedora.yml --ask-become-pass \
  -e install_gui_apps=false -e enable_syncthing=false
```

## Manual steps the playbook intentionally leaves to you

- **Tailscale login**: run `sudo tailscale up` once per machine (interactive auth).
  (Operator permission for the tray applet is set automatically by the playbook.)
- **`~/.env`**: copy `~/.env.template` to `~/.env` and fill in secrets (tokens).
  These are deliberately not in source control.
- **Log out / back in** after the first run so the zsh default shell, the
  GNOME AppIndicator extension, and the Tailscale + Syncthing tray applets take
  effect.

## Notes on install sources

RPM-first, using each vendor's officially supported method:

- **Native RPM repos**: VS Code, Google Chrome, Tailscale (vendor repos);
  syncthing, neovim, firefox (Fedora repos).
- **COPR**: Ghostty — no official Fedora RPM yet; `scottames/ghostty` is the
  path Ghostty's own docs point to.
- **Flatpak**: Obsidian (`md.obsidian.Obsidian`), Zen Browser
  (`app.zen_browser.zen`), and Syncthing Tray
  (`io.github.martchus.syncthingtray`) — none ship an official `.rpm`; Flathub
  is the vendor-endorsed Linux package for all three.
- **Vendor scripts**: bun and pnpm — no official RPMs; the curl install scripts
  are the supported method. Versions are not pinned by these scripts.

Pinned for reproducibility: the Meslo Nerd Font version (`nerd_font_version`
in `fedora.yml`). Bump it deliberately.
