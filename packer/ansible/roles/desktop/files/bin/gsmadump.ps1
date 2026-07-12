Import-Module ActiveDirectory

$gMSAName = Read-Host -Prompt "Please enter the gMSA name"

$gMSA = Get-ADServiceAccount -Identity $gMSAName -Properties msDS-ManagedPassword

if ($gMSA) {
    $managedPasswordBlob = $gMSA."msDS-ManagedPassword"
    $base64Blob = [Convert]::ToBase64String($managedPasswordBlob)

    Write-Output "Managed Password Blob (Base64): $base64Blob"
} else {
    Write-Output "gMSA account '$gMSAName' not found."
}

