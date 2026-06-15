# QZ Tray Setup for SystemInfo-GUI

This document explains how to configure QZ Tray on a fresh machine so that **SystemInfo-GUI** can print labels silently — no `Action Required` dialog, no `Allow / Block` prompts, no `Cannot verify trust - Invalid Signature` errors.

If you're reading this because something stopped working, jump to **Troubleshooting** at the bottom.

---

## How signing works in QZ Tray (the short version)

QZ Tray refuses to print on behalf of a remote client unless every print request is digitally signed by a certificate that QZ Tray already trusts. The flow is:

1. The client sends its **public certificate** as the first message on the WebSocket.
2. For each subsequent privileged call (`print`, `printers.find`, etc.), the client signs a JSON payload containing `{call, params, timestamp}` with its **private key** and includes the signature in the message.
3. QZ Tray verifies the signature against the public certificate. If verification fails, the gateway dialog appears.

To make the dialog disappear you need a cert/key pair that QZ Tray's local installation trusts. Two paths produce one (both covered in *Initial setup*, Step 3): generate a CA cert with `Generate-QzCert.ps1` and trust it on the host via `%APPDATA%\qz\certs\` + a one-time Allow, or use QZ Tray's own **Create New** wizard, which generates the keys *and* registers the cert in every trust store QZ Tray uses internally. Note that simply editing `override.crt` by hand only updates the Site Manager display — runtime signature verification uses a different code path, which is why the wizard (or the certs-folder + Allow flow) is needed.

---

## Initial setup on a new QZ Tray host

You only need to do this once per QZ Tray host (the machine the DYMO printer is physically attached to). The same cert/key pair can then be embedded in SystemInfo-GUI and deployed to any number of laptops.

### Step 1 — Install QZ Tray

1. Download QZ Tray 2.2.x from <https://qz.io/download>
2. Install with default options. Allow firewall access if prompted.
3. After install, QZ Tray starts in the system tray (look for the green/orange icon near the clock).

### Step 2 — Install the DYMO driver

Install the DYMO LabelWriter driver and confirm Windows can print a test page to the LabelWriter. QZ Tray talks to printers through the Windows print spooler, so the driver must be working before QZ Tray will find it.

### Step 3 — Generate the signing credentials

You need an RSA cert/key pair that QZ Tray trusts. There are two ways to produce one. **Option A** is the path the main script now expects (its header points at `Generate-QzCert.ps1`); **Option B** is the original QZ Tray wizard, kept here because it auto-registers trust on the host and because the troubleshooting notes below reference it.

Whichever you pick, the cert/key end up pasted into the two here-strings in `SystemInfo-GUI.ps1` (see *Embedding the cert/key* below).

#### Option A — `Generate-QzCert.ps1` (recommended)

Run this once on any Windows machine (PowerShell 7 / `pwsh.exe` is required to export the PKCS#8 key):

```powershell
pwsh .\Generate-QzCert.ps1
```

It writes four files next to the script:

| File | Use |
| --- | --- |
| `systeminfo-qz.pem` | Public certificate → paste into `$script:EmbeddedCertPem`, **and** copy to the QZ Tray host (see below) |
| `systeminfo-qz.key.pem` | PKCS#8 private key → paste into `$script:EmbeddedKeyPem` |
| `systeminfo-qz.pfx` | Private key + cert (password `QzLabel2024!`), if you need a PFX |
| `systeminfo-qz.pfxb64.txt` | Base64 of the PFX |

> These outputs are gitignored (`*.pem`, `*.pfx`, `*pfxb64.txt`) — they hold the private key and must never be committed.

The cert is self-signed with `BasicConstraints CA:TRUE`, which is what lets QZ Tray grant print permission when you add it via Site Manager's **`+`** button. To trust it on the host:

1. Copy `systeminfo-qz.pem` into `%APPDATA%\qz\certs\` on the QZ Tray host (create the folder if it doesn't exist), then restart QZ Tray.
2. On the first print, QZ Tray may show a one-time **Allow / Block** popup — click **Allow** and tick **Remember this decision** to silence it for good. (Or pre-approve it in Site Manager before distributing the exe.)

Then skip to *Embedding the cert/key*.

#### Option B — QZ Tray's "Create New" wizard

Use this if you'd rather have QZ Tray generate and auto-trust the keys on the host. Manually editing `override.crt` is **not** sufficient — the wizard does additional trust-store registration that no other method replicates.

1. Right-click the QZ Tray icon in the system tray → **Advanced** → **Site Manager**
2. In the Site Manager window, click the **`+`** button at the bottom.
3. Choose **Create New** from the dropdown.
4. A series of prompts will appear. Click **Yes** to all three:
   - "Would you like to create the keys?" → **Yes**
   - "Automatically install?" → **Yes**
   - "Copy keys to override.crt?" → **Yes**
5. Approve the UAC elevation prompt that follows.
6. When the wizard finishes, a folder called **`QZ Tray Demo Cert`** appears on the current user's Desktop. It contains two files:
   - `digital-certificate.txt` — the X.509 certificate (PEM)
   - `private-key.pem` — the matching RSA private key (PKCS#8, 2048-bit)

**Keep this folder safe.** The private key is what authorises silent printing — anyone with it can print to your QZ Tray host without prompts.

### Step 4 — Verify the cert is trusted

In Site Manager → Sites tab, you should now see your cert listed:

- **Option A** (`Generate-QzCert.ps1`): Common Name `SystemInfoTool`, Organisation `Internal`. Make sure it's set to **Allow** (not Block / Prompt).
- **Option B** (wizard): Common Name `QZ Tray Demo Cert`, Organisation `QZ Industries, LLC`, Trusted `Verified by QZ Industries, LLC` (green). If Trusted shows anything else (`Third-party issued`, etc.), the wizard didn't complete — run it again.

### Step 5 — Find the QZ Tray host's IP

If laptops will connect to QZ Tray over the network (not via `localhost`), record the host's IP address or DNS name. Example: `dymo-host.lan` or `192.168.1.50`. You'll need this in the SystemInfo-GUI settings on each laptop.

---

## Embedding the cert/key in SystemInfo-GUI

This compiles the cert/key into the SystemInfo.exe so every laptop running it can print without any per-laptop setup.

### Step 1 — Open the script

Open `SystemInfo-GUI.ps1` in a text editor.

### Step 2 — Find the embedded credentials block

Search for `$script:EmbeddedCertPem`. You'll find two adjacent here-strings near the top of the file:

```powershell
$script:EmbeddedCertPem = @'
-----BEGIN CERTIFICATE-----
... base64 cert lines ...
-----END CERTIFICATE-----
'@

$script:EmbeddedKeyPem = @'
-----BEGIN PRIVATE KEY-----
... base64 key lines ...
-----END PRIVATE KEY-----
'@
```

### Step 3 — Replace the cert

Open the cert file — `systeminfo-qz.pem` (Option A) or `digital-certificate.txt` from the wizard folder (Option B). Replace the contents of `$script:EmbeddedCertPem` between the `@'` and `'@` markers with the file's contents. Preserve the `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----` markers exactly.

### Step 4 — Replace the private key

Open the key file — `systeminfo-qz.key.pem` (Option A) or `private-key.pem` from the wizard folder (Option B). Replace the contents of `$script:EmbeddedKeyPem` the same way. The key must be in PKCS#8 format (header is `BEGIN PRIVATE KEY`, not `BEGIN RSA PRIVATE KEY`). Both `Generate-QzCert.ps1` and the wizard always produce PKCS#8, so this is automatic.

### Step 5 — Recompile to .exe (optional)

If you distribute as `.exe`:

```powershell
Install-Module -Name ps2exe -Scope CurrentUser  # once
Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole -requireAdmin
```

Then deploy `SystemInfo.exe` to laptops.

---

## Configuring each laptop

The first time SystemInfo runs on a laptop, open the **Settings** dialog and confirm:

| Field | Value |
| --- | --- |
| Host | IP or DNS name of the QZ Tray host (or `localhost` if same machine) |
| Port | `8181` |
| Use WSS (TLS) | ✓ checked |
| Printer | Type or paste the exact name as shown in QZ Tray, e.g. `DYMO LabelWriter 450 Turbo`. Use **List…** to query the host. |
| Label (W × H mm) | `50 × 12` for DYMO 99017, or whatever your label is (long edge × short edge) |
| Rotate text 90° | ✓ checked for DYMO 99017 (and any label where the driver's natural orientation is portrait). Uncheck only if you've confirmed your printer driver expects landscape paper. |

Click **Test Print** to confirm everything works. If it prints silently, you're done.

---

## Troubleshooting

### "Cannot verify trust - Invalid Signature" dialog appears

Symptom: clicking Print Label causes a dialog on the QZ Tray host asking the user to Allow / Block.

Likely causes:
1. **The cert/key pair was not generated via the Site Manager wizard.** Manually editing `override.crt` is insufficient. Re-do Step 3 of *Initial setup*.
2. **The wrong key was embedded.** Verify the cert and key in the script are a matching pair: the public key in the cert must correspond to the private key. The PowerShell snippet below will confirm:
   ```powershell
   $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
       [System.Text.Encoding]::UTF8.GetBytes($script:EmbeddedCertPem))
   $cert.Subject  # should say 'QZ Tray Demo Cert'
   ```
3. **The cert is for a different QZ Tray installation.** The wizard's cert/key only trusts the machine it was generated on. If you reinstall QZ Tray or move to a new host, re-run the wizard and re-embed the new cert/key.

### `Bad signature on request` in `%APPDATA%\qz\debug.log`

The signature data isn't matching what QZ Tray expects. The signing code (in `Invoke-QzCall`) must:
- Build JSON `{call, params, timestamp}` with **bare forward slashes** (no `\/` escapes)
- SHA256-hash that JSON → 64-char lowercase hex string
- Sign the UTF-8 bytes of that hex string with **SHA512withRSA / PKCS1**
- Base64-encode

QZ Tray's verifier on the Java side (`PrintSocketClient.java` → `validSignature`) does this:
```java
JSONObject copy = new JSONObject(message, new String[] {"call", "params", "timestamp"});
return certificate.isSignatureValid(algorithm, signature,
    copy.toString().replaceAll("\\\\/", "/"));   // ← strips \/ before hashing
```

The `replaceAll("\\\\/", "/")` is the critical detail: QZ Tray reverses *any* `\/` escape in the data before hashing it. So if the client signs JSON containing `\/` (escaped slashes), the SHA256 won't match QZ Tray's, and verification fails. Base64 image data is full of `/` characters, so this affects every print call.

In `Invoke-QzCall`, the line `$signJson = $signObj | ConvertTo-Json -Depth 20 -Compress` must **not** be followed by a `-replace '/', '\/'` step (it's fine to keep that replace on the *wire* JSON `$json`, but not on the signing JSON `$signJson`).

The app's own `qz-debug.log` writes a `SIGN | signJson=... | sha256Hex=... | sigB64=...` line per print — that's the fastest way to spot the issue. If `signJson` contains any `\/` sequences, signing is broken.

### Label prints but text is rotated wrong / cut off

Toggle the **Rotate text 90°** checkbox in Settings.

**Background.** The DYMO LabelWriter driver's "natural" page orientation for file-folder-style labels (like 99017) is usually **portrait** (12mm × 50mm), even though the label physically comes out long-edge-first from the printer. If you send the driver a landscape bitmap (50 × 12), it silently rotates the bitmap 90° to fit its portrait paper definition, so text that was running across the long edge ends up running across the short edge — with most of the content cut off.

The **Rotate text 90°** checkbox handles this. With it **on**, the app:
1. Draws text in landscape internally (full LabelWidthMm of room per line, so long spec strings fit)
2. Rotates the finished bitmap 90° clockwise into portrait
3. Sends the portrait bitmap to QZ Tray with width/height swapped to match

The result: the printer driver receives a portrait bitmap that matches its expected orientation, prints it directly with no further rotation, and the text ends up running along the long edge of the physical label.

If text comes out upside-down (correct edge but inverted), open `SystemInfo-GUI.ps1`, find the `RotateFlip` call in `New-LabelBitmap`, and change `Rotate90FlipNone` to `Rotate270FlipNone` (same direction, opposite handedness).

The label-size fields in Settings are **always** entered as the printer's natural feed orientation (long edge × short edge, e.g. `50 × 12` for DYMO 99017), regardless of whether rotation is enabled. The rotation toggle handles the orientation translation internally.

### How to verify what the printer actually received

The app writes a copy of the final bitmap (after any rotation) to `<install dir>\label-preview.png` on every print. Open it after a print to see exactly what was sent to QZ Tray. This is the fastest way to tell whether a problem is on the bitmap-generation side (preview looks wrong) or the printer/driver side (preview looks right but the printed label doesn't match).

### `Connection closed: 1006 - Session Closed` in QZ Tray's log

This is normal — it's the connection closing after each print job completes. SystemInfo-GUI opens a fresh WebSocket connection per print to avoid stale-cert issues. Look for `Bad signature on request` *before* the close — that's the real failure if printing isn't working.

### "Successfully chained certificate" but signature still bad

The cert is being trusted correctly, but the data being signed doesn't match what QZ Tray expects. This is purely a signing-side bug — verify the signing flow per the *Bad signature on request* section above.

### Test Print works in Settings but Print Label doesn't

Usually means `Get-LabelData` is failing to populate. Run the script from a PowerShell terminal (not as .exe) to see the actual error, or check `qz-debug.log` for the last `SIGN | signJson=...` entry to see what the print payload looked like.

---

## Cert renewal

A `Generate-QzCert.ps1` cert is valid for **10 years**; the QZ Tray wizard cert is valid for **20 years**. There's no scheduled renewal needed. If the cert is ever revoked, lost, or compromised, regenerate it (Step 3 — re-run `Generate-QzCert.ps1` or the wizard) and re-embed (Steps 1–5 of *Embedding the cert/key*).

---

## File reference

On the QZ Tray host:

| Path | Purpose |
| --- | --- |
| `%APPDATA%\qz\allowed.dat` | Trusted cert fingerprints (added by Allow + Remember, or by the wizard) |
| `%APPDATA%\qz\debug.log` | QZ Tray's runtime log — primary source of truth when debugging |
| `%APPDATA%\qz\prefs.properties` | User-level settings (e.g. `tray.notifications`) |
| `%APPDATA%\qz\certs\` | Drop `systeminfo-qz.pem` here (Option A) so QZ Tray trusts the cert; restart QZ Tray after |
| `C:\Program Files\QZ Tray\override.crt` | Root-CA override; copied by the wizard (Option B) |
| `~\Desktop\QZ Tray Demo Cert\` | Wizard output (Option B): `digital-certificate.txt` and `private-key.pem` |

On any laptop running SystemInfo-GUI:

| Path | Purpose |
| --- | --- |
| `<install dir>\SystemInfo-GUI.ps1` (or `.exe`) | The app itself, with cert/key embedded near the top |
| `<install dir>\qz-debug.log` | App's own debug log — every send, receive, and signed payload |
| `<install dir>\label-preview.png` | Copy of the final bitmap sent on the most recent print — overwritten each time. Open it to verify what reached the printer. |
| `<install dir>\settings.json` | Per-laptop settings (printer name, host, etc.) |

In this repo (build-time helpers, not shipped to laptops):

| Path | Purpose |
| --- | --- |
| `Generate-QzCert.ps1` | **Option A** generator — creates a fresh self-signed cert/key pair (`systeminfo-qz.*`) to paste into the embedded constants. Run once with `pwsh.exe`. |
| `Create-QzPfxFromPem.ps1` | Reuses the existing **InventoryApp** cert/key (already trusted in QZ Tray) so SystemInfo prints under the same identity with no host changes. Note: it targets PFX-based constants (`$script:EmbeddedPfxBase64` / `$script:PfxPassword`); the current script uses the PEM constants above, so use the InventoryApp `.pem`/`.key.pem` directly unless you switch the script back to PFX loading. |
| `diag-cim.ps1` | Standalone CIM/WMI diagnostic helper. |
