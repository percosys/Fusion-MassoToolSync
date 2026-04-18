# MASSO Tool Sync

**Sync your CAD tool libraries directly to a MASSO G3 CNC controller's USB drive.**

Two separate integrations live in this repo, sharing the same `.htg` binary format, merge logic, and backup behaviour:

| Platform | Folder | Language | Status |
|---|---|---|---|
| **Fusion 360 add-in** | [`MassoToolSync/`](MassoToolSync/) | Python | macOS + Windows |
| **VCarve Pro gadget** | [`MassoToolSync_VCarve/`](MassoToolSync_VCarve/) | Lua | Windows only (VCarve is Windows-only) |

Both integrations produce the same `.htg` binary file that the MASSO G3 controller reads, so you can pick whichever CAD tool matches your workflow — or use both.

|  Fusion 360 add-in  |  VCarve Pro gadget  |
| :---: | :---: |
| ![Fusion 360 dialog](screenshots/dialog.png) | ![VCarve Pro dialog](screenshots/vcarve-dialog.png) |

## Shared Features

- **One-click sync** to MASSO G3 `.htg` tool-table files
- **Direct USB write** — the integration writes the tool table to the USB in place
- **Automatic backups** — zips the existing `Machine Settings/` folder before every write
- **Auto-detect firmware** — finds the correct `.htg` filename (v4.x or v5.x)
- **Smart merge** — preserves probed Z offsets, detects added/updated/replaced/unchanged tools, reports skipped ones
- **Auto tool numbering** — assigns sequential T1–T100 (MASSO's usable range; T0 + T101–T104 are reserved)
- **Unit conversion** — handles mm ↔ inches automatically
- **Z offset modes** — zero all, preserve existing, or use tool body length
- **Slot assignment** — match tool number, or leave unassigned

## Install — Fusion 360 (macOS + Windows)

**macOS:**
```bash
git clone https://github.com/percosys/masso-tool-sync.git
cd masso-tool-sync
./install.sh
```

**Windows:**
```cmd
git clone https://github.com/percosys/masso-tool-sync.git
cd masso-tool-sync
install.bat
```

The install script copies `MassoToolSync/` into your Fusion 360 AddIns directory and enables Run-on-Startup. Full docs: see the feature walkthrough below.

## Install — VCarve Pro (Windows)

```cmd
git clone https://github.com/percosys/masso-tool-sync.git
cd masso-tool-sync
install-vcarve.bat
```

The installer auto-detects your VCarve Pro / Aspire gadgets folder, downloads `sqlite3.exe` from sqlite.org, and copies the gadget into place. Full docs in [`MassoToolSync_VCarve/README.md`](MassoToolSync_VCarve/README.md).

Restart VCarve Pro, then open **Gadgets → MassoToolSync**.

## Before You Start — Back Up Your MASSO Controller

Both integrations require the `MASSO/Machine Settings/` folder on the USB. It's only created by the MASSO controller's "Save to file" function:

1. Insert a USB drive into the MASSO controller
2. On the MASSO touchscreen: **F1 Setup → Save & Load Calibration Settings → Save to file**
3. Keep that USB — the add-in / gadget will read from it, back it up, and write the new tool table to it

## Fusion 360 Usage

### 1. Open the Add-in

Navigate to **Manufacture → Milling**. You'll find the **MASSO Tool Sync** button in the **MASSO** panel on the toolbar. It's also in **Design → Add-Ins**.

### 2. Select a Tool Library

**Fusion Library** to pick from your local Fusion 360 tool libraries, or **File on Disk** to browse to a `.tools` or `.json` file.

### 3. Configure MASSO Settings

| Option | Description |
|--------|-------------|
| **MASSO Units** | Match your controller (mm / inches) |
| **Tool Numbering** | Auto-assign T1–T100, or use Fusion post-process numbers |
| **Z Offset Mode** | **Zero all**, **Preserve MASSO**, or **Use Fusion body length** |
| **Slot Assignment** | **Match tool number** or **Leave unassigned** |

### 4. Select MASSO USB Drive

Browse to your MASSO USB drive. The add-in checks for `MASSO/Machine Settings/` and shows a status indicator (green / orange / red).

### 5. Review and Sync

The **Merge Preview** shows exactly what will happen — ADDED / UPDATED / REPLACED / UNCHANGED / SKIPPED. Click OK to back up, write, and optionally sync back to Fusion.

### 6. Load on MASSO Controller

1. Plug USB into your MASSO controller
2. **F1 Setup → Save & Load Calibration Settings → Load from file**
3. Reboot the controller
4. Probe Z on any new or changed tools

## VCarve Pro Usage

See [`MassoToolSync_VCarve/README.md`](MassoToolSync_VCarve/README.md) for the full VCarve-specific walkthrough, including how the Tool Group picker and sqlite3-backed tool database integration work.

## Troubleshooting

**Fusion add-in doesn't appear in toolbar:**
- Make sure you're in the **Manufacture** workspace, **Milling** tab
- Go to Scripts & Add-Ins (Shift+S), find **MassoToolSync**, click Run
- Check **Run on Startup** for automatic loading

**VCarve gadget doesn't appear in menu:**
- Make sure you have VCarve Pro (gadgets aren't supported in the desktop/non-Pro edition)
- Restart VCarve Pro after installing (gadgets menu is built at startup)

**"MASSO/Machine Settings/ not found" error:**
- Select the USB drive root, not a subfolder
- The USB must contain a `MASSO/Machine Settings/` folder (created by the MASSO controller's "Save to file")

**Tools show as blank on MASSO controller:**
- Load the file: **F1 Setup → Save & Load Calibration Settings → Load from file**
- Reboot the controller after loading

## Project Structure

```
masso-tool-sync/
  MassoToolSync/              # Fusion 360 add-in (Python)
    MassoToolSync.py          # Entry point
    MassoToolSync.manifest    # Fusion add-in manifest
    config.py                 # Constants + VERSION
    command.py                # Dialog UI and handlers
    lib_browser.py            # Fusion CAM library enumeration
    fusion2masso/             # Core library (pure Python stdlib)
      masso.py                # .htg binary reader/writer
      fusion.py               # Fusion .tools/.json parser
      mapping.py              # Merge logic
      fusion_sync.py          # Push libraries back to Fusion

  MassoToolSync_VCarve/       # VCarve Pro gadget (Lua)
    MassoToolSync.lua         # Entry point and orchestration
    MassoToolSync.htm         # HTML dialog
    config.luax               # Constants
    crc32.luax                # Pure-Lua CRC32
    masso_htg.luax            # .htg binary reader/writer
    merge.luax                # Merge logic
    vcarve_db.luax            # VCarve SQLite DB reader
    resources/                # Bundled sqlite3.exe goes here

  install.sh / install.bat    # Fusion installers
  install-vcarve.bat          # VCarve installer (launches install.ps1)
  install.ps1                 # VCarve installer (downloads sqlite3, primes cache)
  dev/                        # Standalone CLI + test suite
```

## MASSO .htg Binary Format

The `.htg` file is 6,720 bytes = 105 records of 64 bytes each. Record 0 is reserved (dry-run entry); T1–T100 are usable; T101–T104 are reserved for multi-spindle heads.

| Offset | Length | Type | Field |
|--------|--------|------|-------|
| 0 | 40 | ASCII | Tool name (null-terminated) |
| 40 | 4 | float32 LE | Z offset |
| 44 | 8 | zeros | Reserved |
| 52 | 4 | float32 LE | Diameter |
| 56 | 2 | uint16 **BE** | Slot (0x00FF = empty) |
| 58 | 2 | zeros | Reserved |
| 60 | 4 | uint32 LE | CRC32 of bytes 0–59 |

## Development

The Fusion core library lives in `MassoToolSync/fusion2masso/` and is pure Python stdlib. A standalone test suite lives under `dev/`:

```bash
pip install pytest
python -m pytest dev/tests/ -v
```

The VCarve gadget is pure Lua + HTML and uses only the Lua standard library plus VCarve's HTML_Dialog API.

## Acknowledgments

The MASSO `.htg` binary format was reverse-engineered with help from the [MASSO community forum](https://forums.masso.com.au/threads/convert-cam-tool-libraries-into-masso-tool-file.4563/).

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
