# HomeLab Launcher for Omarchy

A compact, keyboard-friendly launcher for HomeLab services and favorite links. It follows the active Omarchy theme and stores each user's links outside the plugin checkout, so updates never replace personal data.

## Features

- Native Omarchy colors, typography, borders, and controls
- Compact five-column layout with stable card sizing while searching
- Keyboard navigation with arrow keys, `h/j/k/l`, and `Tab`
- Instant search by typing or pressing `/`
- Add, remove, and drag-to-reorder editing mode
- SVG and PNG icons from URLs, absolute paths, or the plugin's `assets/` directory
- Personal data stored in `~/.config/omarchy/homelab-launcher/services.json`

## Install

```bash
omarchy plugin add https://github.com/Elvis-Christian/omarchy-homelab-launcher.git --enable
```

Add a keybinding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Y", "HomeLab launcher", "omarchy-shell shell toggle io.github.elvis-christian.homelab-launcher")
```

If `SUPER + Y` is already bound, unbind it immediately before the new binding:

```lua
hl.unbind("SUPER + Y")
```

Apply and validate the Hyprland configuration:

```bash
hyprctl reload
hyprctl configerrors
```

## Use

- `Super + Y`: open or close
- Arrow keys or `h/j/k/l`: navigate
- `Tab` / `Shift + Tab`: next or previous item
- `Enter`, `Space`, or click: open
- `/` or normal typing: search
- `Esc`: clear search, then close
- `EDIT` switch: add, remove, or reorder links

The Omarchy card is shown only when needed to complete the unfiltered grid.

## Update

```bash
omarchy plugin update io.github.elvis-christian.homelab-launcher
```

## Remove

Remove the `SUPER + Y` binding from `~/.config/hypr/bindings.lua`, then run:

```bash
omarchy plugin remove io.github.elvis-christian.homelab-launcher
```

Personal links remain in `~/.config/omarchy/homelab-launcher/services.json`. Delete that directory manually only if you also want to remove your launcher data.

## Dependencies and permissions

- Omarchy Quattro with `omarchy-shell`
- Quickshell and Hyprland as provided by Omarchy
- `xdg-open` to launch URLs

The plugin runs unsandboxed as part of `omarchy-shell`. It creates and updates only `~/.config/omarchy/homelab-launcher/services.json` and opens user-configured URLs through `xdg-open`. It does not require root privileges, network downloads, install hooks, or additional packages.

## License

MIT — see [LICENSE](LICENSE).
