<#
.SYNOPSIS
mssql database backup script
.DESCRIPTION
Create a backup for all databases in the sql instance specified.
Archive them with 7zip and remove any backup files older than X days.
.EXAMPLE
powershell backup.ps1 -BackupOptionsFilePath options.json
#>
[CmdletBinding()]
param
(
	[Parameter(Mandatory=$false)]
    [ValidateScript({
		if (-Not (test-path -path $_ -isvalid))
		{
			throw "Could not find options file in the following path: $($_)"
		}
		return $true
	})]
	[string]
	$BackupOptionsFilePath="./options.json",
	[Parameter(Mandatory=$false)]
	[ValidateScript({
		if (-Not (test-path -path $_ -isvalid))
		{
			throw "Could not find 7zip binary executable file in the following path: $($_)"
		}
		return $true
	})]
	[string]$7zipPath="$($env:ProgramFiles)\7-Zip\7z.exe"
)

Function Write-Log {
    [CmdletBinding()]
    Param(
    [Parameter(Mandatory=$True)]
    [string]
    $message,
    [Parameter(Mandatory=$False)]
    [string]
    $logfile
    )

    $line = "$(Get-Date -Format "yyyyMMddTHHmmss") $message"
    If($logfile) {
        Add-Content $logfile -Value $line
    }
    Else {
        Write-Output $line
    }
}

function New-LogFile {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
    	[string]
    	$Path
	)

	$logFile = New-Item -Path $path -Name "$(Get-Date -Format "yyyyMMddTHHmmss").log" -ItemType "file"
	return $logFile.FullName 
}

function Get-BackupOptions {
	param (
		[Parameter(Mandatory=$true)]
    	[string]
    	$Path
	)
	return (Get-Content $Path | ConvertFrom-Json)
}

## logs
$logFilePath = New-LogFile -Path "./logs/"
Write-Log "starting database backup script" $logFilePath

## parse json file and load the options

$options = Get-BackupOptions $logFilePath
$databaseServerName = $options.database_backup.servername
$databaseInstanceName = $options.database_backup.instance
$backupDirectory = $options.database_backup.backup_directory_path
$removeOlderThan = $options.database_backup.remove_backups_older_than
$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $options.email_credentials.username, (convertto-securestring $options.email_credentials.password -asplaintext -force) 
$smtp = $options.smtp_settings
Write-Log "parsed options.json file" $logFilePath

try
{
	Import-Module SQLPS -DisableNameChecking
    ## create backups
	$dbs = Get-ChildItem "SQLSERVER:\SQL\$($databaseServerName)\$($databaseInstanceName)\Databases" -ErrorAction Stop
	Set-Location "SQLSERVER:\SQL\$($databaseServerName)\$($databaseInstanceName)\Databases" -ErrorAction Stop
	Write-Log "exporting database instance $($databaseInstanceName) on server $($databaseServerName)" $logFilePath
    foreach ($db in $dbs)
    {
		$dbName = $db.Name
		$dbBackupFilePath = "$($backupDirectory)\$($dbName).bak"
		Write-Log "exporting database $($dbName) in $($backupDirectory) directory" $logFilePath
		Backup-SqlDatabase -Database $dbName -BackupAction Database -BackupFile $dbBackupFilePath -BackupSetDescription (Get-Date) -ErrorAction Stop
		Write-Log "successfully exported database $($dbName) in $($backupDirectory) directory" $logFilePath
    }

	## create archive file
	Write-Log "archiving database backups" $logFilePath
    Set-Location $backupDirectory
    Set-Alias 7zip $7zipPath
    7zip a "$($databaseServerName)_$(Get-Date -Format "yyyyMMddTHHmmssffff").7z" "$($backupDirectory)\*.bak" -t7z -mx=9 -sdel
    Write-Log "archive successfully created" $logFilePath
    ## remove old backups
	Get-ChildItem $backupDirectory -Recurse | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays($removeOlderThan) } | Remove-Item
	Write-Log "removing backups older than today $($removeOlderThan) days" $logFilePath
}
catch
{
	$ErrorMessage = $_.Exception.Message
    $FailedItem = $_.Exception.ItemName
	Write-Log "Failed to create database backup: $($ErrorMessage)" $logFilePath
	Send-MailMessage -from $creds.username -To $smtp.send_to `
		-Subject "Datenbank Backup fehlgeschlagen $($databaseServerName) $(Get-Date -Format 'dd/MM/yyyy')" `
		-SmtpServer $smtp.server_address `
		-Credential $creds `
		-Port $smtp.port `
		-Body "Datenbank Backup konnte nicht erstellt werden.`ndatabaseServerName: $($databaseServerName)`nInstanzname: $($databaseInstanceName)`nZeitpunkt: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')`n$($ErrorMessage)`n$($FailedItem)" `
		#-UseSsl
	break
}
