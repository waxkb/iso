# iso

Custom minimal NixOS installer ISO with bcachefs support.

The live system uses the current mainline kernel without ZFS, because the
out-of-tree bcachefs module in the default kernel currently fails to compile
against that kernel's inode API.

## Build

```sh
./build.sh
# or
nix build .#nixosConfigurations.iso.config.system.build.isoImage
```

The image is exposed through `./result`.

## Installer

`install.sh` is baked into the ISO at `/etc/nixos-installer/install.sh`:

```sh
sudo bash /etc/nixos-installer/install.sh
```

It:

1. Prompts for hostname, form factor, timezone, keyboard layout, passwords,
   and target disk. Hardware defaults are detected.
2. Detects CPU vendor, GPU vendor(s), and laptop/desktop form factor.
3. Clones the `waxkb/nixos` flake and lists `modules/optional/*.nix`, asking
   yes/no for each file. Nothing about the optional list is hardcoded.
4. Auto-includes modules declared with `# requires:`.
5. Writes `hosts/<hostname>/{default,configuration,modules,meta}.nix`, the
   generated hardware config, and commits the host so the flake sees it.
6. Optionally adds a `deploy.nodes` entry for the host.
7. Partitions (1G ESP + bcachefs root, plus laptop swap capped at 16G),
   installs, copies the repo to `~/nixos`, symlinks `/etc/nixos`, and stows
   dotfiles.

Override the source repo for testing with:

```sh
NIXOS_REPO_URL=/path/to/nixos sudo -E bash /etc/nixos-installer/install.sh
```
