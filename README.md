# Dell BIOS Update Script
**MedPro Healthcare Staffing — IT Infrastructure**  
`Author: Javi @ MedPro IT / StackPoint IT` | `Version: 1.0` | `Updated: 2026-03-12`

---

## Overview

Automated silent BIOS update script targeting five Dell Vostro model families identified in MedPro's vulnerability remediation roster. Designed for RMM deployment (Action1, Intune, GPO) and runs as SYSTEM or local admin with no user interaction required.

Supports two acquisition modes: **direct download** from `dl.dell.com` via BITS (with WebClient fallback), or **network share** mode for pre-staged environments. No automatic reboot — reboot scheduling is left to the deployment pipeline.

---

## Targeted Models & BIOS Versions

| Model | Current Version | Target Version | Driver ID |
|---|---|---|---|
| Vostro 5620 | 1.32 | **1.33.0** | `mpy0m` |
| Vostro 5890 | 1.37 | **1.40.0** | `94f3t` |
| Vostro 7620 | 1.33.1 | **1.34.0** | `fycn3` |
| Vostro 14 5410 | 2.38.1 | **2.39.0** | `ym51n` |
| Vostro 15 5510 | 2.38.1 | **2.39.0** | `ym51n` |

---

## Requirements

- **OS:** Windows 10 / Windows 11
- **Execution context:** Local Administrator or SYSTEM (required — script enforces this)
- **PowerShell:** 5.1+
- **Network access:** `dl.dell.com` (direct download mode) or UNC path to `\\med-dc-02\BIOS_Updates` (network share mode)
- **BITS service** must be running for primary download method (WebClient fallback is automatic)

---

## Deployment

### Via Action1 (recommended)
1. Upload `DellBIOSUpdate.ps1` to your Action1 script library.
2. Target the relevant device groups (filter by model if possible).
3. Run as **SYSTEM**.
4. Schedule a separate reboot task after the script completes with exit code `0` or `2`.

### Via RMM / GPO
```powershell
powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "\\path\to\DellBIOSUpdate.ps1"
```

### Manual (elevated prompt)
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\DellBIOSUpdate.ps1
```

---

## Configuration

### Network Share Mode
Pre-stage the BIOS `.exe` files on a local share to avoid internet downloads at runtime.

```powershell
$UseNetworkShare  = $true
$NetworkSharePath = '\\med-dc-02\BIOS_Updates'
```

File names on the share must exactly match the `FileName` values defined in `$BIOSMap`.

### BIOS Admin Password
If machines have a BIOS administrator password set, uncomment and populate:

```powershell
$BIOSPassword = 'YourBIOSPassword'
$installArgs += " /p=`"$BIOSPassword`""
```

> ⚠️ **Security note:** Do not hardcode BIOS passwords in a script stored in version control or a shared repository. Use a secrets manager, RMM variable injection, or environment variable retrieval at runtime.

---

## Logging

All activity is logged to:

```
C:\ProgramData\MedPro\BIOSUpdate\BIOSUpdate.log
```

Dell's own installer log is written to:

```
C:\ProgramData\MedPro\BIOSUpdate\DellBIOS_<DriverID>.log
```

Both files persist after the script completes. The staging directory (`%TEMP%\MedPro_BIOS`) is cleaned up automatically.

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success — update applied (or already at target version) |
| `1` | Model not in scope — no action taken |
| `2` | Download or file acquisition failed |
| `3` | BIOS installer execution failed |
| `4` | Not running as Administrator / SYSTEM |

> Dell's own installer may return exit code `2` to indicate a staged update pending reboot. The script treats this as success.

---

## Behavior Details

### Model Matching
The script first attempts an exact match against WMI `Win32_ComputerSystem.Model`. If that fails, it falls back to a fuzzy contains-match to handle minor OEM string variations (e.g., `"Vostro 5620 2-in-1"` still matches `"Vostro 5620"`).

### Version Comparison
Current BIOS version is read from `Win32_BIOS.SMBIOSBIOSVersion` and compared to the target using `[System.Version]`. If the installed version is **already at or above** the target, the script exits cleanly with code `0` — no download, no install.

### Download Resilience
- Primary: **BITS** (`Start-BitsTransfer`) — handles interruptions, supports resume
- Fallback: **WebClient** with TLS 1.2 forced (`[Net.SecurityProtocolType]::Tls12`)
- Post-download: file existence and non-zero size are validated before execution

### Silent Install Flags
```
/s          Silent mode (no UI)
/l="<path>" Dell installer log path
```
The `/r` (auto-reboot) flag is intentionally **omitted**. Reboot must be triggered by the deployment platform.

---

## File Structure

```
DellBIOSUpdate.ps1
└── Logs written to:
    C:\ProgramData\MedPro\BIOSUpdate\
    ├── BIOSUpdate.log
    └── DellBIOS_<DriverID>.log
```

---

## Security Considerations

- Script enforces admin/SYSTEM execution and exits with code `4` if not elevated.
- Downloads are sourced exclusively from `dl.dell.com` (Dell's official CDN).
- TLS 1.2 is enforced on all WebClient downloads.
- BIOS installers are staged to `%TEMP%` and deleted after execution.
- No credentials are stored in the script by default.
- If adding a BIOS password, inject it via RMM secret/variable — never commit it to source.

---

## Maintenance

When new BIOS versions are released, update the `$BIOSMap` entries:

1. Locate the new `.exe` on [Dell Drivers & Downloads](https://www.dell.com/support/home/en-us).
2. Extract the direct `dl.dell.com` URL (use browser dev tools on the download button).
3. Update `TargetVersion`, `DownloadURL`, `FileName`, and `DriverID` for the affected model.
4. Update the `CurrentVersion` comment to reflect the new baseline.
5. Update the `Version` and `Date` fields in the `.NOTES` block.

---

*MedPro Healthcare Staffing — Internal IT Use Only*  
*Questions: Javi @ StackPoint IT*
