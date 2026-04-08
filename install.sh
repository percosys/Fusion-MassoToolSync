#!/bin/bash
# MASSO Tool Sync — Fusion 360 Add-in Installer (macOS/Linux)

set -e

ADDIN_NAME="MassoToolSync"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/$ADDIN_NAME"

# Fusion 360 AddIns directory (macOS)
ADDINS_DIR="$HOME/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: $ADDIN_NAME folder not found in $(pwd)"
    echo "Make sure you run this script from the repository root."
    exit 1
fi

if [ ! -d "$ADDINS_DIR" ]; then
    echo "Error: Fusion 360 AddIns directory not found at:"
    echo "  $ADDINS_DIR"
    echo ""
    echo "Make sure Fusion 360 is installed."
    exit 1
fi

DEST="$ADDINS_DIR/$ADDIN_NAME"

if [ -d "$DEST" ]; then
    echo "MASSO Tool Sync is already installed."
    read -p "Overwrite? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        exit 0
    fi
    rm -rf "$DEST"
fi

cp -R "$SOURCE_DIR" "$DEST"

# Read version from config.py
VERSION=$(grep 'VERSION' "$DEST/config.py" | head -1 | sed 's/.*"\(.*\)".*/\1/')

echo ""
echo "MASSO Tool Sync v${VERSION} installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Restart Fusion 360 (or go to Scripts & Add-Ins > Add-Ins tab)"
echo "  2. Find 'MassoToolSync' and click Run"
echo "  3. The MASSO Tool Sync button will appear in Manufacture > Milling toolbar"
echo ""
