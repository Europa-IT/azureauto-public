# Standalone script for enrollment reg key removal.

Write-Host "Removing any existing enrollment information."

$EnrollmentsPath = "HKLM:\SOFTWARE\Microsoft\Enrollments\"
$Enrollments = Get-ChildItem -Path $EnrollmentsPath
$UrlsFile = "$PSScriptRoot\..\config\enrollmenturls.txt"
if (Test-Path $UrlsFile) {
    $DiscoveryServerFullUrls = Get-Content $UrlsFile | Where-Object { $_ -match "^https?://" }
} else {
    $DiscoveryServerFullUrls = @("https://wip.mam.manage.microsoft.com/Enroll")
}

$RemovedCount = 0

try {

    foreach ( $Enrollment in $Enrollments ) {

        try {
            $EnrollmentObject = Get-ItemProperty Registry::$Enrollment -ErrorAction Stop
        } catch {
            Write-Host "Failed to read enrollment key $Enrollment, skipping."
            continue
        }
        $EnrollmentPath = $EnrollmentsPath + $EnrollmentObject.PSChildName

        if ( $EnrollmentObject."DiscoveryServiceFullURL" -in $DiscoveryServerFullUrls ) {
            Remove-Item -Path $EnrollmentPath -Recurse -ErrorAction Stop
            $RemovedCount++
        } elseif ( $EnrollmentObject.PSChildName -match "^[A-f0-9]{8}(-[A-f0-9]{4}){3}-[A-f0-9]{12}$") {
            try {
                Remove-Item -Path $EnrollmentPath -Recurse -ErrorAction Stop
                $RemovedCount++
            } catch {
                Write-Host "Failed to remove key $EnrollmentPath, continuing."
            }
        }
    }
} catch {
    Throw "Failure removing enrollment registry keys. Try again after running Remove-EnrollmentKeys.ps1 with admin rights."
}

Write-Host "Enrollment key removal complete. Removed $RemovedCount of $($Enrollments.Count) key(s)."
