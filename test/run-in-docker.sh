#!/bin/sh
# Convenience wrapper: run the real netns leak test inside a throwaway,
# privileged Linux container. Works from macOS/Windows where netns/iptables
# are not available on the host. It only touches the container's namespaces;
# your host network and your phone are never affected.
#
#   Usage (from repo root):  sh test/run-in-docker.sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
IMAGE=${IMAGE:-alpine:3.20}

command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 127; }

exec docker run --rm --privileged -v "$REPO":/work -w /work "$IMAGE" \
    sh -c 'apk add -q iproute2 iptables ip6tables iputils 2>/dev/null; sh test/leak-netns.sh'
