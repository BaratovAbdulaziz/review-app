#!/bin/sh
#
# Installs the piper text-to-speech engine and one English voice into
# ~/.local/share/review_app/tts/piper, which is where the review_app
# commentator looks for them. No sudo, no pip, no system packages.
#
# Usage: tool/install_tts.sh [--force] [-h]

set -eu

PIPER_TTS_DIR="${PIPER_TTS_DIR:-$HOME/.local/share/review_app/tts}"
PIPER_DIR="$PIPER_TTS_DIR/piper"
VOICE="en_US-lessac-medium"
VOICE_RELPATH="en/en_US/lessac/medium"
VOICE_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main"
RELEASE_API="https://api.github.com/repos/rhasspy/piper/releases/latest"
RELEASE_LATEST="https://github.com/rhasspy/piper/releases/latest/download"
FORCE=0

die() {
    printf 'install_tts.sh: %s\n' "$1" >&2
    exit 1
}

# Progress goes to stderr so that stdout stays clean for command substitution.
info() { printf '==> %s\n' "$1" >&2; }

usage() {
    cat <<'EOF'
Usage: tool/install_tts.sh [--force]

Installs piper plus the en_US-lessac-medium voice into
  ~/.local/share/review_app/tts/piper
without sudo.

  --force   re-download and re-extract even if the files already exist
  -h        show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
    shift
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

case "$(uname -m)" in
    x86_64 | amd64) ASSET="piper_linux_x86_64.tar.gz" ;;
    aarch64 | arm64) ASSET="piper_linux_aarch64.tar.gz" ;;
    *) die "no piper release for $(uname -m); install espeak-ng instead" ;;
esac

# True when a URL resolves to a 200, following the CDN redirects that both
# GitHub releases and HuggingFace use.
url_ok() {
    [ "$(curl -sIL -o /dev/null -w '%{http_code}' --retry 2 \
        --connect-timeout 20 "$1" 2>/dev/null || echo 000)" = "200" ]
}

# Prefers the stable "latest release" redirect, and falls back to the GitHub
# API when that 404s, which happens if the tag name changes format.
resolve_release_url() {
    if url_ok "$RELEASE_LATEST/$ASSET"; then
        printf '%s\n' "$RELEASE_LATEST/$ASSET"
        return 0
    fi
    info "$ASSET not found at the latest tag, asking the GitHub API"
    found="$(
        curl -fsSL --retry 2 --connect-timeout 20 "$RELEASE_API" |
            awk -v want="$ASSET" '
                /"name":/ {
                    line = $0
                    sub(/.*"name": *"/, "", line)
                    sub(/".*/, "", line)
                    name = line
                }
                /"browser_download_url":/ && name == want && !found {
                    url = $0
                    sub(/.*"browser_download_url": *"/, "", url)
                    sub(/".*/, "", url)
                    found = url
                }
                END { if (found != "") print found }
            '
    )"
    [ -n "$found" ] || die "the GitHub API does not list $ASSET"
    printf '%s\n' "$found"
}

# Downloads to a .part file first so an interrupted run cannot leave a truncated
# binary or a 63 MB half voice behind.
fetch() {
    url="$1"
    out="$2"
    label="$3"

    if [ "$FORCE" -eq 0 ] && [ -s "$out" ]; then
        info "already have $label, skipping"
        return 0
    fi
    url_ok "$url" ||
        die "$label is not downloadable (404 or offline): $url"

    info "downloading $label"
    rm -f "$out.part"
    if ! curl -fSL --progress-bar --retry 3 --retry-delay 2 \
        --connect-timeout 20 -o "$out.part" "$url"; then
        rm -f "$out.part"
        die "download failed for $label: $url"
    fi
    if [ ! -s "$out.part" ]; then
        rm -f "$out.part"
        die "download produced an empty file for $label: $url"
    fi
    mv "$out.part" "$out"
}

mkdir -p "$PIPER_TTS_DIR"

BINARY="$PIPER_DIR/piper"
if [ "$FORCE" -ne 0 ] || [ ! -x "$BINARY" ]; then
    release_url="$(resolve_release_url)"
    archive="$PIPER_TTS_DIR/$ASSET"
    fetch "$release_url" "$archive" "$ASSET"
    info "extracting piper"
    # The archive unpacks as piper/, which is exactly the directory the app
    # expects. Everything is extracted, not just the binary: piper dlopens
    # libonnxruntime, libpiper_phonemize and espeak-ng-data from next to itself.
    rm -rf "$PIPER_DIR"
    tar -xzf "$archive" -C "$PIPER_TTS_DIR" ||
        die "could not extract $archive"
    rm -f "$archive"
    [ -f "$BINARY" ] || die "the archive did not contain piper/piper"
    chmod +x "$BINARY" "$PIPER_DIR/espeak-ng" 2>/dev/null || true
else
    info "already have $BINARY, skipping"
fi

MODEL="$PIPER_DIR/$VOICE.onnx"
fetch "$VOICE_BASE/$VOICE_RELPATH/$VOICE.onnx" "$MODEL" "$VOICE.onnx"
fetch "$VOICE_BASE/$VOICE_RELPATH/$VOICE.onnx.json" "$MODEL.json" \
    "$VOICE.onnx.json"

# A piper that cannot start would otherwise only show up as a silent failure in
# the app, so check it here where the error can be read.
"$BINARY" --help >/dev/null 2>&1 ||
    die "piper could not start; the shared libraries may be incomplete"

printf '\npiper is installed.\n'
printf '  binary:      %s\n' "$BINARY"
printf '  voice model: %s\n' "$MODEL"
printf '  voice config: %s\n' "$MODEL.json"
printf '  audio player: paplay (falling back to pw-play, then aplay)\n'

if [ "$MODEL" = "$HOME/.local/share/review_app/tts/piper/$VOICE.onnx" ]; then
    printf '\nThe app finds this model automatically; no environment variable needed.\n'
else
    printf '\nThis model is not in the default location, so export:\n'
    printf '  export PIPER_TTS_MODEL=%s\n' "$MODEL"
fi

printf '\nA fallback espeak-ng also ships in %s, but needs its own library path:\n' "$PIPER_DIR"
printf '  export LD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s/espeak-ng-data\n' \
    "$PIPER_DIR" "$PIPER_DIR"
