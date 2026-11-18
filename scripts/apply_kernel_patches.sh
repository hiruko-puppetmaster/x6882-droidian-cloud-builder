#!/usr/bin/env bash
#
# Apply the small source fixes needed by the XTENSEI kernel tree.
#
#   scripts/apply_kernel_patches.sh <kernel-tree>
#
# Patches live in ../patches/*.patch and are applied with git apply.  Every
# patch is checked first, so a kernel update that invalidates the context
# fails the build instead of silently building an unpatched kernel.  Running
# the script twice is safe: an already-applied patch is detected with a
# reverse check.
set -euo pipefail

KERNEL_DIR="${1:?usage: apply_kernel_patches.sh <kernel-tree>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/../patches"

fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "${KERNEL_DIR}" ] || fail "kernel tree not found: ${KERNEL_DIR}"
command -v git >/dev/null || fail "git is required"

shopt -s nullglob
patches=("${PATCH_DIR}"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
    printf 'No kernel patches in %s\n' "${PATCH_DIR}"
    exit 0
fi

for patch_file in "${patches[@]}"; do
    name="$(basename "${patch_file}")"

    # git apply works inside and outside a repository and, unlike GNU patch,
    # does not silently ignore -R when it thinks the patch is unreversed.
    if git -C "${KERNEL_DIR}" apply --reverse --check "${patch_file}" \
            >/dev/null 2>&1; then
        printf 'already applied: %s\n' "${name}"
        continue
    fi

    if ! git -C "${KERNEL_DIR}" apply --check "${patch_file}" \
            >/dev/null 2>&1; then
        printf 'ERROR: %s does not apply to %s\n' "${name}" "${KERNEL_DIR}" >&2
        git -C "${KERNEL_DIR}" apply --check "${patch_file}" >&2 || true
        exit 1
    fi

    git -C "${KERNEL_DIR}" apply "${patch_file}"
    printf 'applied: %s\n' "${name}"
done
