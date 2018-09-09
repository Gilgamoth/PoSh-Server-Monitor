# Daily Server Monitor
# Copyright (C) 2018 Steve Lunn (gilgamoth@gmail.com)
# Downloaded From: https://github.com/Gilgamoth

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see https://www.gnu.org/licenses/

Set-PSDebug -strict
$ErrorActionPreference = "SilentlyContinue"
Clear-Host

### Variables ###

#Servers in Downtime File
$Cfg_DowntimeFile = ".\downtime.txt"

# E-Mail Report Enabled - $true or $false
$Cfg_Email_Report = $true

# E-Mail Settings
$Cfg_Email_To_Address = "recipient@domain.local"
$Cfg_Email_From_Address = "Server Monitor <sender@domain.local>"
$Cfg_Email_Subject = "Server Monitor Results "
$Cfg_Email_Server = "mail.domain.local"
$Cfg_Smtp_User = ""
$Cfg_Smtp_Password = ""
$Cfg_Email_Body = ""

$ExcludedSvrs = ""
$Cfg_Check_Disk_Space = $true
$Cfg_Check_Services = $true
$Cfg_Check_Event_Logs = $true
$Cfg_Email_Report = $true

$Cfg_Warning_Count = 0
$Cfg_Critical_Count = 0
$Cfg_DiskPct_Warn = 10
$Cfg_DiskFree_Warn = 10
$Cfg_DiskPct_Crit = 5
$Cfg_DiskFree_Crit = 5

$StartTime = get-date

# *************************** FUNCTION SECTION ***************************

function fnc_ldap_query($strFilter, $strSearchRoot)
{
	#Function to return the name of all items that match the provided filter in the provided location
	$objDomain = New-Object System.DirectoryServices.DirectoryEntry

	$objSearcher = New-Object System.DirectoryServices.DirectorySearcher
	$objSearcher.SearchRoot = $objDomain
	$objSearcher.PageSize = 1000
	$objSearcher.Filter = $strFilter
	$objSearcher.SearchScope = "Subtree"
	$objSearcher.SearchRoot = $strSearchRoot
	$objSearcher.PropertiesToLoad.Add("name") > $null

	$colResults = $objSearcher.FindAll()

	foreach ($objResult in $colResults) {
		$objItem = $objResult.Properties
		$objItem.name
	}
}

# ****************************** CODE START ******************************

If ($Cfg_DowntimeFile) {
	# Check for servers in downtime
    If(Test-Path $Cfg_DowntimeFile) { 
		$ExcludedSvrs = Get-Content $Cfg_DowntimeFile
        If ($ExcludedSvrs -eq $null) {
            $ExcludedSvrs = ""
        }
	} Else {
		Write-Host "Error! " -NoNewline -ForegroundColor Red
		Write-Host "$Cfg_DowntimeFile not found but specified"
		Exit
	}
}

Write-host "Gathering Server List @" (get-date)
if ($args.count -eq 0)
{
	# Default OU for Servers in AD. Leave as "" if using the whole domain.
	#$Cfg_Server_OU = "LDAP://ou=OU, dc=Domain, dc=com"
	$Cfg_Server_OU = ""

	# LDAP Server Search Criteria - Required (Default Computer Accounts with Server in OS Name, and not disabled)
	$Cfg_Server_Search = "(&(&(objectCategory=Computer)(operatingSystem=*Server*))(!(useraccountcontrol:1.2.840.113556.1.4.803:=2)))"

	$server_list = fnc_ldap_query $Cfg_Server_Search $Cfg_Server_OU

} elseif ($args.count -eq 1) {

	$server_list = $args[0]

} else {

	write-host "Too Many Arguments"
	Exit
}

Write-Host "Processing Server List @" (get-date)
[Array]::Sort([array]$Server_List)
foreach ($Server_Name in $server_list) {
    $InDowntime=0
    Write-Host $Server_Name -NoNewline
	ForEach($ExcludedSvr in $ExcludedSvrs) {
		If ($Server_Name -eq $ExcludedSvr) {
		    Write-Host " In Downtime" -ForegroundColor Yellow
		    $Cfg_Email_Body += "<font color=Orange>$Server_Name is in Downtime</font><br><br>"
            $InDowntime=1
        }
	}
    if ($InDowntime -eq "0") {
		if ((Test-Connection $Server_Name -quiet)) {
			# Process Drive Details
			Write-Host " Is Active" -ForegroundColor Green
            Write-Host "- Processing Disks @" (get-date)
            $Cfg_Svr_Critical_Count = 0
            $Cfg_Svr_Warning_Count = 0
            $Cfg_Email_Body += "$Server_Name is <font color=green>Active</font><br>`n"
            $Cfg_Email_Body += "<TABLE BORDER=1>`n"

            if ($Cfg_Check_Disk_Space) {
                $Cfg_Email_Body += "<TR><TH><B>Drive</B></TH><TH WIDTH=250><B>Vol Name</B></TH><TH><B>Size (GB)</B></TH><TH><B>Free (GB)</B></TH><TH><B>Free (%age)</B></TH></TR>`n"

                $DrivesList = Get-WmiObject Win32_LogicalDisk -ComputerName $Server_Name | Where-Object {$_.DriveType -eq 3} | Select-Object Name, VolumeName, Size, FreeSpace
                ForEach($Drive in $DrivesList) {
                    $DriveName = $Drive.Name
                    $DriveVName =  $Drive.VolumeName
                    $DriveSize = "{0:N0}" -f ($Drive.Size /1Gb)
                    $DriveFree = "{0:N0}" -f ($Drive.FreeSpace /1Gb)
                    [int]$DrivePct = "{0:N0}" -f (($DriveFree / $DriveSize) *100)

                    Write-Host "-- $DriveName $DriveVName $DriveSize $DriveFree " -NoNewline
                    $Cfg_Email_Body += "<TR><TD>$DriveName</TD><TD>$DriveVName</TD><TD ALIGN=RIGHT>$DriveSize</TD><TD ALIGN=RIGHT>$DriveFree</TD><TD ALIGN=RIGHT>"
                    If ($DrivePct -lt $Cfg_DiskPct_Crit -and [int]$DriveFree -lt $Cfg_DiskFree_Crit) {
                        #Less than 10% AND less than 5Gb - Red
                        $Cfg_Email_Body += "<font color=`"#FF0000`">$DrivePct</font>"
                        Write-Host "$DrivePct" -ForegroundColor Red
                        $Cfg_Svr_Critical_Count += 1 
                        $Cfg_Critical_Count += 1 
                    } elseif ($DrivePct -le $Cfg_DiskPct_Warn -and [int]$DriveFree -le $Cfg_DiskFree_Warn) {
                        #Less than 20% AND less than 10Gb - Orange
                        $Cfg_Email_Body += "<font color=`"#FF6600`">$DrivePct</font>"
                        Write-Host "$DrivePct" -ForegroundColor Red
                        $Cfg_Svr_Warning_Count += 1
                        $Cfg_Warning_Count += 1
                    } else {
                        #Green
                        $Cfg_Email_Body += "<font color=`"#009933`">$DrivePct</font>"
                        Write-Host "$DrivePct" -ForegroundColor Green
                    }
                    $Cfg_Email_Body += "%</TD></TR>`n"
                }
            }

            # Process Services
            if ($Cfg_Check_Services) {
                Write-Host "- Processing Services @" (get-date)
                $ServicesList = Get-Service -ComputerName $Server_Name -Exclude "RemoteRegistry", "sppsvc", "ShellHWDetection", "dbupdate", "gupdate", "wbiosrvc", "clr_optim*", "wuauserv" | Where-Object {($_.StartType -eq "Automatic") -and ($_.Status -eq "Stopped")}
				if ($ServicesList.Count -gt 0) {
					$Cfg_Warning_Count += $ServicesList.Count
					$Cfg_Email_Body += "<TR><TD COLSPAN=5><TABLE BORDER=0><TR><TH>Service</TH><TH>Start Mode</TH><TH>State</TH></TR>"
					foreach ($Service in $ServicesList) {
						$SvcDisplayName = $Service.DisplayName
						$SvcStartMode = $Service.StartType
						$SvcState = $Service.Status
                        Write-Host "---$SvcDisplayName $SvcStartMode $SvcState"
						$Cfg_Email_Body +=  "<TR><TD>$SvcDisplayName</TD><TD>$SvcStartMode</TD><TD><font color=`"#FF0000`">$SvcState</font></TD></TR>"				
					}
					$Cfg_Email_Body += "</TABLE></TD></TR>"
					#$ServicesList | Format-Table DisplayName, StartType, Status -AutoSize
				} else {
                    $Cfg_Email_Body += "<TR><TD COLSPAN=5><font color=`"#009933`">All Automatic Services Are Running</font></TD></TR>`n"
                }
            }

            # Process Event Logs
            # $Events = Get-EventLog -LogName Application -EntryType Error -After (Get-Date).AddHours(-24) -ComputerName $Server_Name
            # $Events += Get-EventLog -LogName System -EntryType Error -After (Get-Date).AddHours(-24) -ComputerName $Server_Name
            # $Events | group-object -property source -noelement | sort-object -property count �descending
            
            if ($Cfg_Check_Event_Logs) {
                $AppLog = $null
                $SystemLog = $null
                $ECount=0
                Write-Host "- Processing Event Logs"
                $Yesterday = (Get-Date).AddDays(-1)
                Write-Host "-- Accessing Application Log @" (get-date)
                $AppLog = Get-EventLog -ComputerName $Server_Name -After $Yesterday -LogName Application -EntryType Error, Warning | ?{@("12014","12017","12018") -notcontains $_.EventID}
                $AppLog = $AppLog.GetEnumerator() | sort -Property Index
                Write-Host "-- Accessing System Log @" (get-date)
                $SystemLog = Get-EventLog -ComputerName $Server_Name -After $Yesterday -LogName System -EntryType Error, Warning | ?{@("10016","36874","36887") -notcontains $_.EventID}
                $SystemLog = $SystemLog.GetEnumerator() | sort -Property Index
                If ($AppLog.Count -gt 0 -OR $SystemLog.Count -gt 0) {
                    $ECount = $AppLog.Count + $SystemLog.Count
                    $Cfg_Svr_Warning_Count = $Cfg_Svr_Warning_Count + $ECount
                    $Cfg_Warning_Count += 1
                    $Cfg_Email_Body += "<TR><TD COLSPAN=5><TABLE BORDER=0 WIDTH=100%>`n"
                    $Cfg_Email_Body += "<TR><TH>Log</TH><TH>Time</TH><TH>Type</TH><TH>Source</TH><TH>Event ID</TH></TR>`n"
                    #$LogAnalysis = $Events | group-object -property source -noelement | sort-object -property count -descending
                    Write-Host "-- Processing Application Log @" (get-date)
                    ForEach($Event in $AppLog) {
                        $ETime = $Event.TimeGenerated
                        $EType = $Event.EntryType
                        $ESource = $Event.Source
                        $EID = $Event.EventID
                        Write-Host "--- $ETime, $EType, $ESource, $EID"
                        $Cfg_Email_Body += "<TR><TD>Application</TD><TD>" + "{0:dd-MM-yyyy HH:mm:ss}" -f $ETime + "</TD><TD>$EType</TD><TD>$ESource</TD><TD>$EID</TD></TR>`n"
                    }
                    Write-Host "-- Processing System Log @" (get-date)
					If ($AppLog.Count -gt 0 -AND $SystemLog.Count -gt 0) {
					$Cfg_Email_Body += "<TR><TD COLSPAN=5><HR WIDTH=90% ALIGN=CENTER></TD></TR>`n"
					}
                    ForEach($Event in $SystemLog) {
                        $ETime = $Event.TimeGenerated
                        $EType = $Event.EntryType
                        $ESource = $Event.Source
                        $EID = $Event.EventID
                        Write-Host "--- $ETime, $EType, $ESource, $EID"
                        $Cfg_Email_Body += "<TR><TD>System</TD><TD>" + "{0:dd-MM-yyyy HH:mm:ss}" -f $ETime + "</TD><TD>$EType</TD><TD>$ESource</TD><TD>$EID</TD></TR>`n"
                    }
                    $Cfg_Email_Body +=  "</TABLE><br>`n"
                } else {
                    $Cfg_Email_Body += "<TR><TD COLSPAN=5><font color=`"#009933`">No Errors or Warnings Found in Event Log</font></TD></TR>`n"
                }

            }

            if ($Cfg_Svr_Critical_Count -gt 0 ) {
                Write-Host "- Server has $Cfg_Svr_Critical_Count Critical Issue(s)"
                $Cfg_Email_Body += "<TR><TD COLSPAN=5><font color=`"#FF0000`">$Server_Name has $Cfg_Svr_Critical_Count Critical Issue(s)</font></TD></TR>`n"
            } elseif ($Cfg_Svr_Warning_Count -gt 0 ) {
                Write-Host "- Server has $Cfg_Svr_Warning_Count Warning Issue(s)"
                $Cfg_Email_Body += "<TR><TD COLSPAN=5><font color=`"#FF6600`">$Server_Name has $Cfg_Svr_Warning_Count Warning Issue(s)</font></TD></TR>`n"
            } else {
                Write-Host "- Server has no issues"
                $Cfg_Email_Body += "<TR><TD COLSPAN=5><font color=`"#009933`">$Server_Name has no issues</font></TD></TR>`n"
            }
            
            $Cfg_Email_Body +=  "</TABLE><br>`n"
		} Else {
			$Cfg_Email_Body +=  "$Server_Name is <font color=red>Not Responding</font><br>`n<br>`n"
			Write-Host " is Down" -ForegroundColor Red
            $Cfg_Critical_Count += 1
		}
            
	}

}

$EndTime = get-date
$RunTime = $EndTime - $StartTime
$FormatTime = "{0:N2}" -f $RunTime.TotalMinutes

Write-Host "Job took $FormatTime minutes to run"
$Cfg_Email_Body +=  "Start Time: " + "{0:dd-MM-yyyy HH:mm:ss}" -f $StartTime + "<BR>`n"
$Cfg_Email_Body +=  "End Time: " + "{0:dd-MM-yyyy HH:mm:ss}" -f $EndTime + "<BR>`n"
$Cfg_Email_Body +=  "Run Time: $FormatTime minutes<BR>`n"

if ($Cfg_Email_Report) {
    $smtp = New-Object System.Net.Mail.SmtpClient -argumentList $Cfg_Email_Server
    if ($Cfg_Smtp_User -ne "") { $smtp.Credentials = New-Object System.Net.NetworkCredential -argumentList $Cfg_Smtp_User,$Cfg_Smtp_Password }
    $message = New-Object System.Net.Mail.MailMessage
    $message.From = New-Object System.Net.Mail.MailAddress($Cfg_Email_From_Address)
    $message.To.Add($Cfg_Email_To_Address)
    $message.Subject = $Cfg_Email_Subject + (get-date).ToString("dd/MM/yyyy") + " - " + $Server_list.count + " Checked, " + $Cfg_Critical_Count + " Critical, " + $Cfg_Warning_Count + " Warning - "
    $message.isBodyHtml = $true
    $message.Body = $Cfg_Email_Body

    $smtp.Send($message)
}
