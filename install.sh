#!/usr/bin/env bash
# NixOS full-disk installer for the waxkb/nixos flake.
#
# Run as root inside the custom minimal ISO:
#   sudo bash /etc/nixos-installer/install.sh
#
# The installer:
#   1. Prompts for system information (hostname, form factor, timezone,
#      keyboard layout, passwords, target disk) with detected defaults.
#   2. Detects CPU/GPU vendors for the hardware modules.
#   3. Loops over every file in modules/optional/ and asks whether to include
#      it. Nothing about the optional list is hardcoded here.
#   4. Adds hosts/<hostname>/{default,configuration,modules,meta}.nix plus the
#      generated hardware config, and commits it so the flake sees it.
#   5. Optionally registers the host as a deploy-rs node in meta.nix.
#   6. Partitions, formats, installs, copies the repo to ~/nixos, symlinks
#      /etc/nixos, and optionally stows dotfiles.

set -euo pipefail

readonly REPO_URL="${NIXOS_REPO_URL:-https://github.com/waxkb/nixos.git}"
readonly DOTFILES_URL="${DOTFILES_URL:-https://github.com/waxkb/dotfiles.git}"
readonly STOW_PKGS="niri foot noctalia tofi starship git gita matugen yazi broot mime hypr scripts"
readonly WORKDIR="/tmp/nixos-install"
readonly STATE_FALLBACK="26.11"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found in the ISO"
}

ask() { # $1=prompt $2=var_name $3=default(optional)
  local prompt="$1" var="$2" def="${3:-}" ans
  if [ -n "$def" ]; then
    printf '%s [%s]: ' "$prompt" "$def"
  else
    printf '%s: ' "$prompt"
  fi
  IFS= read -r ans || die "input aborted"
  ans="$(trim "$ans")"
  if [ -z "$ans" ] && [ -n "$def" ]; then ans="$def"; fi
  printf -v "$var" '%s' "$ans"
}

ask_yn() { # $1=prompt $2=default (y/n/yes/no)
  local prompt="$1" def="${2:-n}" ans
  case "$def" in
    yes|Y|y) def=y ;;
    *) def=n ;;
  esac
  while true; do
    if [ "$def" = y ]; then
      printf '%s [Y/n]: ' "$prompt"
    else
      printf '%s [y/N]: ' "$prompt"
    fi
    IFS= read -r ans || die "input aborted"
    ans="$(trim "$ans")"
    ans="${ans:-$def}"
    case "$ans" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) printf 'answer y or n\n' ;;
    esac
  done
}

ask_secret() { # $1=prompt $2=var_name (hidden, confirmed, non-empty)
  local prompt="$1" var="$2" a b
  while true; do
    printf '%s: ' "$prompt"
    IFS= read -rs a || die "input aborted"
    printf '\n'
    [ -n "$a" ] || { printf 'password must not be empty\n'; continue; }
    printf '%s (confirm): ' "$prompt"
    IFS= read -rs b || die "input aborted"
    printf '\n'
    if [ "$a" = "$b" ]; then
      printf -v "$var" '%s' "$a"
      return
    fi
    printf 'passwords do not match, try again\n'
  done
}

hash_pw() { # $1=password; prints $6$ SHA-512 crypt hash
  local pw="$1" salt
  salt="$(head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9./' | cut -c1-16)"
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m sha-512 -S "$salt" "$pw"
  elif command -v openssl >/dev/null 2>&1; then
    openssl passwd -6 -salt "$salt" "$pw"
  else
    die "neither mkpasswd (whois) nor openssl found; rebuild the ISO from ~/iso"
  fi
}

chown_as_max() { # $1=path on the target; best effort
  chown -R 1000:100 "$1" 2>/dev/null || \
    chown -R 1000:users "$1" 2>/dev/null || true
}

detect_form() {
  local chassis=""
  if compgen -G '/sys/class/power_supply/BAT*' >/dev/null 2>&1; then
    printf 'laptop'
    return
  fi
  if command -v dmidecode >/dev/null 2>&1; then
    chassis="$(dmidecode -s chassis-type 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    case "$chassis" in
      *notebook*|*laptop*|*portable*|*sub-notebook*|*convertible*|*detachable*)
        printf 'laptop'
        return
        ;;
    esac
  fi
  chassis="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || true)"
  case "$chassis" in
    8|9|10|14) printf 'laptop' ;;
    *) printf 'desktop' ;;
  esac
}

detect_cpu() {
  local cpuinfo intel=0 amd=0
  cpuinfo="$(cat /proc/cpuinfo 2>/dev/null || true)"
  if grep -qi genuineintel <<<"$cpuinfo"; then intel=1; fi
  if grep -qi authenticamd <<<"$cpuinfo"; then amd=1; fi
  if (( intel && amd )); then
    printf 'both'
  elif (( intel )); then
    printf 'intel'
  elif (( amd )); then
    printf 'amd'
  else
    printf 'both'
  fi
}

HAVE_NVIDIA=0
HAVE_AMD=0
HAVE_INTEL=0
detect_gpus() {
  local gpu_lc
  GPU_PCI="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || true)"
  gpu_lc="$(printf '%s' "$GPU_PCI" | tr '[:upper:]' '[:lower:]')"
  case "$gpu_lc" in *nvidia*) HAVE_NVIDIA=1 ;; esac
  case "$gpu_lc" in *amd*|*ati*|*radeon*) HAVE_AMD=1 ;; esac
  case "$gpu_lc" in *intel*) HAVE_INTEL=1 ;; esac
}

module_description() {
  sed -n 's/^# description: //p' "$1" | head -n 1
}

module_default() {
  local d
  d="$(sed -n 's/^# installer-default: //p' "$1" | head -n 1)"
  case "$d" in yes|y|Y|true) printf 'y' ;; *) printf 'n' ;; esac
}

module_selected() {
  local want="$1" m
  for m in "${SELECTED_OPTIONAL[@]}"; do
    [ "$m" = "$want" ] && return 0
  done
  return 1
}

module_requires() {
  sed -n 's/^# requires: //p' "$1" | tr ',' ' '
}

resolve_module_dependencies() {
  local i m dep file changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    for ((i = 0; i < ${#SELECTED_OPTIONAL[@]}; i++)); do
      m="${SELECTED_OPTIONAL[$i]}"
      file="$WORKDIR/modules/optional/$m.nix"
      for dep in $(module_requires "$file"); do
        [ -f "$WORKDIR/modules/optional/$dep.nix" ] \
          || die "module '$m' requires unknown module '$dep'"
        if ! module_selected "$dep"; then
          SELECTED_OPTIONAL+=("$dep")
          info "auto-including required module '$dep' (needed by '$m')"
          changed=1
        fi
      done
    done
  done
}

(( $# == 0 )) || die "this installer takes no arguments (usage: sudo bash install.sh)"

# ---------- preconditions ----------
[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash install.sh)"
[ -d /sys/firmware/efi ] || die "no UEFI detected (/sys/firmware/efi missing). BIOS installs are not supported"
for t in git sgdisk partprobe wipefs mkfs.vfat mkfs.bcachefs mkswap swapon \
         nixos-generate-config nixos-install lspci mount umount lsblk udevadm \
         sed grep awk; do
  need_cmd "$t"
done
command -v mkpasswd >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 \
  || die "need mkpasswd (whois) or openssl for password hashing; rebuild the ISO from ~/iso"

info "checking network (needed to clone the flake and dotfiles)..."
if ! getent hosts github.com >/dev/null 2>&1; then
  warn "cannot resolve github.com; use nmcli to join Wi-Fi if the clone fails"
fi

# ---------- system information ----------
info "system information"

HOSTNAME=""
while true; do
  ask "hostname for the new machine (hosts/<name>)" HOSTNAME
  if [[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then break; fi
  printf 'invalid hostname: use lowercase letters, digits, dashes (max 63 chars)\n'
done

DETECTED_FORM="$(detect_form)"
FORM=""
while true; do
  ask "is this a laptop or a desktop? (laptop adds swap + power/bluetooth stack)" FORM "$DETECTED_FORM"
  FORM="$(printf '%s' "$FORM" | tr '[:upper:]' '[:lower:]')"
  case "$FORM" in laptop|desktop) break ;; *) printf "answer 'laptop' or 'desktop'\n" ;; esac
done
IS_LAPTOP=0
[ "$FORM" = "laptop" ] && IS_LAPTOP=1

TIMEZONE=""
ask "timezone" TIMEZONE "America/Los_Angeles"
if [ -d /etc/zoneinfo ] && [ ! -e "/etc/zoneinfo/$TIMEZONE" ]; then
  warn "timezone '$TIMEZONE' not found in /etc/zoneinfo; keeping it anyway"
fi

KEYBOARD=""
while true; do
  ask "X11 keyboard layout" KEYBOARD "us"
  [[ "$KEYBOARD" =~ ^[a-zA-Z0-9,_-]+$ ]] && break
  printf 'invalid keyboard layout\n'
done

ROOT_PW=""
USER_PW=""
ask_secret "password for root" ROOT_PW
ask_secret "password for user max" USER_PW

# ---------- disk selection ----------
info "disk selection"
CANDIDATES=()
while read -r dev dtype; do
  [ "$dtype" = "disk" ] || continue
  case "$dev" in
    /dev/loop*|/dev/ram*|/dev/fd*|/dev/sr*|/dev/dm-*) continue ;;
  esac
  CANDIDATES+=("$dev")
done < <(lsblk -dnr -o PATH,TYPE 2>/dev/null || lsblk -dnr -o NAME,TYPE 2>/dev/null | sed 's|^|/dev/|')
[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidate disks found (lsblk showed nothing usable)"

printf 'candidate disks:\n'
for idx in "${!CANDIDATES[@]}"; do
  printf '  %d) %s  [%s]\n' "$((idx + 1))" "${CANDIDATES[idx]}" \
    "$(lsblk -dnr -o SIZE,MODEL "${CANDIDATES[idx]}" 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
done
printf '\n'

DISK=""
while true; do
  pick=""
  ask "target disk to WIPE: number from the list, or a full /dev/... path (q to abort)" pick
  case "$pick" in
    q|Q|quit|abort|exit) die "aborted (nothing was touched)" ;;
  esac
  if [[ "$pick" =~ ^[0-9]+$ ]]; then
    num=$((10#$pick))
    if (( num >= 1 && num <= ${#CANDIDATES[@]} )); then
      DISK="${CANDIDATES[$((num - 1))]}"
      break
    fi
  elif [[ "$pick" == /dev/* ]] && [ -b "$pick" ]; then
    DISK="$pick"
    printf '%s\n' "${CANDIDATES[@]}" | grep -qxF "$DISK" \
      || warn "$DISK was not in the detected list, but it is a block device; continuing"
    break
  fi
  printf "'%s' is neither a menu number nor an existing block device.\n" "$pick"
done
case "$DISK" in
  *loop*|*ram*|*sr[0-9]*|*dm-*) die "refusing to install onto $DISK" ;;
esac

info "current layout of $DISK:"
lsblk "$DISK" || true
sgdisk -p "$DISK" || true
printf '\nALL DATA ON %s WILL BE DESTROYED. No encryption, UEFI only.\n' "$DISK"
CONFIRM=""
ask "type the disk path again to confirm the wipe ($DISK)" CONFIRM
[ "$CONFIRM" = "$DISK" ] || die "confirmation mismatch, aborting (nothing was touched)"

if [[ "$DISK" =~ [0-9]$ ]]; then PSEP="p"; else PSEP=""; fi
ESP="${DISK}${PSEP}1"
ROOT_PART="${DISK}${PSEP}2"
SWAP_PART="${DISK}${PSEP}3"

# ---------- hardware detection ----------
CPU_VENDOR="$(detect_cpu)"
detect_gpus
info "detected CPU: $CPU_VENDOR"
info "detected GPUs: nvidia=$HAVE_NVIDIA amd=$HAVE_AMD intel=$HAVE_INTEL"
if (( ! HAVE_NVIDIA && ! HAVE_AMD && ! HAVE_INTEL )); then
  warn "no known GPU detected (VM/unknown?) - continuing with generic modesetting only"
fi

SWAP_GIB=0
if [ "$IS_LAPTOP" -eq 1 ]; then
  MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  MEM_KB="${MEM_KB:-0}"
  SWAP_GIB=$(( (MEM_KB + 1048575) / 1048576 ))
  [ "$SWAP_GIB" -lt 1 ] && SWAP_GIB=1
  [ "$SWAP_GIB" -gt 16 ] && SWAP_GIB=16
  info "laptop swap size: ${SWAP_GIB}G (RAM size, capped at 16G)"
fi

# ---------- clone the flake (needed for the module list) ----------
info "cloning $REPO_URL..."
rm -rf "$WORKDIR"
git clone --depth 1 "$REPO_URL" "$WORKDIR" || die "git clone failed (check network)"
cd "$WORKDIR" || die "could not cd to $WORKDIR"
if [ -d "hosts/$HOSTNAME" ]; then
  die "hosts/$HOSTNAME already exists in the repo; pick another hostname"
fi
if ! grep -q 'readDir ./hosts' flake.nix; then
  die "the cloned flake is outdated: push the refactored nixos repo first, or set NIXOS_REPO_URL to a checkout that has host auto-discovery"
fi
[ -d modules/optional ] || die "cloned repo has no modules/optional directory"

# ---------- optional modules (filename-driven, no hardcoded list) ----------
info "optional modules"
printf 'Answer y/n for each file in modules/optional/. Enter accepts the default.\n'
SELECTED_OPTIONAL=()
for file in "$WORKDIR"/modules/optional/*.nix; do
  name="$(basename "$file" .nix)"
  desc="$(module_description "$file")"
  def="$(module_default "$file")"
  prompt="  $name"
  [ -n "$desc" ] && prompt="$prompt — $desc"
  if ask_yn "$prompt?" "$def"; then
    SELECTED_OPTIONAL+=("$name")
  fi
done
resolve_module_dependencies
info "selected ${#SELECTED_OPTIONAL[@]} optional module(s)"

# ---------- deploy-rs ----------
DEPLOY_ENABLE=0
DEPLOY_HOST="$HOSTNAME"
DEPLOY_USER="root"
if ask_yn "manage this host with deploy-rs?" "y"; then
  DEPLOY_ENABLE=1
  ask "deploy-rs SSH hostname or IP" DEPLOY_HOST "$HOSTNAME"
  ask "deploy-rs SSH user" DEPLOY_USER "root"
fi

printf '\n'
info "summary"
printf '  host:     %s\n' "$HOSTNAME"
printf '  form:     %s\n' "$FORM"
printf '  disk:     %s\n' "$DISK"
printf '  cpu:      %s\n' "$CPU_VENDOR"
printf '  gpus:     nvidia=%s amd=%s intel=%s\n' "$HAVE_NVIDIA" "$HAVE_AMD" "$HAVE_INTEL"
printf '  timezone: %s\n' "$TIMEZONE"
printf '  keyboard: %s\n' "$KEYBOARD"
printf '  deploy:   %s\n' "$([ "$DEPLOY_ENABLE" -eq 1 ] && printf '%s@%s' "$DEPLOY_USER" "$DEPLOY_HOST" || printf 'no')"
printf '  optional: %s\n' "${SELECTED_OPTIONAL[*]:-none}"

GO=""
ask "proceed with WIPE + INSTALL? type YES" GO
[ "$GO" = "YES" ] || die "aborted (nothing was touched)"

# ---------- partition / format / mount ----------
info "wiping $DISK..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all "$DISK"
wipefs -a "$DISK"
partprobe "$DISK" || true
sleep 2

if [ "$IS_LAPTOP" -eq 1 ]; then
  info "creating partitions (1G ESP + bcachefs root + swap)..."
else
  info "creating partitions (1G ESP + bcachefs root)..."
fi
if [ "$IS_LAPTOP" -eq 1 ]; then
  sgdisk -n1:0:+1G -t1:EF00 -c1:boot \
         -n2:0:-"${SWAP_GIB}"G -t2:8300 -c2:nixos \
         -n3:0:0 -t3:8200 -c3:swap "$DISK"
else
  sgdisk -n1:0:+1G -t1:EF00 -c1:boot \
         -n2:0:0 -t2:8300 -c2:nixos "$DISK"
fi
partprobe "$DISK" || true
udevadm settle || sleep 3

info "formatting..."
mkfs.vfat -F32 -n boot "$ESP"
mkfs.bcachefs -f -L nixos "$ROOT_PART"
if [ "$IS_LAPTOP" -eq 1 ]; then
  mkswap -L swap "$SWAP_PART"
fi

info "mounting on /mnt..."
mount -L nixos /mnt
mkdir -p /mnt/boot
mount -L boot /mnt/boot
if [ "$IS_LAPTOP" -eq 1 ]; then
  swapon -L swap || swapon "$SWAP_PART"
fi
lsblk "$DISK"

# ---------- generated host files ----------
info "hashing passwords..."
ROOT_HASH="$(hash_pw "$ROOT_PW")"
USER_HASH="$(hash_pw "$USER_PW")"
ROOT_PW=""
USER_PW=""
[ -n "$ROOT_HASH" ] && [ -n "$USER_HASH" ] || die "password hashing failed"

info "generating hardware-configuration.nix..."
mkdir -p "hosts/$HOSTNAME"
nixos-generate-config --root /mnt --show-hardware-config > "hosts/$HOSTNAME/hardware-configuration.nix" \
  || die "nixos-generate-config failed"

STATEVER="$(nixos-version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if ! [[ "$STATEVER" =~ ^[0-9]+\.[0-9]+$ ]]; then STATEVER="$STATE_FALLBACK"; fi
info "using system.stateVersion = \"$STATEVER\""

HARDWARE_MODULES=()
case "$CPU_VENDOR" in
  intel) HARDWARE_MODULES+=("cpu-intel") ;;
  amd) HARDWARE_MODULES+=("cpu-amd") ;;
  both) HARDWARE_MODULES+=("cpu-intel" "cpu-amd") ;;
esac
(( HAVE_NVIDIA )) && HARDWARE_MODULES+=("gpu-nvidia")
(( HAVE_AMD )) && HARDWARE_MODULES+=("gpu-amd")
(( HAVE_INTEL )) && HARDWARE_MODULES+=("gpu-intel")
(( IS_LAPTOP )) && HARDWARE_MODULES+=("laptop")

info "writing hosts/$HOSTNAME..."
cat > "hosts/$HOSTNAME/default.nix" <<'EOF'
{
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ./configuration.nix
    ./modules.nix
  ];
}
EOF

{
  printf '{\n  imports = [\n'
  for m in "${HARDWARE_MODULES[@]}"; do
    printf '    ../../modules/hardware/%s.nix\n' "$m"
  done
  for m in "${SELECTED_OPTIONAL[@]}"; do
    printf '    ../../modules/optional/%s.nix\n' "$m"
  done
  printf '  ];\n}\n'
} > "hosts/$HOSTNAME/modules.nix"

SWAP_NIX=""
if [ "$IS_LAPTOP" -eq 1 ]; then
  SWAP_NIX="
  swapDevices = lib.mkForce [
    {
      device = \"/dev/disk/by-label/swap\";
    }
  ];
"
fi

cat > "hosts/$HOSTNAME/configuration.nix" <<EOF
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  networking.hostName = "$HOSTNAME";

  system.stateVersion = "$STATEVER";

  time.timeZone = "$TIMEZONE";

  # Overridden by modules/optional/desktop.nix when the desktop is selected.
  services.xserver.xkb.layout = "$KEYBOARD";

  # Installer uses by-label mounts; the generated hardware config is kept
  # verbatim and these mkForce definitions win.
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/nixos";
    fsType = "bcachefs";
  };

  fileSystems."/boot" = lib.mkForce {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
      "noatime"
    ];
  };
$SWAP_NIX
  users.users.max.hashedPassword = "$USER_HASH";
  users.users.root.hashedPassword = "$ROOT_HASH";
}
EOF

cat > "hosts/$HOSTNAME/meta.nix" <<EOF
{
  system = "x86_64-linux";

  deploy = {
    enable = $([ "$DEPLOY_ENABLE" -eq 1 ] && printf 'true' || printf 'false');
    hostname = "$DEPLOY_HOST";
    sshUser = "$DEPLOY_USER";
  };
}
EOF

info "committing hosts/$HOSTNAME so the flake can see it..."
git add "hosts/$HOSTNAME"
git -c user.name=installer -c user.email=installer@localhost \
  commit -m "add $HOSTNAME via installer" \
  || die "could not commit the new host (a dirty flake is not visible to nixos-install)"

# ---------- install ----------
# programs.ccache wraps compilers and needs its cache dir in the live
# installer sandbox too. Must match cacheDir in modules/optional/ccache.nix.
mkdir -p /var/cache/ccache
chmod 0777 /var/cache/ccache
info "running nixos-install --flake .#$HOSTNAME (this takes a while)..."
nixos-install --flake ".#$HOSTNAME" --no-root-passwd --show-trace \
  --option extra-sandbox-paths /var/cache/ccache

# ---------- repo + /etc/nixos on the target ----------
info "setting up /home/max/nixos + /etc/nixos symlink on the target..."
mkdir -p /mnt/home/max
if [ -e /mnt/home/max/nixos ] && [ ! -L /mnt/home/max/nixos ]; then
  rm -rf /mnt/home/max/nixos
fi
cp -a "$WORKDIR" /mnt/home/max/nixos
chown_as_max /mnt/home/max/nixos
rm -rf /mnt/etc/nixos
ln -s /home/max/nixos /mnt/etc/nixos
info "target: /etc/nixos -> /home/max/nixos"

# ---------- dotfiles ----------
info "cloning dotfiles..."
if [ -e /mnt/home/max/dotfiles ] && [ ! -L /mnt/home/max/dotfiles ]; then
  rm -rf /mnt/home/max/dotfiles
fi
if git clone "$DOTFILES_URL" /mnt/home/max/dotfiles; then
  chown_as_max /mnt/home/max/dotfiles
  if ! module_selected stow; then
    warn "the stow module was not selected; on first boot run: nix shell nixpkgs#stow -c stow -d ~/dotfiles $STOW_PKGS"
  elif command -v nixos-enter >/dev/null 2>&1 && \
    nixos-enter --root /mnt -c "su max -s /bin/sh -c 'cd /home/max/dotfiles && stow $STOW_PKGS'"; then
    info "dotfiles stowed: ~/.config wired to ~/dotfiles"
  else
    warn "automatic stow failed; on first boot run: cd ~/dotfiles && stow $STOW_PKGS"
  fi
else
  warn "dotfiles clone failed; on first boot run: git clone $DOTFILES_URL ~/dotfiles && cd ~/dotfiles && stow $STOW_PKGS"
fi

printf '\n'
info "DONE. Installed '$HOSTNAME' ($FORM) onto $DISK."
if [ "$DEPLOY_ENABLE" -eq 1 ]; then
  info "deploy-rs entry created for ${DEPLOY_USER}@${DEPLOY_HOST}"
else
  info "deploy-rs disabled for this host"
fi
info "Unmount with: swapoff -a; umount -R /mnt ; then reboot and remove the ISO."
info "First boot: log in as max (password you set). Push when ready: cd ~/nixos && git push."
