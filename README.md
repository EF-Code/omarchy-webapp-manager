# Web App Manager

An Omarchy bar plugin for discovering, launching, installing, and removing user-owned web-app launchers.

## Preview

![Web App Manager panel](assets/web-app-manager.png)

## Status

This is the first implementation pass. It supports the core workflow:

- Scan Omarchy web-app desktop entries in the user application directory.
- Search and launch an installed web app.
- Install a new web app through `omarchy webapp install`.
- Move a selected launcher to the user trash for reversible removal.
- Report invalid URLs, missing icons, and protocol handlers.

The plugin deliberately does not expose arbitrary desktop-file `Exec=` commands or MIME-type editing yet.

## Install for local development

Clone or copy this repository into the Omarchy user plugin directory:

```bash
mkdir -p ~/.config/omarchy/plugins
ln -sfn "$PWD" ~/.config/omarchy/plugins/io.github.ef-code.webapp-manager
```

Add the widget to the bar using the normal Omarchy plugin workflow, then reload the shell if needed:

```bash
omarchy-shell shell rescanPlugins
```

## Native commands used

The plugin uses Omarchy's existing command surface for installation:

```text
omarchy webapp install [name url icon-url-or-name]
omarchy webapp remove [name]
omarchy-launch-webapp <url>
```

The helper scans only `${XDG_DATA_HOME:-$HOME/.local/share}/applications` and refuses to mutate system desktop entries.

## Validation

```bash
omarchy plugin validate .
qmllint -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" \
  BarWidget.qml Panel.qml WebAppController.qml
bash -n scripts/webapp-managerctl
scripts/webapp-managerctl scan | jq .
```

## Roadmap

- Browser/profile selection using an allowlisted command template.
- Icon preview and refresh.
- Desktop-entry repair and backup history.
- MIME association management with an explicit warning.
- Import/export of web-app definitions.
