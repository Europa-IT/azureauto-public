Invoke-WmiMethod -Class win32_OfflineFilesCache -Name Enable -ArgumentList $false | Out-Null
return [PSCustomObject]@{ RebootRequired = $true }
