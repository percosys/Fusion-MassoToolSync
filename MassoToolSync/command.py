"""MASSO Tool Sync command — dialog UI and handlers."""

from __future__ import annotations

import json
import os
import traceback
import zipfile
from datetime import datetime

import adsk.core

import config
import event_utils as futil
import lib_browser
from fusion2masso import (
    MassoToolFile,
    parse_fusion_library,
    merge,
    auto_number_tools,
    ChangeKind,
)
from fusion2masso.fusion_sync import push_library_to_fusion

app = adsk.core.Application.get()
ui = app.userInterface

_global_handlers = []   # lives for the add-in lifetime (commandCreated)
_dialog_handlers = []  # lives for one dialog session, cleared on destroy
_temp_files: list[str] = []

CUSTOM_PANEL_ID = "MassoToolSyncPanel"
CUSTOM_PANEL_NAME = "MASSO"

# (workspace_id, tab_id_or_None, panel_id)
_TOOLBAR_LOCATIONS = [
    ("CAMEnvironment", "MillingTab", None),        # custom MASSO panel in Milling tab
    ("FusionSolidEnvironment", None, "SolidScriptsAddinsPanel"),  # Design > Add-Ins
]


# ---------------------------------------------------------------------------
# User settings persistence (backup path)
# ---------------------------------------------------------------------------

def _load_user_settings() -> dict:
    try:
        if os.path.exists(config.USER_SETTINGS_FILE):
            with open(config.USER_SETTINGS_FILE) as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def _save_user_settings(settings: dict):
    try:
        with open(config.USER_SETTINGS_FILE, "w") as f:
            json.dump(settings, f, indent=2)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# USB validation and backup
# ---------------------------------------------------------------------------

def _validate_usb(usb_path: str):
    """Returns (is_valid, status_html, htg_path_or_none, detected_filename).

    Auto-detects firmware version by checking which .htg file exists.
    """
    if not usb_path or not os.path.isdir(usb_path):
        return False, "<span style='color:gray'><i>Select MASSO USB drive...</i></span>", None, None
    settings_dir = os.path.join(usb_path, config.MACHINE_SETTINGS_SUBDIR)
    if not os.path.isdir(settings_dir):
        return False, "<span style='color:red'>MASSO/Machine Settings/ not found on this drive</span>", None, None

    # Auto-detect firmware by checking which .htg files exist
    for fw_name, fw_info in config.FIRMWARE_VERSIONS.items():
        htg = os.path.join(settings_dir, fw_info["filename"])
        if os.path.isfile(htg):
            return (
                True,
                f"<span style='color:green'>Found {fw_info['filename']} ({fw_name})</span>",
                htg,
                fw_info["filename"],
            )

    # No tool file found — default to current firmware filename
    default_filename = list(config.FIRMWARE_VERSIONS.values())[0]["filename"]
    return (
        True,
        f"<span style='color:orange'>No existing tool table — will create {default_filename}</span>",
        None,
        default_filename,
    )


def _backup_machine_settings(usb_path: str, backup_dir: str) -> str:
    """Zip the Machine Settings folder. Returns path to zip file."""
    settings_dir = os.path.join(usb_path, config.MACHINE_SETTINGS_SUBDIR)
    os.makedirs(backup_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    zip_path = os.path.join(backup_dir, f"MASSO_Backup_{timestamp}.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for fname in os.listdir(settings_dir):
            fpath = os.path.join(settings_dir, fname)
            if os.path.isfile(fpath):
                zf.write(fpath, os.path.join("Machine Settings", fname))
    return zip_path


# ---------------------------------------------------------------------------
# Start / Stop
# ---------------------------------------------------------------------------

def start():
    """Register the toolbar button in Manufacture and Design workspaces."""
    old_def = ui.commandDefinitions.itemById(config.CMD_ID)
    if old_def:
        old_def.deleteMe()

    icon_folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resources", "")
    cmd_def = ui.commandDefinitions.addButtonDefinition(
        config.CMD_ID, config.CMD_NAME, config.CMD_DESC, icon_folder
    )

    class OnCommandCreated(adsk.core.CommandCreatedEventHandler):
        def __init__(self): super().__init__()
        def notify(self, args):
            try:
                command_created(args)
            except Exception:
                ui.messageBox(f"Dialog build error:\n{traceback.format_exc()}", config.CMD_NAME)

    _handler = OnCommandCreated()
    cmd_def.commandCreated.add(_handler)
    _global_handlers.append(_handler)

    for ws_id, tab_id, panel_id in _TOOLBAR_LOCATIONS:
        try:
            workspace = ui.workspaces.itemById(ws_id)
            if not workspace:
                continue
            if tab_id:
                tab = workspace.toolbarTabs.itemById(tab_id)
                if not tab:
                    continue
                panel = tab.toolbarPanels.itemById(CUSTOM_PANEL_ID)
                if not panel:
                    panel = tab.toolbarPanels.add(
                        CUSTOM_PANEL_ID, CUSTOM_PANEL_NAME, "CAMManagePanel", False
                    )
            else:
                panel = workspace.toolbarPanels.itemById(panel_id)
            if not panel:
                continue
            if not panel.controls.itemById(config.CMD_ID):
                control = panel.controls.addCommand(cmd_def)
                control.isPromoted = True
                control.isPromotedByDefault = True
        except Exception:
            pass


def stop():
    """Remove toolbar buttons and clean up."""
    for ws_id, tab_id, panel_id in _TOOLBAR_LOCATIONS:
        try:
            workspace = ui.workspaces.itemById(ws_id)
            if not workspace:
                continue
            if tab_id:
                tab = workspace.toolbarTabs.itemById(tab_id)
                if not tab:
                    continue
                panel = tab.toolbarPanels.itemById(CUSTOM_PANEL_ID)
            else:
                panel = workspace.toolbarPanels.itemById(panel_id)
            if not panel:
                continue
            control = panel.controls.itemById(config.CMD_ID)
            if control:
                control.deleteMe()
            if tab_id:
                panel = tab.toolbarPanels.itemById(CUSTOM_PANEL_ID)
                if panel and panel.controls.count == 0:
                    panel.deleteMe()
        except Exception:
            pass

    cmd_def = ui.commandDefinitions.itemById(config.CMD_ID)
    if cmd_def:
        cmd_def.deleteMe()

    global _global_handlers
    _global_handlers = []
    futil.clear_handlers()
    _cleanup_temp_files()


def _cleanup_temp_files():
    global _temp_files
    for f in _temp_files:
        try:
            os.remove(f)
        except OSError:
            pass
    _temp_files = []


def _find_input(inputs, input_id):
    """Recursively find a command input by ID (searches inside groups)."""
    result = inputs.itemById(input_id)
    if result:
        return result
    for i in range(inputs.count):
        inp = inputs.item(i)
        if hasattr(inp, "children"):
            result = _find_input(inp.children, input_id)
            if result:
                return result
    return None



# ---------------------------------------------------------------------------
# Command Created — builds the dialog
# ---------------------------------------------------------------------------

def command_created(args: adsk.core.CommandCreatedEventArgs):
    try:
        _command_created_impl(args)
    except Exception:
        ui.messageBox(f"Dialog build error:\n{traceback.format_exc()}", config.CMD_NAME)


def _command_created_impl(args: adsk.core.CommandCreatedEventArgs):
    cmd = args.command
    inputs = cmd.commandInputs

    user_settings = _load_user_settings()

    # ---- Source Group ----
    grp_src = inputs.addGroupCommandInput("grp_source", "Tool Library Source")
    grp_src.isExpanded = True

    source_dd = grp_src.children.addDropDownCommandInput(
        "lib_source", "Source",
        adsk.core.DropDownStyles.TextListDropDownStyle,
    )
    source_dd.listItems.add("Fusion Library", True)
    source_dd.listItems.add("File on Disk", False)

    fusion_dd = grp_src.children.addDropDownCommandInput(
        "fusion_lib", "Fusion Library",
        adsk.core.DropDownStyles.TextListDropDownStyle,
    )
    try:
        libs = lib_browser.get_local_libraries()
        for name, url_str in libs:
            fusion_dd.listItems.add(name, False)
        if fusion_dd.listItems.count > 0:
            fusion_dd.listItems.item(0).isSelected = True
    except Exception:
        fusion_dd.listItems.add("(unable to load libraries)", True)

    file_input = grp_src.children.addStringValueInput("file_path", "Library File", "")
    file_input.isVisible = False
    browse_file = grp_src.children.addBoolValueInput("browse_file", "Browse...", False, "", False)
    browse_file.isVisible = False

    # ---- MASSO Configuration Group ----
    grp_masso = inputs.addGroupCommandInput("grp_masso", "MASSO Configuration")
    grp_masso.isExpanded = True

    units_dd = grp_masso.children.addDropDownCommandInput(
        "masso_units", "MASSO Units",
        adsk.core.DropDownStyles.TextListDropDownStyle,
    )
    for name in config.MASSO_UNITS:
        units_dd.listItems.add(name, name.startswith("Milli"))

    num_dd = grp_masso.children.addDropDownCommandInput(
        "numbering_mode", "Tool Numbering",
        adsk.core.DropDownStyles.TextListDropDownStyle,
    )
    num_dd.listItems.add("Auto-assign (T1, T2, T3...)", True)
    num_dd.listItems.add("Use Fusion post-process numbers", False)

    z_dd = grp_masso.children.addDropDownCommandInput(
        "z_offset_mode", "Z Offset Mode",
        adsk.core.DropDownStyles.TextListDropDownStyle,
    )
    for name in config.Z_MODES:
        z_dd.listItems.add(name, name.startswith("Preserve"))

    slot_dd = grp_masso.children.addDropDownCommandInput(
        "slot_mode", "Slot Assignment",
        adsk.core.DropDownStyles.TextListDropDownStyle,
    )
    for name in config.SLOT_MODES:
        slot_dd.listItems.add(name, name.startswith("Match"))

    # ---- MASSO USB Drive Group ----
    grp_usb = inputs.addGroupCommandInput("grp_usb", "MASSO USB Drive")
    grp_usb.isExpanded = True

    grp_usb.children.addStringValueInput("usb_path", "USB Drive", "")
    grp_usb.children.addBoolValueInput("browse_usb", "Select USB Drive...", False, "", False)
    grp_usb.children.addTextBoxCommandInput(
        "usb_status", "",
        "<span style='color:gray'><i>Select MASSO USB drive...</i></span>", 1, True
    )

    # Backup location (persisted)
    saved_backup = user_settings.get("backup_path", config.DEFAULT_BACKUP_DIR)
    grp_usb.children.addStringValueInput("backup_path", "Backup Location", saved_backup)
    grp_usb.children.addBoolValueInput("browse_backup", "Browse...", False, "", False)

    # ---- Options ----
    grp_opts = inputs.addGroupCommandInput("grp_options", "Options")
    grp_opts.isExpanded = True
    grp_opts.children.addBoolValueInput(
        "sync_fusion", "Create synced library in Fusion", True, "", True
    )
    grp_opts.children.addBoolValueInput(
        "auto_eject", "Eject USB drive when done", True, "", True
    )

    # ---- Preview ----
    inputs.addTextBoxCommandInput(
        "preview", "Merge Preview",
        "<i>Select a tool library to see preview...</i>", 14, True
    )

    # Attach handlers
    _attach_dialog_handlers(cmd)

    # Trigger initial preview
    _update_preview(inputs)


# ---------------------------------------------------------------------------
# Module-level handler classes
# ---------------------------------------------------------------------------

class _InputChangedHandler(adsk.core.InputChangedEventHandler):
    def __init__(self):
        super().__init__()
    def notify(self, args):
        try:
            command_input_changed(args)
        except Exception:
            ui.messageBox(f"inputChanged error:\n{traceback.format_exc()}", config.CMD_NAME)


class _ValidateHandler(adsk.core.ValidateInputsEventHandler):
    def __init__(self):
        super().__init__()
    def notify(self, args):
        try:
            command_validate(args)
        except Exception:
            pass


class _ExecuteHandler(adsk.core.CommandEventHandler):
    def __init__(self):
        super().__init__()
    def notify(self, args):
        try:
            command_execute(args)
        except Exception:
            ui.messageBox(f"Execute error:\n{traceback.format_exc()}", config.CMD_NAME)


class _DestroyHandler(adsk.core.CommandEventHandler):
    def __init__(self):
        super().__init__()
    def notify(self, args):
        command_destroy(args)


def _attach_dialog_handlers(cmd):
    h1 = _InputChangedHandler()
    h2 = _ValidateHandler()
    h3 = _ExecuteHandler()
    h4 = _DestroyHandler()
    cmd.inputChanged.add(h1)
    cmd.validateInputs.add(h2)
    cmd.execute.add(h3)
    cmd.destroy.add(h4)
    _dialog_handlers.extend([h1, h2, h3, h4])


# ---------------------------------------------------------------------------
# Input Changed
# ---------------------------------------------------------------------------

def command_input_changed(args: adsk.core.InputChangedEventArgs):
    try:
        _command_input_changed_impl(args)
    except Exception:
        ui.messageBox(f"inputChanged error:\n{traceback.format_exc()}", config.CMD_NAME)


def _command_input_changed_impl(args: adsk.core.InputChangedEventArgs):
    changed = args.input
    inputs = args.firingEvent.sender.commandInputs

    # Toggle source visibility
    if changed.id == "lib_source":
        is_fusion = _find_input(inputs, "lib_source").selectedItem.name == "Fusion Library"
        _find_input(inputs, "fusion_lib").isVisible = is_fusion
        _find_input(inputs, "file_path").isVisible = not is_fusion
        _find_input(inputs, "browse_file").isVisible = not is_fusion

    # Browse buttons
    if changed.id == "browse_file" and changed.value:
        dlg = ui.createFileDialog()
        dlg.title = "Select Fusion Tool Library"
        dlg.filter = "Fusion Tool Libraries (*.tools;*.json);;All Files (*.*)"
        if dlg.showOpen() == adsk.core.DialogResults.DialogOK:
            _find_input(inputs, "file_path").value = dlg.filename
        changed.value = False

    if changed.id == "browse_usb" and changed.value:
        dlg = ui.createFolderDialog()
        dlg.title = "Select MASSO USB Drive"
        if dlg.showDialog() == adsk.core.DialogResults.DialogOK:
            _find_input(inputs, "usb_path").value = dlg.folder
        changed.value = False

    if changed.id == "browse_backup" and changed.value:
        dlg = ui.createFolderDialog()
        dlg.title = "Select Backup Location"
        if dlg.showDialog() == adsk.core.DialogResults.DialogOK:
            _find_input(inputs, "backup_path").value = dlg.folder
        changed.value = False

    # Update USB status when usb_path changes
    if changed.id in ("usb_path", "browse_usb"):
        usb_path = _find_input(inputs, "usb_path").value.strip()
        _, status_html, _, _ = _validate_usb(usb_path)
        _find_input(inputs, "usb_status").formattedText = status_html

    _update_preview(inputs)


# ---------------------------------------------------------------------------
# Validate — enable/disable OK button
# ---------------------------------------------------------------------------

def command_validate(args: adsk.core.ValidateInputsEventArgs):
    inputs = args.firingEvent.sender.commandInputs

    has_source = False
    source = _find_input(inputs, "lib_source")
    if source and source.selectedItem:
        if source.selectedItem.name == "Fusion Library":
            fusion_lib = _find_input(inputs, "fusion_lib")
            has_source = fusion_lib and fusion_lib.selectedItem is not None
        else:
            file_path = _find_input(inputs, "file_path")
            has_source = bool(file_path and file_path.value.strip())

    usb_path = _find_input(inputs, "usb_path").value.strip()
    usb_valid, _, _, _ = _validate_usb(usb_path)

    args.areInputsValid = has_source and usb_valid


# ---------------------------------------------------------------------------
# Preview helpers
# ---------------------------------------------------------------------------

def _clear_non_fusion_tools(masso_file: MassoToolFile, fusion_numbers: set[int]):
    """Blank out MASSO slots that are NOT in the Fusion library.

    Tools at slots matching Fusion numbers are kept (so merge can
    detect UNCHANGED/UPDATED/REPLACED and preserve Z offsets).
    Everything else is wiped so the controller ends up with only
    the Fusion library's tools.
    """
    from fusion2masso.masso import MassoTool, NUM_RECORDS
    for i in range(1, NUM_RECORDS):
        if i not in fusion_numbers:
            masso_file.tools[i] = MassoTool()


def _get_source_path(inputs) -> str | None:
    """Get the tool library path (exporting from Fusion if needed)."""
    source = _find_input(inputs, "lib_source")
    if not source or not source.selectedItem:
        return None

    if source.selectedItem.name == "Fusion Library":
        fusion_lib = _find_input(inputs, "fusion_lib")
        if not fusion_lib or not fusion_lib.selectedItem:
            return None
        lib_name = fusion_lib.selectedItem.name
        try:
            libs = lib_browser.get_local_libraries()
            url_str = next(url for name, url in libs if name == lib_name)
            tmp = lib_browser.export_library_to_json(url_str)
            _temp_files.append(tmp)
            return tmp
        except Exception:
            return None
    else:
        path = _find_input(inputs, "file_path").value.strip()
        return path if path and os.path.exists(path) else None


def _get_z_mode(inputs) -> str:
    sel = _find_input(inputs, "z_offset_mode").selectedItem
    return config.Z_MODES.get(sel.name, "preserve") if sel else "preserve"


def _get_masso_units(inputs) -> str:
    sel = _find_input(inputs, "masso_units").selectedItem
    return config.MASSO_UNITS.get(sel.name, "mm") if sel else "mm"


def _get_slot_mode(inputs) -> str:
    sel = _find_input(inputs, "slot_mode").selectedItem
    return config.SLOT_MODES.get(sel.name, "match") if sel else "match"


def _is_auto_number(inputs) -> bool:
    sel = _find_input(inputs, "numbering_mode").selectedItem
    return sel is not None and sel.name.startswith("Auto")


def _get_usb_htg_path(inputs) -> str | None:
    """Get the .htg path from the USB drive, or None."""
    usb_path = _find_input(inputs, "usb_path").value.strip()
    if not usb_path:
        return None
    _, _, htg_path, _ = _validate_usb(usb_path)
    return htg_path


def _update_preview(inputs):
    preview = _find_input(inputs, "preview")
    if not preview:
        return

    source_path = _get_source_path(inputs)
    if not source_path:
        preview.formattedText = "<i>Select a tool library to see preview...</i>"
        return

    try:
        fusion_tools = parse_fusion_library(source_path)
        if _is_auto_number(inputs):
            auto_number_tools(fusion_tools)
    except Exception as e:
        preview.formattedText = f"<span style='color:red'>Error reading library: {e}</span>"
        return

    # Load existing .htg from USB. Keep tools that overlap with Fusion (so Z
    # offsets are preserved via merge), but blank out any MASSO-only tools so
    # the controller ends up with exactly the Fusion library's tool set.
    fusion_numbers = {t.number for t in fusion_tools if t.number is not None}
    htg_path = _get_usb_htg_path(inputs)
    try:
        if htg_path:
            masso_preview = MassoToolFile.load(htg_path)
            masso_preview = MassoToolFile.from_bytes(masso_preview.to_bytes())
        else:
            masso_preview = MassoToolFile()
        _clear_non_fusion_tools(masso_preview, fusion_numbers)
    except Exception as e:
        preview.formattedText = f"<span style='color:red'>Error reading .htg: {e}</span>"
        return

    z_mode = _get_z_mode(inputs)
    masso_units = _get_masso_units(inputs)

    try:
        report = merge(fusion_tools, masso_preview,
                       masso_units=masso_units, z_mode=z_mode,
                       slot_mode=_get_slot_mode(inputs))
    except Exception as e:
        preview.formattedText = f"<span style='color:red'>Merge error: {e}</span>"
        return

    preview.formattedText = _format_report_html(report, len(fusion_tools))


def _format_report_html(report, total_tools: int) -> str:
    lines = [f"<b>Merge Preview</b> ({total_tools} tools in library)<br>"]

    counts = {kind: len(report.by_kind(kind)) for kind in ChangeKind}

    if counts[ChangeKind.ADDED]:
        lines.append(f"<span style='color:green'><b>ADDED: {counts[ChangeKind.ADDED]}</b></span> (new slots)<br>")
    if counts[ChangeKind.UPDATED]:
        lines.append(f"<span style='color:blue'><b>UPDATED: {counts[ChangeKind.UPDATED]}</b></span><br>")
    if counts[ChangeKind.REPLACED]:
        lines.append(f"<span style='color:orange'><b>REPLACED: {counts[ChangeKind.REPLACED]}</b></span> (different tool)<br>")
    if counts[ChangeKind.UNCHANGED]:
        lines.append(f"UNCHANGED: {counts[ChangeKind.UNCHANGED]}<br>")
    if counts[ChangeKind.SKIPPED]:
        lines.append(f"<span style='color:gray'>SKIPPED: {counts[ChangeKind.SKIPPED]}</span><br>")

    details = []
    for c in report.changes:
        if c.kind == ChangeKind.UNCHANGED:
            continue
        num_str = f"T{c.number}" if c.number >= 0 else "T?"
        name = c.fusion_name[:40]
        if c.kind == ChangeKind.ADDED:
            details.append(f"<span style='color:green'>{num_str}</span> {name}")
        elif c.kind == ChangeKind.REPLACED:
            details.append(f"<span style='color:orange'>{num_str}</span> {name} <i>({c.reason[:50]})</i>")
        elif c.kind == ChangeKind.UPDATED:
            details.append(f"<span style='color:blue'>{num_str}</span> {name} <i>({c.reason[:60]})</i>")
        elif c.kind == ChangeKind.SKIPPED:
            details.append(f"<span style='color:gray'>{num_str} {name} — {c.reason}</span>")

    if details:
        lines.append("<br><b>Details:</b><br>")
        for d in details[:20]:
            lines.append(f"{d}<br>")
        if len(details) > 20:
            lines.append(f"<i>...and {len(details) - 20} more</i><br>")

    if report.warnings:
        lines.append(f"<br><b>Warnings:</b><br>")
        for w in report.warnings[:5]:
            lines.append(f"<span style='color:orange'>{w[:80]}</span><br>")

    return "".join(lines)


# ---------------------------------------------------------------------------
# Execute — the real merge
# ---------------------------------------------------------------------------

def command_execute(args: adsk.core.CommandEventArgs):
    inputs = args.command.commandInputs

    try:
        # Validate USB and auto-detect firmware
        usb_path = _find_input(inputs, "usb_path").value.strip()
        usb_valid, _, existing_htg_path, htg_filename = _validate_usb(usb_path)
        if not usb_valid:
            ui.messageBox("MASSO USB drive not valid. Please select a USB drive with MASSO/Machine Settings/.", config.CMD_NAME)
            return

        # Parse source library
        source_path = _get_source_path(inputs)
        if not source_path:
            ui.messageBox("No tool library selected.", config.CMD_NAME)
            return

        fusion_tools = parse_fusion_library(source_path)
        if _is_auto_number(inputs):
            auto_number_tools(fusion_tools)

        # Load existing .htg — keep tools that overlap with Fusion (preserves Z),
        # blank out slots not in the Fusion library.
        if existing_htg_path:
            masso_file = MassoToolFile.load(existing_htg_path)
        else:
            masso_file = MassoToolFile()
        fusion_numbers = {t.number for t in fusion_tools if t.number is not None}
        _clear_non_fusion_tools(masso_file, fusion_numbers)

        # Merge
        z_mode = _get_z_mode(inputs)
        masso_units = _get_masso_units(inputs)
        report = merge(fusion_tools, masso_file,
                       masso_units=masso_units, z_mode=z_mode,
                       slot_mode=_get_slot_mode(inputs))

        # Backup existing Machine Settings
        backup_path = _find_input(inputs, "backup_path").value.strip()
        if not backup_path:
            backup_path = config.DEFAULT_BACKUP_DIR
        zip_path = _backup_machine_settings(usb_path, backup_path)

        # Save backup path for next time
        _save_user_settings({"backup_path": backup_path})

        # Write new .htg to USB
        output_path = os.path.join(usb_path, config.MACHINE_SETTINGS_SUBDIR, htg_filename)
        masso_file.save(output_path)

        # Optional: sync back to Fusion
        sync_msg = ""
        if _find_input(inputs, "sync_fusion").value:
            source_name = _find_input(inputs, "lib_source").selectedItem.name
            if source_name == "Fusion Library":
                lib_name = _find_input(inputs, "fusion_lib").selectedItem.name
            else:
                lib_name = os.path.splitext(os.path.basename(source_path))[0]
            while lib_name.endswith(" - MASSO"):
                lib_name = lib_name[: -len(" - MASSO")]
            masso_lib_name = f"{lib_name} - MASSO"

            try:
                push_library_to_fusion(fusion_tools, masso_lib_name)
                sync_msg = f"\nFusion library created: {masso_lib_name}"
            except RuntimeError as e:
                sync_msg = f"\nFusion sync warning: {e}"

        # Optional: eject USB
        eject_msg = ""
        if _find_input(inputs, "auto_eject").value:
            try:
                import subprocess
                subprocess.run(
                    ["diskutil", "eject", usb_path],
                    capture_output=True, timeout=10,
                )
                eject_msg = "\nUSB drive ejected — safe to unplug."
            except Exception as e:
                eject_msg = f"\nCould not eject USB: {e}"

        # Build summary
        counts = {k: len(report.by_kind(k)) for k in ChangeKind}
        skip_note = ""
        if counts[ChangeKind.SKIPPED]:
            skip_note = (
                f"\n\nSkipped {counts[ChangeKind.SKIPPED]} tool(s) — "
                "MASSO supports T1-T104 (104 slots max)."
            )

        if eject_msg:
            next_steps = (
                "Next steps:\n"
                "1. Plug USB into MASSO controller\n"
                "2. F1 Setup > Save & Load Calibration Settings > Load from file\n"
                "3. Reboot MASSO controller\n"
                "4. Probe Z on new/changed tools"
            )
        else:
            next_steps = (
                "Next steps:\n"
                "1. Safely eject the USB drive\n"
                "2. Plug USB into MASSO controller\n"
                "3. F1 Setup > Save & Load Calibration Settings > Load from file\n"
                "4. Reboot MASSO controller\n"
                "5. Probe Z on new/changed tools"
            )

        summary = (
            f"Tool table updated on USB!\n\n"
            f"Written to: {output_path}\n"
            f"Backup saved to: {zip_path}"
            f"{eject_msg}"
            f"\n\n"
            f"Added: {counts[ChangeKind.ADDED]}  |  "
            f"Updated: {counts[ChangeKind.UPDATED]}  |  "
            f"Replaced: {counts[ChangeKind.REPLACED]}  |  "
            f"Unchanged: {counts[ChangeKind.UNCHANGED]}"
            f"{skip_note}"
            f"{sync_msg}\n\n"
            f"{next_steps}"
        )
        ui.messageBox(summary, config.CMD_NAME)

    except Exception:
        ui.messageBox(
            f"Error during merge:\n{traceback.format_exc()}",
            config.CMD_NAME,
        )


# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------

def command_destroy(args: adsk.core.CommandEventArgs):
    global _dialog_handlers
    _dialog_handlers = []
    _cleanup_temp_files()
