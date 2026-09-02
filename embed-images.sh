#!/bin/bash
set -euo pipefail

AUTH_FILE="${1:-/tmp/pull-secret.json}"
RELEASE_FILE="${2:-}"
BATCH="${3:-}"
CACHE_DIR="${IMAGE_STORAGE_DIR:-/usr/lib/containers/storage}"
ARCH=$(uname -m)

mkdir -p "${CACHE_DIR}"
touch "${CACHE_DIR}/image-list.txt"

if [[ -n "${RELEASE_FILE}" ]]; then
    FILES=("${RELEASE_FILE}")
else
    mapfile -t FILES < <(find /usr/share/microshift/release -name "release-*${ARCH}*.json")
fi

mapfile -t IMAGES < <(
    printf '%s\n' "${FILES[@]}" | xargs -I{} jq -r '.images | values[]' {} | sort -u
)

# Apply batch slicing if requested (format: N/M = batch N of M)
if [[ -n "${BATCH}" ]]; then
    BATCH_NUM=${BATCH%%/*}
    BATCH_TOTAL=${BATCH##*/}
    TOTAL=${#IMAGES[@]}
    BATCH_SIZE=$(( (TOTAL + BATCH_TOTAL - 1) / BATCH_TOTAL ))
    START=$(( (BATCH_NUM - 1) * BATCH_SIZE ))
    IMAGES=("${IMAGES[@]:${START}:${BATCH_SIZE}}")
    echo "==> Batch ${BATCH_NUM}/${BATCH_TOTAL}: images ${START}..$(( START + ${#IMAGES[@]} - 1 )) of ${TOTAL}"
fi

# Skip images already cached
NEW_IMAGES=()
for img in "${IMAGES[@]}"; do
    sha=$(echo "${img}" | sha256sum | awk '{ print $1 }')
    if [[ -d "${CACHE_DIR}/${sha}" ]]; then
        echo "  Already cached: ${img}"
    else
        NEW_IMAGES+=("${img}")
    fi
done

echo "==> Embedding ${#NEW_IMAGES[@]} images (${#IMAGES[@]} in scope, $((${#IMAGES[@]} - ${#NEW_IMAGES[@]})) already cached)"

FAILED=0
for img in "${NEW_IMAGES[@]}"; do
    sha=$(echo "${img}" | sha256sum | awk '{ print $1 }')
    echo "  Caching: ${img}"
    if skopeo copy --retry-times 3 --preserve-digests \
        --authfile="${AUTH_FILE}" \
        "docker://${img}" \
        "dir:${CACHE_DIR}/${sha}" 2>&1; then
        echo "${img},${sha}" >> "${CACHE_DIR}/image-list.txt"
    else
        echo "  WARNING: Failed to cache ${img}"
        FAILED=$((FAILED + 1))
    fi
done

TOTAL=$(wc -l < "${CACHE_DIR}/image-list.txt")
echo "==> Cached ${TOTAL} images total (${FAILED} failed this batch)"

if [[ ${FAILED} -gt 0 ]]; then
    echo "==> WARNING: ${FAILED} images failed (logged above). These will not be available offline."
fi
