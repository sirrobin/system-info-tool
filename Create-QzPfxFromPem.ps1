#Requires -Version 7.1
<#
.SYNOPSIS
    Creates a PFX from the InventoryApp PEM certificate + private key so that
    SystemInfo-GUI can authenticate with QZ Tray using the same identity that
    the web app already has permission to print with.

.DESCRIPTION
    Run once with PowerShell 7 (pwsh.exe).  Produces:
        inventory-qz.pfx           — PFX file (password protected)
        inventory-qz.pfxb64.txt    — Base64 of the PFX — paste this into
                                      $script:EmbeddedPfxBase64 in SystemInfo-GUI.ps1

    The certificate and private key below come directly from the InventoryApp
    web app source (app.js: QZ_CERT and QZ_PRIVATE_KEY constants).
    Do NOT change them — they must match what is already trusted in QZ Tray.
#>

$ErrorActionPreference = 'Stop'

# ── Paste the QZ_CERT constant from app.js here ──────────────────────────────
$CertPem = @"
-----BEGIN CERTIFICATE-----
MIIDPTCCAiWgAwIBAgIUckgdA5kfEaoSi9yj52gWjtMf/IswDQYJKoZIhvcNAQEL
BQAwLjEVMBMGA1UEAwwMSW52ZW50b3J5QXBwMRUwEwYDVQQKDAxJbnZlbnRvcnlB
cHAwHhcNMjYwNTEwMDUyODA3WhcNMzYwNTA3MDUyODA3WjAuMRUwEwYDVQQDDAxJ
bnZlbnRvcnlBcHAxFTATBgNVBAoMDEludmVudG9yeUFwcDCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBANkD4QYiHlvF9qgtn3UGd9EJFDEg756/JNWDpyT3
3iqtXKZgFoIKHco2Ts6NxOURYoW4K2sqvfOBbQu0miuR4VC6f7Oq9ucMSCb/CJv1
sbf6WIQgToQovnG10kEzQ0TbZN5QJj+GIKZiEcrnTrjjW2bYRS7qV37nXGG0ceS+
hnG2y8aFXE3tnpns0O5V1MVTurve8yFmuWyyrlpsVpPW1Z/0lbsOqSZMWtZVpEwV
cHzGUcImFqUMp3GF75KiQ5qZyFibu9+uWvfhMm+ED02rJ7ThurFYljin9imG+0TU
Bo4E0xhAcMzywrJBwA1eRRhs1kAi3vKROBsYMUVv4QYGJqMCAwEAAaNTMFEwHQYD
VR0OBBYEFAbFf1XPj3z5AVLrArj2Q4lkR4N6MB8GA1UdIwQYMBaAFAbFf1XPj3z5
AVLrArj2Q4lkR4N6MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEB
ALvsBXOWj43IfrS7lZ48vbYGYH1BpcyNvgEFH7BZv5+ooYbvS60AqYeVz//1cYmI
pBg3hGfPcUNsHbgBbWceKiBB/v/gp5I0ZqiDsVNU43Zg1W1yk2nMFoI+GJn8htOy
SyjSVGafzNLYOYHtecqg8l1U8un/zBHG9XesoR3H+zLrlOfilelOmDXLBrtDylvt
ZaObhnz0oYENT89/t79yTeURqSL2k0EbJB43HbQgyqIGFnEYWE9p1CWDX6Bpt/3/
Hc4hRGlSpWBxzt7PsR3K2UaiyIb6RbeUjCfBR0AkpPkSP5vlBxc/X/RuMmsu+zIX
rtJrOOdH+seU2Zdqccv68ts=
-----END CERTIFICATE-----
"@

# ── Paste the QZ_PRIVATE_KEY constant from app.js here ───────────────────────
$KeyPem = @"
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDZA+EGIh5bxfao
LZ91BnfRCRQxIO+evyTVg6ck994qrVymYBaCCh3KNk7OjcTlEWKFuCtrKr3zgW0L
tJorkeFQun+zqvbnDEgm/wib9bG3+liEIE6EKL5xtdJBM0NE22TeUCY/hiCmYhHK
506441tm2EUu6ld+51xhtHHkvoZxtsvGhVxN7Z6Z7NDuVdTFU7q73vMhZrlssq5a
bFaT1tWf9JW7DqkmTFrWVaRMFXB8xlHCJhalDKdxhe+SokOamchYm7vfrlr34TJv
hA9Nqye04bqxWJY4p/YphvtE1AaOBNMYQHDM8sKyQcANXkUYbNZAIt7ykTgbGDFF
b+EGBiajAgMBAAECggEAHuyxlUkpYFSOeJq/vVJlopETooiZ/NoqKo7vM5Jqw1Qe
/sp0iqVcZ2NjyYVkSGw4yOtcrJHTra6E1oUu7wSDwhhBeF3lfzk90ujG1kqlv5za
HkHoTmbr9JI/WvEuJdLJxfBP8v9vCaax+GML0cb8UGSDP1M/kqLvhDDNhhYsXGm3
zZLtezh9zngE2WXBbeSGzx7ZhaFDu0O2IpvA6mC/nIqloRyXADW3LCMfMD+CWbyB
Drd7a5M4vJEI+M6TSRy90VboU1ItFQ4dz4plEOl+EbJyPJJWZ+QJ/3o8OCwwkVCg
7wZTtIQ+RikO+wtC/e0fjtvQKSrYtcx39sopm+KSOQKBgQD4VKQttAR5kFQCHP1e
H0mb48+UywYrcPvzC1rxSnJwJxVq/hLq9BqyU3nRs3dgMCboM98EcSZ1bbABgB/D
3p1A80nU9aNO+8SnfkL65A6aPXwIGSROY9UAWKVFysvDgt689bTLTe78bsx1H5oF
rsr9qU0C/gy2d/OqOo8wXfi7bwKBgQDft6Z92FQT7vwVzaDc9aUdnsBEeY1yCTc6
U7QgO4DnssI3G4xrhvWdmvIZgCyd4AxMVB9D5iQxTt5NonZTVedXZTC+JXxiU3fF
+D0Wn98xBzapHAo0MrmieDKcHAaKxEiXXUEz/NY/vfr6D48RTPTIAWcdTkOZKpuH
eVgj7Bx+DQKBgQCP6Z1rzxN4z6efweUjksY5zYATHsVoj4WziDUf+KDxVfUXmD6m
YujFx5KlcHgSClXB462vCVPcYcDKXdIK1QwVA+kZvXDy6P1Cg+2VMG01/cPPfaKI
u1pJZRYCqFAF8eXbZBluaK/DIwLiLXo5KN8CugajYU9Ev6c6U81/njXziQKBgGnU
/DsOSn//j1tVImNFBa5kejoqcoJe37SFAnI5E/sH8p6VNrFrb+f188+idfjdk5PM
O9ooFjkJQVriny0/Nyh94zggjZ4KNF//1g5M5Q3RhscrT5xv3qeASxjUnTeqMVkB
saXBVy1iV0dScvDRQf8Xwsr3Sj08DcVh3xNnT/dFAoGBAOTB3Sz7jaoU91Vhjr5F
EGsBKxowCDKnizvqbqRnFC13HNBsxQd4yfz2AmfP0ByORx9yS3/DSLdkk9MYCLqH
LkVHKeHYQ6ws89h+3KZoK1K+k8b1z8H4BRwCsqm9v06ZnWbiqWQuNVNHnubpZqEa
tWoDBwCEl7RDj2VYjBhTbgLZ
-----END PRIVATE KEY-----
"@

$PfxPassword = 'InventoryApp2024!'   # paste this into $script:PfxPassword
$outDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $outDir) { $outDir = (Get-Location).Path }

Write-Host 'Creating X509Certificate2 from PEM cert + private key...' -ForegroundColor Cyan

# X509Certificate2.CreateFromPem requires .NET 5+ / PowerShell 7.1+
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
            $CertPem, $KeyPem)

$pfxBytes = $cert.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
    $PfxPassword)

$pfxPath = Join-Path $outDir 'inventory-qz.pfx'
[System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes)
Write-Host "  PFX  -> $pfxPath"

$b64 = [Convert]::ToBase64String($pfxBytes)
$b64Path = Join-Path $outDir 'inventory-qz.pfxb64.txt'
[System.IO.File]::WriteAllText($b64Path, $b64, [System.Text.Encoding]::ASCII)
Write-Host "  B64  -> $b64Path"

Write-Host ''
Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  NEXT STEPS' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '1. Open SystemInfo-GUI.ps1 and replace the two constants:'
Write-Host ''
Write-Host "       `$script:EmbeddedPfxBase64 = '<contents of inventory-qz.pfxb64.txt>'"
Write-Host "       `$script:PfxPassword       = '$PfxPassword'"
Write-Host ''
Write-Host '2. Recompile:'
Write-Host '       Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole -requireAdmin'
Write-Host ''
Write-Host '   No QZ Tray changes needed — InventoryApp is already trusted.'
Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Green
