#Requires -Version 5.1
<#
.SYNOPSIS
    One-time script — generates the RSA key pair and self-signed certificate
    used by SystemInfo-GUI to authenticate with QZ Tray.

.DESCRIPTION
    Run this script ONCE on any Windows machine. It produces three files in
    the same directory as the script:

        systeminfo-qz.pfx          Private key + cert (password-protected).
                                   Base64-encode and paste into SystemInfo-GUI.ps1.

        systeminfo-qz.pem          Public certificate only.
                                   Copy to the QZ Tray host's certs folder.

        systeminfo-qz.pfxb64.txt   Ready-to-paste Base64 string for the script.

    The certificate is removed from the Windows store immediately after export.

.NOTES
    Requires Windows PowerShell 5.1 and the New-SelfSignedCertificate cmdlet
    (present on Windows 10 / Server 2016 and newer).
#>
$ErrorActionPreference = 'Stop'

# ── Customise these before running ───────────────────────────────────────────
$PfxPassword = 'QzLabel2024!'          # Keep this secret — paste it into
                                        # $script:PfxPassword in SystemInfo-GUI.ps1
$CertSubject = 'CN=SystemInfoTool,O=Internal'
$ValidYears  = 10
# ─────────────────────────────────────────────────────────────────────────────

$outDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $outDir) { $outDir = (Get-Location).Path }

$pfxPath = Join-Path $outDir 'systeminfo-qz.pfx'
$pemPath = Join-Path $outDir 'systeminfo-qz.pem'
$b64Path = Join-Path $outDir 'systeminfo-qz.pfxb64.txt'

Write-Host ''
Write-Host 'Generating RSA-2048 self-signed certificate...' -ForegroundColor Cyan

# KeyUsage includes CertSign so New-SelfSignedCertificate sets BasicConstraints
# CA:TRUE — this is what QZ Tray requires to grant print permission automatically
# when the certificate is added to Site Manager via the '+' button.
$cert = New-SelfSignedCertificate `
    -Subject           $CertSubject `
    -KeyAlgorithm      RSA `
    -KeyLength         2048 `
    -HashAlgorithm     SHA512 `
    -KeyUsage          CertSign, CRLSign, DigitalSignature `
    -NotAfter          (Get-Date).AddYears($ValidYears) `
    -CertStoreLocation 'Cert:\CurrentUser\My'

try {
    # Export PFX (private key + cert, password-protected)
    $securePwd = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
    $cert | Export-PfxCertificate -FilePath $pfxPath -Password $securePwd | Out-Null
    Write-Host "  PFX  -> $pfxPath"

    # Export public certificate PEM (for QZ Tray)
    $pem = "-----BEGIN CERTIFICATE-----`n" +
           [Convert]::ToBase64String($cert.RawData, [Base64FormattingOptions]::InsertLineBreaks) +
           "`n-----END CERTIFICATE-----`n"
    [System.IO.File]::WriteAllText($pemPath, $pem, [System.Text.Encoding]::ASCII)
    Write-Host "  PEM  -> $pemPath"

    # Export private key as PKCS#8 PEM for embedding in SystemInfo-GUI.ps1
    # (ExportPkcs8PrivateKey requires .NET 5+ / PowerShell 7)
    $keyPath = Join-Path $outDir 'systeminfo-qz.key.pem'
    try {
        $rsaKey = $null
        try { $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert) } catch {}
        if ($null -eq $rsaKey) { $rsaKey = $cert.PrivateKey }
        $pkcs8  = $rsaKey.ExportPkcs8PrivateKey()
        $keyPem = "-----BEGIN PRIVATE KEY-----`n" +
                  [Convert]::ToBase64String($pkcs8, [Base64FormattingOptions]::InsertLineBreaks) +
                  "`n-----END PRIVATE KEY-----`n"
        [System.IO.File]::WriteAllText($keyPath, $keyPem, [System.Text.Encoding]::ASCII)
        Write-Host "  KEY  -> $keyPath"
    } catch {
        Write-Host "  KEY  -> (skipped — run in PowerShell 7 / pwsh.exe to export key PEM)" -ForegroundColor Yellow
    }

    # Write Base64 PFX text (paste this into SystemInfo-GUI.ps1)
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfxPath))
    [System.IO.File]::WriteAllText($b64Path, $b64, [System.Text.Encoding]::ASCII)
    Write-Host "  B64  -> $b64Path"

} finally {
    # Remove from the Windows cert store — only needed it for Export-PfxCertificate
    $cert | Remove-Item -ErrorAction SilentlyContinue
    Write-Host '  (Certificate removed from Windows store)'
}

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  NEXT STEPS' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '1. Open SystemInfo-GUI.ps1 and replace the two constants near the top:'
Write-Host ''
Write-Host '       $script:EmbeddedCertPem  <- paste all of systeminfo-qz.pem'
Write-Host '       $script:EmbeddedKeyPem   <- paste all of systeminfo-qz.key.pem'
Write-Host '   Include the -----BEGIN / -----END lines in each block.'
Write-Host ''
Write-Host '   Then recompile the exe.'
Write-Host ''
Write-Host '2. On the QZ Tray host machine, copy systeminfo-qz.pem into:'
Write-Host ''
Write-Host '       %APPDATA%\qz\certs\'
Write-Host ''
Write-Host '   (Create the folder if it does not exist.)'
Write-Host '   Then restart QZ Tray so it picks up the new certificate.'
Write-Host ''
Write-Host '3. On the first print from any laptop, QZ Tray may show a'
Write-Host '   one-time Allow / Block popup. Click Allow and tick'
Write-Host '   "Remember this decision" to silence it permanently.'
Write-Host ''
Write-Host '   To pre-approve silently for all machines: right-click the'
Write-Host '   QZ Tray system-tray icon -> Site Manager, find the cert,'
Write-Host '   and set it to "Allow" before distributing the exe.'
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Green
