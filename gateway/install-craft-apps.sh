#!/usr/bin/env bash
# install-craft-apps.sh - installiert die ArtCraft-/Craft-CLIs in das Image.
#
# Die Apps sind freie, in Rust geschriebene Clean-Room-Implementierungen
# (github.com/storytold). Jede App bringt ein eigenes CLI mit, das den
# MCP-Server ueber stdio anbietet.
#
# Welche Apps installiert werden, steuert die Build-Arg-Variable
# CRAFT_APPS (kommaseparierte Liste). "all" installiert die ganze Suite.
#
# Jedes Release liefert ein SHA256SUMS.txt mit; die Pruefsumme des
# heruntergeladenen Archivs wird dagegen geprueft. Ohne den Abgleich wird
# nichts installiert.

set -euo pipefail

APPS_DIR="${APPS_DIR:-/opt/craft}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# app:version:confined
#   confined = "yes" -> das CLI kennt --automation-read-root/--automation-write-root
ALL_APPS="
wordcraft:0.9.0:yes
deckcraft:0.9.0:yes
gridcraft:0.9.0:no
photocraft:0.11.1:yes
pdfcraft:0.10.1:yes
vectorcraft:0.14.0:yes
lightcraft:0.10.0:no
filmcraft:0.10.0:no
designcraft:0.10.0:yes
effectcraft:0.13.0:yes
cadcraft:0.10.0:no
soundcraft:0.10.0:yes
figcraft:0.8.0:yes
"

# Architektur auf das Release-Naming der Suite abbilden.
case "$(uname -m)" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="aarch64" ;;
  arm64)   ARCH="aarch64" ;;
  riscv64) ARCH="riscv64" ;;
  *) echo "FEHLER: nicht unterstuetzte Architektur: $(uname -m)" >&2; exit 1 ;;
esac

download() {
  # download <url> <ziel>
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
}

verify_sha256() {
  # verify_sha256 <datei> <sums-datei> <dateiname>
  local file="$1" sums="$2" name="$3" expected actual
  expected="$(grep -E "  ${name}\$" "$sums" | awk '{print $1}' | head -1)"
  if [[ -z "$expected" ]]; then
    echo "FEHLER: kein SHA256-Eintrag fuer $name" >&2
    return 1
  fi
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    echo "FEHLER: SHA256-Abweichung fuer $name" >&2
    echo "  erwartet: $expected" >&2
    echo "  erhalten: $actual" >&2
    return 1
  fi
  echo "  sha256 ok: $name"
}

install_app() {
  # install_app <name> <version> <confined>
  local name="$1" version="$2" confined="$3"
  local repo="storytold/$name"
  local tarball="${name}-${version}-linux-${ARCH}.tar.gz"
  local base="https://github.com/${repo}/releases/download/v${version}"

  echo "==> $name $version"

  download "${base}/SHA256SUMS.txt" "${WORK_DIR}/${name}.sums"
  download "${base}/${tarball}" "${WORK_DIR}/${tarball}"
  verify_sha256 "${WORK_DIR}/${tarball}" "${WORK_DIR}/${name}.sums" "$tarball"

  tar xzf "${WORK_DIR}/${tarball}" -C "${WORK_DIR}"

  local src="${WORK_DIR}/${name}-${version}-linux-${ARCH}"
  if [[ ! -d "$src" ]]; then
    echo "FEHLER: unerwartetes Archiv-Layout fuer $name" >&2
    exit 1
  fi

  mkdir -p "${APPS_DIR}/${name}"
  # Nur das CLI wird installiert. Die Desktop-App braucht ein GUI und wuerde
  # den Container nur aufblaehen; der MCP-Server laeuft headless.
  install -m 0755 "${src}/bin/${name}-cli" "${APPS_DIR}/${name}/${name}-cli"

  # Die Lizenzdateien des Releases mitnehmen. Die Apps stehen unter
  # Apache-2.0/MIT; wer das Image weiterverteilt, muss die Bedingungen
  # einhalten (Apache-2.0 verlangt eine Kopie der Lizenz).
  local license_dir
  license_dir="$(find "${src}/share/doc" -maxdepth 2 -type d -name "$name" 2>/dev/null | head -1)"
  if [[ -n "$license_dir" ]]; then
    mkdir -p "${APPS_DIR}/${name}/licenses"
    find "$license_dir" -maxdepth 1 -type f \
      \( -name 'LICENSE-*' -o -name 'OFL-*.txt' \) \
      -exec cp {} "${APPS_DIR}/${name}/licenses/" \;
  fi

  # Der Rest des Archivs (Desktop-App, Icons, Metainfo) wird nicht gebraucht
  # und nicht mit ins Image kopiert. Das spart several hundert MB.
  rm -rf "${src}/bin/${name}" "${src}/share" "${src}/lib" 2>/dev/null || true

  # Die Confined-Marker braucht das Gateway im Container, nicht der Installer.
  # Sie stehen deshalb in einer Manifest-Datei, die der Gateway liest.
  echo "${name}:${version}:${confined}" >> "${APPS_DIR}/manifest.txt"

  echo "    installiert: ${APPS_DIR}/${name}/${name}-cli"
}

requested="${CRAFT_APPS:-all}"

if [[ "$requested" == "all" ]]; then
  selection="$ALL_APPS"
else
  selection=""
  for want in ${requested//,/ }; do
    found=""
    for entry in $ALL_APPS; do
      if [[ "$(echo "$entry" | cut -d: -f1)" == "$want" ]]; then
        found="$entry"
        break
      fi
    done
    if [[ -z "$found" ]]; then
      echo "FEHLER: unbekannte App '$want'" >&2
      echo "bekannt: $(echo "$ALL_APPS" | cut -d: -f1 | tr '\n' ' ')" >&2
      exit 1
    fi
    selection="$selection$found"$'\n'
  done
fi

mkdir -p "$APPS_DIR"
: > "${APPS_DIR}/manifest.txt"

count=0
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  install_app "$(echo "$entry" | cut -d: -f1)" "$(echo "$entry" | cut -d: -f2)" "$(echo "$entry" | cut -d: -f3)"
  count=$((count + 1))
done <<< "$selection"

echo "==> $count App(s) installiert"
