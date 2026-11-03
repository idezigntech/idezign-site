# unpack.ps1 - bundled inside iDezign-Toolkit.exe (NSIS) and run from its temp dir.
# Decrypts payload.bin (see .github/scripts/encrypt-payload.py) with the
# password the user typed, which NSIS passes in the IDZ_PW environment
# variable (never on the command line).
#
# Exit codes: 0 ok | 2 wrong password | 3 no password | 4 bad payload | 5 other error
# Windows PowerShell 5.1 compatible, ASCII only.
param(
    [Parameter(Mandatory=$true)][string]$Payload,
    [string]$Dest,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
try {
    $pw = $env:IDZ_PW
    if ([string]::IsNullOrEmpty($pw)) { exit 3 }

    $b = [IO.File]::ReadAllBytes($Payload)
    if ($b.Length -lt 84 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'IDZ1') { exit 4 }

    $salt = New-Object byte[] 16; [Array]::Copy($b, 4,  $salt, 0, 16)
    $iv   = New-Object byte[] 16; [Array]::Copy($b, 20, $iv,   0, 16)
    $tag  = New-Object byte[] 32; [Array]::Copy($b, 36, $tag,  0, 32)
    $ct   = New-Object byte[] ($b.Length - 68); [Array]::Copy($b, 68, $ct, 0, $ct.Length)

    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $k = $kdf.GetBytes(64)
    $ek = New-Object byte[] 32; [Array]::Copy($k, 0,  $ek, 0, 32)
    $mk = New-Object byte[] 32; [Array]::Copy($k, 32, $mk, 0, 32)

    $h = New-Object Security.Cryptography.HMACSHA256 (,$mk)
    [void]$h.TransformBlock($iv, 0, 16, $null, 0)
    [void]$h.TransformFinalBlock($ct, 0, $ct.Length)
    $calc = $h.Hash
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $tag[$i]) }
    if ($diff -ne 0) { exit 2 }
    if ($CheckOnly) { exit 0 }

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $ek; $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)

    $tmp = Join-Path $env:TEMP ("idz_" + [Guid]::NewGuid().ToString('N') + ".zip")
    [IO.File]::WriteAllBytes($tmp, $plain)
    try {
        if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
        Expand-Archive -Path $tmp -DestinationPath $Dest -Force
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    exit 0
} catch {
    exit 5
}
