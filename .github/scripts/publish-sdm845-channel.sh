#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <build-dir> <output-id>\n' "${0##*/}" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'missing required environment variable: %s\n' "${name}" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

upload_file() {
  local file="$1"
  local remote_path="$2"
  local checksum

  checksum="$(sha256sum "${file}" | cut -d ' ' -f1 | tr '[:lower:]' '[:upper:]')"
  curl --fail --show-error --silent --retry 5 --retry-all-errors \
    --request PUT \
    --upload-file "${file}" \
    --header "AccessKey: ${BUNNY_STORAGE_ACCESS_KEY}" \
    --header "Checksum: ${checksum}" \
    "${storage_base}/${remote_path}"
}

verify_cors() {
  local url="$1"
  local headers

  headers="$(mktemp)"
  curl --fail --show-error --silent --head --location --retry 5 --retry-all-errors \
    --header 'Origin: https://www.fastboop.win' \
    --dump-header "${headers}" \
    --output /dev/null \
    "${url}"

  if ! grep -Eiq '^access-control-allow-origin:[[:space:]]*(\*|https://www\.fastboop\.win)' "${headers}"; then
    printf 'missing expected CORS response header for %s\n' "${url}" >&2
    printf 'response headers were:\n' >&2
    sed 's/^/  /' "${headers}" >&2
    exit 1
  fi
}

verify_range() {
  local url="$1"
  local headers
  local status

  headers="$(mktemp)"
  status="$(curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
    --range 0-0 \
    --header 'Origin: https://www.fastboop.win' \
    --dump-header "${headers}" \
    --max-filesize 1024 \
    --write-out '%{http_code}' \
    --output /dev/null \
    "${url}")"

  if [[ "${status}" != 206 ]]; then
    printf 'expected HTTP 206 for ranged rootfs request to %s, got %s\n' "${url}" "${status}" >&2
    printf 'response headers were:\n' >&2
    sed 's/^/  /' "${headers}" >&2
    exit 1
  fi

  if ! grep -Eiq '^access-control-allow-origin:[[:space:]]*(\*|https://www\.fastboop\.win)' "${headers}"; then
    printf 'missing expected CORS response header for ranged request to %s\n' "${url}" >&2
    printf 'response headers were:\n' >&2
    sed 's/^/  /' "${headers}" >&2
    exit 1
  fi
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

build_dir="$1"
output_id="$2"

require_env BUNNY_STORAGE_ACCESS_KEY
require_env BUNNY_STORAGE_ZONE
require_env BUNNY_STORAGE_HOST
require_env BUNNY_CDN_BASE_URL

for cmd in basename curl cut fastboop grep mktemp sed sha256sum sha512sum stat tr; do
  require_cmd "${cmd}"
done

shopt -s nullglob
images=()
for candidate in "${build_dir}/${output_id}"_*.raw.xz; do
  candidate_name="$(basename -- "${candidate}")"
  if [[ "${candidate_name}" == "${output_id}_"*.raw.xz \
    && "${candidate_name}" != *.esp.raw.xz \
    && "${candidate_name}" != *.root-*.raw.xz ]]; then
    images+=("${candidate}")
  fi
done
if [[ ${#images[@]} -ne 1 ]]; then
  printf 'expected exactly one full disk image matching %s/%s_*.raw.xz, found %s\n' \
    "${build_dir}" "${output_id}" "${#images[@]}" >&2
  exit 1
fi

image_path="${images[0]}"
image_name="$(basename -- "${image_path}")"

storage_host="${BUNNY_STORAGE_HOST#http://}"
storage_host="${storage_host#https://}"
storage_host="${storage_host%%/*}"
storage_base="https://${storage_host}/${BUNNY_STORAGE_ZONE}"
cdn_base="${BUNNY_CDN_BASE_URL%/}"

rootfs_object_path="images/${image_name}"
rootfs_url="${cdn_base}/${rootfs_object_path}"
channel_url="${cdn_base}/channel"

size_bytes="$(stat -c '%s' "${image_path}")"
sha512_digest="$(sha512sum "${image_path}" | cut -d ' ' -f1)"

work_parent="${RUNNER_TEMP:-/tmp}"
work_dir="$(mktemp -d "${work_parent}/bengalos-fastboop-channel.XXXXXX")"
manifest="${work_dir}/bootprofile.yaml"
channel_unindexed="${work_dir}/channel.unindexed"
channel_indexed="${work_dir}/channel"

printf 'uploading rootfs artifact to %s\n' "${rootfs_url}"
upload_file "${image_path}" "${rootfs_object_path}"

cat >"${manifest}" <<EOF
id: bengalos-sdm845-development
display_name: BengalOS SDM845 development

stage0:
  kernel_modules:
    - simpledrm
    - qcom-rpmh-regulator
    - fixed

rootfs:
  ext4:
    gpt:
      index: 1
      xz:
        http: ${rootfs_url}
        cors_safelisted_mode: true
        content:
          digest: sha512:${sha512_digest}
          size_bytes: ${size_bytes}

kernel:
  path: /vmlinuz-6.18-sdm845
  fat:
    gpt:
      index: 0
      xz:
        http: ${rootfs_url}
        cors_safelisted_mode: true
        content:
          digest: sha512:${sha512_digest}
          size_bytes: ${size_bytes}

dtbs:
  path: /usr/lib/linux-image-6.18-sdm845
  ext4:
    gpt:
      index: 1
      xz:
        http: ${rootfs_url}
        cors_safelisted_mode: true
        content:
          digest: sha512:${sha512_digest}
          size_bytes: ${size_bytes}
EOF

fastboop bootprofile create "${manifest}" \
  --output "${channel_unindexed}" \
  --optimize \
  --local-artifact "${image_path}"

fastboop channel index "${channel_unindexed}" --output "${channel_indexed}"
fastboop show "${channel_indexed}" >/dev/null

printf 'uploading indexed fastboop channel to %s\n' "${channel_url}"
upload_file "${channel_indexed}" channel

if [[ -n "${BUNNY_API_KEY:-}" ]]; then
  curl --fail --show-error --silent --retry 5 --retry-all-errors \
    --request POST \
    --header "AccessKey: ${BUNNY_API_KEY}" \
    "https://api.bunny.net/purge?url=${channel_url}&async=true" >/dev/null
fi

if [[ "${BUNNY_SKIP_CDN_VERIFY:-0}" != 1 ]]; then
  verify_cors "${channel_url}"
  verify_cors "${rootfs_url}"
  verify_range "${rootfs_url}"
fi

printf 'published fastboop channel: %s\n' "${channel_url}"
