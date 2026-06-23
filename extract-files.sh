#!/bin/bash
#
# Copyright (C) 2023 Paranoid Android
#
# SPDX-License-Identifier: Apache-2.0
#

set -e

### Setup
MY_DIR="${BASH_SOURCE%/*}"
SRC_ROOT="${MY_DIR}/../../.."
TMP_DIR=$(mktemp -d)
EXTRACT_KERNEL=true
declare -a MODULE_FOLDERS=("vendor_ramdisk" "vendor_dlkm" "system_dlkm")

cleanup() {
    rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

### Parse arguments
FIRMWARE_ZIP=""

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n|--no-kernel)
            EXTRACT_KERNEL=false
            ;;
        *.zip)
            FIRMWARE_ZIP="${1}"
            ;;
        *)
            echo "Unknown argument: ${1}"
            echo "Usage: $0 [-n|--no-kernel] firmware.zip"
            exit 1
            ;;
    esac
    shift
done

### Validate input
if [ -z "${FIRMWARE_ZIP}" ]; then
    echo "Usage: $0 [-n|--no-kernel] firmware.zip"
    exit 1
fi

if [ ! -f "${FIRMWARE_ZIP}" ]; then
    echo "Unable to find firmware ZIP: ${FIRMWARE_ZIP}"
    exit 1
fi

touch "${MY_DIR}/Module.symvers"
touch "${MY_DIR}/System.map"

### Check dependencies
for BIN in 7z curl python3 lz4 cpio; do
    if ! command -v "${BIN}" >/dev/null 2>&1; then
        echo "Missing dependency: ${BIN}"
        exit 1
    fi
done

### Find or install payload dumper
PAYLOAD_DUMPER=""

if command -v payload-dumper-go >/dev/null 2>&1; then
    PAYLOAD_DUMPER="payload-dumper-go"

elif [ -x "$HOME/go/bin/payload-dumper-go" ]; then
    PAYLOAD_DUMPER="$HOME/go/bin/payload-dumper-go"

else
    echo "payload-dumper-go not found."

    if command -v go >/dev/null 2>&1; then
        echo "Installing payload-dumper-go..."

        export PATH="$HOME/go/bin:$PATH"

        if ! go install github.com/ssut/payload-dumper-go@latest; then
            echo "Failed to install payload-dumper-go via Go."
        fi

        if command -v payload-dumper-go >/dev/null 2>&1; then
            PAYLOAD_DUMPER="payload-dumper-go"
        elif [ -x "$HOME/go/bin/payload-dumper-go" ]; then
            PAYLOAD_DUMPER="$HOME/go/bin/payload-dumper-go"
        fi
    fi
fi

# Fall back to Python implementation
if [ -z "${PAYLOAD_DUMPER}" ]; then
    echo "Falling back to Python payload_dumper..."

    export PATH="$HOME/.local/bin:$PATH"
    export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

    if ! command -v payload_dumper >/dev/null 2>&1; then
        echo "Installing Python payload_dumper..."

        python3 -m pip install --user \
            "protobuf<=3.20.3" \
            payload-dumper
    fi

    if command -v payload_dumper >/dev/null 2>&1; then
        PAYLOAD_DUMPER="payload_dumper"
    else
        echo "Failed to install any payload dumper!"
        exit 1
    fi
fi

echo "Using ${PAYLOAD_DUMPER}"

### Extract firmware ZIP
echo "Extracting firmware ZIP..."
7z x "${FIRMWARE_ZIP}" -o"${TMP_DIR}/firmware" >/dev/null

PAYLOAD_BIN=$(find "${TMP_DIR}/firmware" -type f -name "payload.bin" | head -n1)

if [ -z "${PAYLOAD_BIN}" ]; then
    echo "payload.bin not found!"
    exit 1
fi

echo "Extracting payload.bin..."

if [[ "${PAYLOAD_DUMPER}" == *payload-dumper-go ]]; then
    "${PAYLOAD_DUMPER}" \
        -o "${TMP_DIR}/dump" \
        "${PAYLOAD_BIN}" >/dev/null
else
    export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

    "${PAYLOAD_DUMPER}" \
        "${PAYLOAD_BIN}" \
        --out "${TMP_DIR}/dump" >/dev/null
fi

DUMP="${TMP_DIR}/dump"

### Kernel
if ${EXTRACT_KERNEL}; then
    if [ -f "${DUMP}/boot.img" ]; then
        echo "Extracting boot image..."

        "${SRC_ROOT}/system/tools/mkbootimg/unpack_bootimg.py" \
            --boot_img "${DUMP}/boot.img" \
            --out "${TMP_DIR}/boot.out" >/dev/null

        cp -f "${TMP_DIR}/boot.out/kernel" "${MY_DIR}/kernel"
        echo "  - kernel"
    fi
fi

### DTBs
rm -rf "${MY_DIR}/dtbs"
mkdir -p "${MY_DIR}/dtbs"

if [ -f "${DUMP}/vendor_boot.img" ]; then
    echo "Extracting vendor_boot image..."

    "${SRC_ROOT}/system/tools/mkbootimg/unpack_bootimg.py" \
        --boot_img "${DUMP}/vendor_boot.img" \
        --out "${TMP_DIR}/vendor_boot.out" >/dev/null

    curl -sSL \
        "https://raw.githubusercontent.com/PabloCastellano/extract-dtb/master/extract_dtb/extract_dtb.py" \
        -o "${TMP_DIR}/extract_dtb.py"

    python3 "${TMP_DIR}/extract_dtb.py" \
        "${TMP_DIR}/vendor_boot.out/dtb" \
        -o "${TMP_DIR}/dtbs" >/dev/null

    find "${TMP_DIR}/dtbs" -type f -name "*.dtb" | while read -r dtb; do
        cp "${dtb}" "${MY_DIR}/dtbs/"
        echo "  - dtbs/$(basename "${dtb}")"
    done
fi

### DTBO
if [ -f "${DUMP}/dtbo.img" ]; then
    cp -f "${DUMP}/dtbo.img" "${MY_DIR}/dtbs/dtbo.img"
    cp -f "${DUMP}/dtbo.img" "${MY_DIR}/dtbo.img"
    echo "  - dtbs/dtbo.img"
fi

### Modules
for MODULE_FOLDER in "${MODULE_FOLDERS[@]}"; do
    rm -rf "${MY_DIR}/${MODULE_FOLDER}"
    mkdir -p "${MY_DIR}/${MODULE_FOLDER}"
done

for MODULE_FOLDER in "${MODULE_FOLDERS[@]}"; do
    MODULE_SRC="${DUMP}/${MODULE_FOLDER}"

    if [ "${MODULE_FOLDER}" = "vendor_ramdisk" ]; then
        if [ -f "${TMP_DIR}/vendor_boot.out/vendor_ramdisk00" ]; then
            echo "Extracting vendor_ramdisk..."

            lz4 -qd \
                "${TMP_DIR}/vendor_boot.out/vendor_ramdisk00" \
                "${TMP_DIR}/vendor_ramdisk.cpio"

            mkdir -p "${TMP_DIR}/vendor_ramdisk"

            (
                cd "${TMP_DIR}/vendor_ramdisk"
                cpio -idmv < "${TMP_DIR}/vendor_ramdisk.cpio" \
                    >/dev/null 2>&1
            )

            MODULE_SRC="${TMP_DIR}/vendor_ramdisk"
        else
            continue
        fi
    fi

    [ -d "${MODULE_SRC}/lib/modules" ] || continue

    find "${MODULE_SRC}/lib/modules" -type f | while read -r module; do
        cp "${module}" "${MY_DIR}/${MODULE_FOLDER}/"
        echo "  - ${MODULE_FOLDER}/$(basename "${module}")"
    done
done

echo
echo "Done!"
