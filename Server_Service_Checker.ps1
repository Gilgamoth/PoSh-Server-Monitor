# Hourly Server Monitor
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
$ExcludedSvrs = ""

# E-Mail Report Enabled - $true or $false
$Cfg_Email_Report = $true

# E-Mail Settings
$Cfg_Email_To_Address = "recipient@domain.local"
$Cfg_Email_From_Address = "Service Checker <sender@domain.local>"
$Cfg_Email_Subject = "Server Service Checker"
$Cfg_Email_Server = "mail.domain.local"
$Cfg_Email_Body = ""

$Cfg_Failed_Count = 0

$ExcludedServices = @("RemoteRegistry", "sppsvc", "ShellHWDetection", "dbupdate", "gupdate", "wbiosrvc", "clr_optim*", "wuauserv", "MSExchangeNotificationsBroker")

### Functions ###

$StartTime = get-date

function fnc_ldap_query($strFilter, $strSearchRoot) {
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

### Main Code ###

If ($Cfg_DowntimeFile) {
    If (Test-Path $Cfg_DowntimeFile) { 
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

if ($args.count -eq 0) {
    # Default OU for Servers in AD. Leave as "" if using the whole domain.
    #$Cfg_Server_OU = "LDAP://ou=OU, dc=Domain, dc=com"
    $Cfg_Server_OU = ""

    # LDAP Server Search Criteria - Required
    $Cfg_Server_Search = "(&(&(objectCategory=Computer)(operatingSystem=*Server*))(!(useraccountcontrol:1.2.840.113556.1.4.803:=2)))"

    $server_list = fnc_ldap_query $Cfg_Server_Search $Cfg_Server_OU

} elseif ($args.count -eq 1) {

    $server_list = $args[0]

} else {

    write-host "Too Many Arguments"
    Exit
}

[Array]::Sort([array]$Server_List)
foreach ($Server_Name in $server_list) {
    $InDowntime = 0
    Write-Host $Server_Name -NoNewline
    ForEach ($ExcludedSvr in $ExcludedSvrs) {
        If ($Server_Name -eq $ExcludedSvr) {
            Write-Host " In Downtime" -ForegroundColor Yellow
            $Cfg_Email_Body += "<font color=Yellow>$Server_Name is in Downtime</font><br>"
            $InDowntime = 1
        }
    }
    if ($InDowntime -eq "0") {
        if ((Test-Connection $Server_Name -quiet)) {
            $Cfg_Email_Body += "<font color=green>$Server_Name</font><br>"
            Write-Host " is Up" -ForegroundColor Green -NoNewLine
            Write-Host " - Getting Services" -NoNewLine
            $ServicesList = Get-Service -ComputerName $Server_Name -Exclude $ExcludedServices | Where-Object {($_.StartType -eq "Automatic") -and ($_.Status -eq "Stopped")}
            Write-Host " - Checking" -NoNewLine
            if ($ServicesList.count -gt 0) {
                $Cfg_Email_Body += "<TABLE BORDER=1><TR><TH>Service</TH><TH>Start Mode</TH><TH>State</TH></TR>"
                foreach ($Service in $ServicesList) {
                    $SvcDisplayName = $Service.DisplayName
                    $SvcStartMode = $Service.StartMode
                    Get-Service -ComputerName $Server_Name -Name $Service.DisplayName | Start-Service
                    Write-Host " - Starting" $Service.DisplayName -NoNewLine
                    Start-Sleep -Seconds 15
                    $SvcNewStatus = Get-Service -ComputerName $Server_Name -Name $Service.DisplayName
                    if ($SvcNewStatus.Status -eq "Running") {
                        $SvcState = "Started"
                    }
                    else {
                        $Cfg_Failed_Count += 1
                        $SvcState = $SvcNewStatus.Status
                    }
                    Write-Host " - Service" $SvcNewStatus.Status -NoNewline
                    $Cfg_Email_Body += "<TR><TD>$SvcDisplayName</TD><TD>$SvcStartMode</TD><TD>$SvcState</TD></TR>"				
                }
                $Cfg_Email_Body += "</TABLE>"
                #$ServicesList | Format-Table * -AutoSize
            }
            Write-Host " - Check Complete"
        }
        else {
            $Cfg_Failed_Count += 1
            $Cfg_Email_Body += "<font color=red>$Server_Name is not responding</font><br>"
            Write-Host " is Down" -ForegroundColor Red
        }
    }

}

$EndTime = get-date
$RunTime = $EndTime - $StartTime
$FormatTime = "{0:N2}" -f $RunTime.TotalMinutes

Write-Host "Job took $FormatTime minutes to run"

$smtp = New-Object System.Net.Mail.SmtpClient -argumentList $Cfg_Email_Server
if ($smtpUser -ne "") { $smtp.Credentials = New-Object System.Net.NetworkCredential -argumentList $smtpUser,$smtpPassword }
$message = New-Object System.Net.Mail.MailMessage
$message.From = New-Object System.Net.Mail.MailAddress($Cfg_Email_From_Address)
$message.To.Add($Cfg_Email_To_Address)
$message.Subject = $Cfg_Email_Subject + " " + (get-date).ToString("dd/MM/yyyy") + " - $Cfg_Failed_Count Service Warnings"
$message.isBodyHtml = $true
$message.Body = $Cfg_Email_Body
if ($Cfg_Failed_Count -gt 0 -and $Cfg_Email_Report) {
    $smtp.Send($message)
}
