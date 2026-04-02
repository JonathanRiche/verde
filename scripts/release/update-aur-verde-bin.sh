#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <tag-or-version> <aur-repo-dir>" >&2
  exit 1
fi

INPUT_VERSION="$1"
AUR_REPO_DIR="$2"

VERSION="${INPUT_VERSION#v}"
TAG="v${VERSION}"
RELEASE_BASE_URL="https://github.com/JonathanRiche/verde/releases/download/${TAG}"
RAW_BASE_URL="https://raw.githubusercontent.com/JonathanRiche/verde/${TAG}"
LINUX_ASSET="verde-${TAG}-linux-x86_64.tar.gz"

if [[ ! -f "${AUR_REPO_DIR}/PKGBUILD" || ! -f "${AUR_REPO_DIR}/.SRCINFO" ]]; then
  echo "aur repo dir must contain PKGBUILD and .SRCINFO: ${AUR_REPO_DIR}" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SHA_FILE="${WORK_DIR}/SHA256SUMS.txt"
LICENSE_FILE="${WORK_DIR}/LICENSE"

curl -fL --retry 5 --retry-delay 2 \
  -o "${SHA_FILE}" \
  "${RELEASE_BASE_URL}/SHA256SUMS.txt"
curl -fL --retry 5 --retry-delay 2 \
  -o "${LICENSE_FILE}" \
  "${RAW_BASE_URL}/LICENSE"

LINUX_SHA="$(awk -v asset="${LINUX_ASSET}" '$2 == asset { print $1 }' "${SHA_FILE}")"
LICENSE_SHA="$(sha256sum "${LICENSE_FILE}" | awk '{ print $1 }')"

if [[ -z "${LINUX_SHA}" || -z "${LICENSE_SHA}" ]]; then
  echo "failed to resolve release checksums for ${TAG}" >&2
  exit 1
fi

PKGBUILD="${AUR_REPO_DIR}/PKGBUILD"
SRCINFO="${AUR_REPO_DIR}/.SRCINFO"

sed -i -E "s/^pkgver=.*/pkgver=${VERSION}/" "${PKGBUILD}"
sed -i -E "/^sha256sums=\(/,/^\)/c\\sha256sums=(\\n  '${LINUX_SHA}'\\n  '${LICENSE_SHA}'\\n)" "${PKGBUILD}"

awk \
  -v version="${VERSION}" \
  -v linux_sha="${LINUX_SHA}" \
  -v license_sha="${LICENSE_SHA}" \
  '
  BEGIN {
    sha_index = 0
  }
  {
    if ($1 == "pkgver" && $2 == "=") {
      print "\tpkgver = " version
      next
    }
    if ($1 == "source" && $2 == "=" && index($0, "linux-x86_64.tar.gz")) {
      print "\tsource = verde-bin-" version ".tar.gz::https://github.com/JonathanRiche/verde/releases/download/v" version "/verde-v" version "-linux-x86_64.tar.gz"
      next
    }
    if ($1 == "source" && $2 == "=" && index($0, "raw.githubusercontent.com/JonathanRiche/verde")) {
      print "\tsource = LICENSE::https://raw.githubusercontent.com/JonathanRiche/verde/v" version "/LICENSE"
      next
    }
    if ($1 == "sha256sums" && $2 == "=") {
      if (sha_index == 0) {
        print "\tsha256sums = " linux_sha
        sha_index += 1
        next
      }
      if (sha_index == 1) {
        print "\tsha256sums = " license_sha
        sha_index += 1
        next
      }
    }
    print
  }
  ' "${SRCINFO}" > "${SRCINFO}.tmp"
mv "${SRCINFO}.tmp" "${SRCINFO}"

echo "Updated verde-bin metadata to ${TAG}"
echo "linux sha256: ${LINUX_SHA}"
echo "license sha256: ${LICENSE_SHA}"
