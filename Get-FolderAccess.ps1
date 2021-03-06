# Best to run as admin account or you might get "Attempted to perform an unauthorized operation" on folders you can't access.
# Depth 0 = only specified folder. # This used to be set to folder and recurse all subs
# Depth 1-6 = works for folder and it's children
# Filters groups by regex on name, not by "if it found a group then exclude it"
# Does not tell you if the permission is inherited or explicit
# 
# -Path            = 'c:\temp' | 'r:\' | '\\server\share'
# -Depth           = folder recurse depth. max is 6
# -ExpandGroups    = get all nested members of AD groups. then does not show group names
# -ShowAllAccounts = include builtin accounts and AD groups. for use with ExpandGroups
# -ReportFormat    = creates report in HTML or EXCEL format
# -DontOpen        = does not open report file after creation
# -Rights          = allows regex filter on access rights (ex:'readonly') # Doesn't work for some reason?
# 
# EXAMPLES:
# Get-FolderAccess -Path 'c:\temp\scripts'
# Get-FolderAccess -Path 'c:\temp' -ExpandGroups -ShowAllAccounts -Depth 0 -ReportFormat HTML
# Get-FolderAccess -Path 'c:\temp' -Depth 0 -ReportFormat HTML
# 
# RETURNS
# if ReportFormat is Console (default) it outputs an object to the console window
# if ReportFormat is either HTML or Excel, it returns the path to the created report
# 
# TODO:
# fix the -rights parameter
# include email (maybe...)
# include folder browser dialogue for chosing where to save the report (maybe...)

function Get-FolderAccess {
    [CmdletBinding()]
    param (
        [string]$Path = $PWD,
        [int]$Depth = 1,
        [switch]$ExpandGroups = $false,
        [switch]$ShowAllAccounts = $false,
        [switch]$DontOpen = $false,
        [ValidateSet('Console','HTML','Excel')]
        $ReportFormat = 'Console',
        [string]$Rights
    )

function Get-FolderACL ([string]$Folder, [string]$Filter) {

    $CurrentACL = Get-Acl $Folder
    # could make hashtable of all current identities and exclude those from the output
    # or just filter out what i don't want (builtin, nt authority, etc...)
    # don't need because of later filtering
    # $CurrentACL.Access | % {$CurrentACL.RemoveAccessRule($_) | Out-Null} # does absolutely nothing??? :'( T_T
	$root = Split-Path $Folder -Leaf

#!#
#Write-Host "Folder: $root"
#!#

	(Get-Acl $Folder).Access |
		Where-Object {
            $(if ($Filter) {$_.FileSystemRights.ToString() -match $Filter} else {$true}) -and
            $_.IdentityReference.ToString() -match "^$domain\\" -and
            $_.FileSystemRights -notmatch '\d{6}' -and
            $_.IdentityReference.ToString() -notmatch '\d{6}' #-and
            #$_.IdentityReference.ToString() -notmatch '^Everyone$' -and
            #$_.IdentityReference.ToString() -notmatch '^BUILTIN\\' -and
            #$_.IdentityReference.ToString() -notmatch '^NT AUTHORITY\\' -and
            #$_.IdentityReference.ToString() -notmatch '^CREATOR$' -and
        } |
    Select-Object `
      @{Name = 'Folder'; Expression = {$root}},
			@{Name = 'UserAccount'; Expression = {$_.IdentityReference.ToString().Substring($_.IdentityReference.ToString().IndexOf('\') + 1)}},
      @{n='IdentityReference';e={$_.IdentityReference.ToString()}},
			FileSystemRights,
        InheritanceFlags, # retunrs "Read, Write" may need to remove space
        PropagationFlags,
        AccessControlType |
        ForEach-Object {
          # $IdentityReference = $_.IdentityReference
          $FileSystemRights  = $_.FileSystemRights  #* $FileSystemRights  = $access.FileSystemRights
          $InheritanceFlags  = $_.InheritanceFlags  #* $InheritanceFlags  = $access.InheritanceFlags
          $PropagationFlags  = $_.PropagationFlags  #* $PropagationFlags  = $access.PropagationFlags
          $AccessControlType = $_.AccessControlType #* $AccessControlType = $access.AccessControlType
          # if ((([adsi]"LDAP://$_").userAccountControl[0] -band 2) -ne 0) {account is disabled}
          $dn = $(([adsisearcher]"samaccountname=$($_.UserAccount)").FindOne().Path.Substring(7))
          Get-Member $dn |
            Where-Object {
              $_ -notmatch '-\d{10}-' -and
              $_ -notmatch '-svc-' ########################
            } |
            ForEach-Object {
              #* $IdentityReference = ([adsi]"LDAP://$obj").samaccountname
              $IdentityReference = ([adsi]"LDAP://$_").samaccountname
              $CurrentACLPermission = $IdentityReference,$FileSystemRights,$InheritanceFlags,$PropagationFlags,$AccessControlType
              try {
                $CurrentAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $CurrentACLPermission
                $CurrentACL.AddAccessRule($CurrentAccessRule)
              } catch [system.exception] {
                Write-Host "Error: `$CurrentAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $CurrentACLPermission" -ForegroundColor Red
                "Error: `$CurrentAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $CurrentACLPermission" >> $logFile
              }
            }
        }
  $CurrentACL
}

function Get-Member ($GroupName) {
  $Grouppath = "LDAP://" + $GroupName
  $GroupObj = [ADSI]$Grouppath

#!#
#Write-Host "    Group:"$GroupObj.cn.ToString()
#!#

  $users = foreach ($member in $GroupObj.Member) {
    $UserPath = "LDAP://" + $member
    $UserObj = [ADSI]$UserPath
    if ($UserObj.groupType.Value -eq $null) { # if this is NOT a group (it's a user) then...

#!#
#Write-Host "        Member:"$UserObj.cn.ToString()
#!#

      $member
    } else { # this is a group. redo loop.
      Get-Member($member)
    }
  }
  $users | select -Unique
}

function acltohtml ($Path, $colACLs, $ShowAllAccounts) {
$saveDir = "$env:TEMP\Network Access"
if (!(Test-Path $saveDir)) {mkdir "$saveDir\Logs" | Out-Null}
$time = Get-Date -Format 'yyyyMMddHHmmss'
$saveName = "Network Access $time"
$report = "$saveDir\$saveName.html"
'' > $report

#region Function definitions
function drawDirectory([ref] $directory) {
    $dirHTML = '
        <div class="'
            if ($directory.value.level -eq 0) { $dirHTML += 'he0_expanded' } else { $dirHTML += 'he' + $directory.value.level }
            $dirHTML += '"><span class="sectionTitle" tabindex="0">Folder ' + $directory.value.Folder.FullName + '</span></div>
						<div class="container">
                        <div class="he4i">
                                <div class="heACL">
                                        <table class="info3" cellpadding="0" cellspacing="0">
                                                <thead>
                                                        <th scope="col"><b>Owner</b></th>
                                                </thead>
                                                <tbody>'
            foreach ($itemACL in $directory.value.ACL) {
                    $acls = $null
                    if ($itemACL.AccessToString -ne $null) {
                        # select -u because duplicates if inherited and not
                        $acls = $itemACL.AccessToString.split("`n") | select -Unique | ? {$_ -notmatch '  -\d{9}$'} | sort
                    }
                    $dirHTML += '<tr><td>' + $itemACL.Owner + '</td></tr>
                        <tr>
                        <td>
                        <table>
                                <thead>
                                        <th>User</th>
                                        <th>Control</th>
                                        <th>Privilege</th>
                                </thead>
                                <tbody>'
                    foreach ($acl in $acls) {
                            #$temp = [regex]::split($acl, '(?<!(,|NT))\s+')
                            $temp = [regex]::split($acl, '\s+(?=Allow|Deny)|(?<=Allow|Deny)\s+')  
                            if ($debug) {
                                write-host "ACL(" $temp.gettype().name ")[" $temp.length "]: " $temp
                            }
                            if ($temp.count -eq 1) {
                                continue
                            }
                            ############
                            if ($temp[0] -match "^$domain\\") {
                                if ((([adsi]([adsisearcher]"samaccountname=$($temp[0] -replace "^$domain\\")").findone().path).useraccountcontrol[0] -band 2) -ne 0) {
                                    # account is disabled
                                    $temp[0] += ' - DISABLED'
                                }
                            }
                            ############
                            if (!$ShowAllAccounts) {
                                if ( Invoke-Expression $comparison ) {
                                    $dirHTML += "<tr><td>" + $temp[0] + "</td><td>" + $temp[1] + "</td><td>" + $temp[2] + "</td></tr>"
                                }
                            } else {
                                $dirHTML += "<tr><td>" + $temp[0] + "</td><td>" + $temp[1] + "</td><td>" + $temp[2] + "</td></tr>"
                            }
                    }
                    $dirHTML += '</tbody>
                                                </table>
                                                </td>
                                                </tr>'
            }
$dirHTML += '
                                                </tbody>
                                        </table>
                                </div>
                        </div>
						<div class="filler"></div>
						</div>'
    return $dirHTML
}
#endregion
#region Header, style and javascript functions needed by the html report
@"
<html dir="ltr" xmlns:v="urn:schemas-microsoft-com:vml" gpmc_reportInitialized="false">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-16" />
<title>Access Control List for $Path</title>
<!-- Styles -->
<style type="text/css">
                body    { background-color:#FFFFFF; border:1px solid #666666; color:#000000; font-size:68%; font-family:MS Shell Dlg; margin:0,0,10px,0; word-break:normal; word-wrap:break-word; }
                table   { font-size:100%; table-layout:fixed; width:100%; }
                td,th   { overflow:visible; text-align:left; vertical-align:top; white-space:normal; }
                .title  { background:#FFFFFF; border:none; color:#333333; display:block; height:24px; margin:0px,0px,-1px,0px; padding-top:4px; position:relative; table-layout:fixed; width:100%; z-index:5; }
                .he0_expanded    { background-color:#FEF7D6; border:1px solid #BBBBBB; color:#3333CC; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:0px; margin-right:0px; padding-left:8px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he1_expanded    { background-color:#A0BACB; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:20px; margin-right:0px; padding-left:8px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he1h_expanded   { background-color: #7197B3; border: 1px solid #BBBBBB; color: #000000; cursor: hand; display: block; font-family: MS Shell Dlg; font-size: 100%; font-weight: bold; height: 2.25em; margin-bottom: -1px; margin-left: 10px; margin-right: 0px; padding-left: 8px; padding-right: 5em; padding-top: 4px; position: relative; width: 100%; }
                .he1    { background-color:#A0BACB; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:20px; margin-right:0px; padding-left:8px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he2    { background-color:#C0D2DE; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:30px; margin-right:0px; padding-left:8px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he3    { background-color:#D9E3EA; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:40px; margin-right:0px; padding-left:11px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he4    { background-color:#E8E8E8; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:50px; margin-right:0px; padding-left:11px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he4h   { background-color:#E8E8E8; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:55px; margin-right:0px; padding-left:11px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he4i   { background-color:#F9F9F9; border:1px solid #BBBBBB; color:#000000; display:block; font-family:MS Shell Dlg; font-size:100%; margin-bottom:-1px; margin-left:30px; margin-right:0px; padding-bottom:5px; padding-left:21px; padding-top:4px; position:relative; width:100%; }
                .he5    { background-color:#E8E8E8; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; height:2.25em; margin-bottom:-1px; margin-left:60px; margin-right:0px; padding-left:11px; padding-right:5em; padding-top:4px; position:relative; width:100%; }
                .he5h   { background-color:#E8E8E8; border:1px solid #BBBBBB; color:#000000; cursor:hand; display:block; font-family:MS Shell Dlg; font-size:100%; padding-left:11px; padding-right:5em; padding-top:4px; margin-bottom:-1px; margin-left:65px; margin-right:0px; position:relative; width:100%; }
                .he5i   { background-color:#F9F9F9; border:1px solid #BBBBBB; color:#000000; display:block; font-family:MS Shell Dlg; font-size:100%; margin-bottom:-1px; margin-left:65px; margin-right:0px; padding-left:21px; padding-bottom:5px; padding-top: 4px; position:relative; width:100%; }
                DIV .expando { color:#000000; text-decoration:none; display:block; font-family:MS Shell Dlg; font-size:100%; font-weight:normal; position:absolute; right:10px; text-decoration:underline; z-index: 0; }
                .he0 .expando { font-size:100%; }
                .info, .info3, .info4, .disalign  { line-height:1.6em; padding:0px,0px,0px,0px; margin:0px,0px,0px,0px; }
                .disalign TD                      { padding-bottom:5px; padding-right:10px; }
                .info TD                          { padding-right:10px; width:50%; }
                .info3 TD                         { padding-right:10px; width:33%; }
                .info4 TD, .info4 TH              { padding-right:10px; width:25%; }
                .info TH, .info3 TH, .info4 TH, .disalign TH { border-bottom:1px solid #CCCCCC; padding-right:10px; }
                .subtable, .subtable3             { border:1px solid #CCCCCC; margin-left:0px; background:#FFFFFF; margin-bottom:10px; }
                .subtable TD, .subtable3 TD       { padding-left:10px; padding-right:5px; padding-top:3px; padding-bottom:3px; line-height:1.1em; width:10%; }
                .subtable TH, .subtable3 TH       { border-bottom:1px solid #CCCCCC; font-weight:normal; padding-left:10px; line-height:1.6em;  }
                .subtable .footnote               { border-top:1px solid #CCCCCC; }
                .subtable3 .footnote, .subtable .footnote { border-top:1px solid #CCCCCC; }
                .subtable_frame     { background:#D9E3EA; border:1px solid #CCCCCC; margin-bottom:10px; margin-left:15px; }
                .subtable_frame TD  { line-height:1.1em; padding-bottom:3px; padding-left:10px; padding-right:15px; padding-top:3px; }
                .subtable_frame TH  { border-bottom:1px solid #CCCCCC; font-weight:normal; padding-left:10px; line-height:1.6em; }
                .subtableInnerHead { border-bottom:1px solid #CCCCCC; border-top:1px solid #CCCCCC; }
                .explainlink            { color:#000000; text-decoration:none; cursor:hand; }
                .explainlink:hover      { color:#0000FF; text-decoration:underline; }
                .spacer { background:transparent; border:1px solid #BBBBBB; color:#FFFFFF; display:block; font-family:MS Shell Dlg; font-size:100%; height:10px; margin-bottom:-1px; margin-left:43px; margin-right:0px; padding-top: 4px; position:relative; }
                .filler { background:transparent; border:none; color:#FFFFFF; display:block; font:100% MS Shell Dlg; line-height:8px; margin-bottom:-1px; margin-left:53px; margin-right:0px; padding-top:4px; position:relative; }
                .container { display:block; position:relative; }
                .rsopheader { background-color:#A0BACB; border-bottom:1px solid black; color:#333333; font-family:MS Shell Dlg; font-size:130%; font-weight:bold; padding-bottom:5px; text-align:center; }
                .rsopname { color:#333333; font-family:MS Shell Dlg; font-size:130%; font-weight:bold; padding-left:11px; }
                .gponame{ color:#333333; font-family:MS Shell Dlg; font-size:130%; font-weight:bold; padding-left:11px; }
                .gpotype{ color:#333333; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; padding-left:11px; }
                #uri    { color:#333333; font-family:MS Shell Dlg; font-size:100%; padding-left:11px; }
                #dtstamp{ color:#333333; font-family:MS Shell Dlg; font-size:100%; padding-left:11px; text-align:left; width:30%; }
                #objshowhide { color:#000000; cursor:hand; font-family:MS Shell Dlg; font-size:100%; font-weight:bold; margin-right:0px; padding-right:10px; text-align:right; text-decoration:underline; z-index:2; word-wrap:normal; }
                #gposummary { display:block; }
                #gpoinformation { display:block; }
                @media print {
                    #objshowhide{ display:none; }
                    body    { color:#000000; border:1px solid #000000; }
                    .title  { color:#000000; border:1px solid #000000; }
                    .he0_expanded    { color:#000000; border:1px solid #000000; }
                    .he1h_expanded   { color:#000000; border:1px solid #000000; }
                    .he1_expanded    { color:#000000; border:1px solid #000000; }
                    .he1    { color:#000000; border:1px solid #000000; }
                    .he2    { color:#000000; background:#EEEEEE; border:1px solid #000000; }
                    .he3    { color:#000000; border:1px solid #000000; }
                    .he4    { color:#000000; border:1px solid #000000; }
                    .he4h   { color:#000000; border:1px solid #000000; }
                    .he4i   { color:#000000; border:1px solid #000000; }
                    .he5    { color:#000000; border:1px solid #000000; }
                    .he5h   { color:#000000; border:1px solid #000000; }
                    .he5i   { color:#000000; border:1px solid #000000; }
                    }
                    v\:* {behavior:url(#default#VML);}
</style>
</head>
<body>
<table class="title" cellpadding="0" cellspacing="0">
<tr><td colspan="2" class="gponame">Access Control List for $Path</td></tr>
<tr>
   <td id="dtstamp">Data obtained on: $(Get-Date)</td>
   <td><div id="objshowhide" tabindex="0"></div></td>
</tr>
</table>
<div class="filler"></div>
"@ | Set-Content $report
#endregion
#region Setting up the report
        '<div class="gposummary">' | Add-Content $report
        if ($colACLs.count) {
            $count = $colACLs.count
        } else {
            $count = 1
        }
        for ($i = 0; $i -lt $count; $i++) {
                drawDirectory ([ref] $colACLs[$i]) | Add-Content $report
        }
        '</div></body></html>' | Add-Content $report
#endregion
    if (!$DontOpen) {
        . $report
    }
    $report
}

function acltovariable ($colACLs, $ShowAllAccounts) {
    foreach ($directory in $colACLs) {
        foreach ($itemacl in $directory.ACL) {
            $acls = $null
            if ($itemACL.AccessToString -ne $null) {
                # select -u because duplicates if inherited and not
                $acls = $itemACL.AccessToString.split("`n") | select -Unique | ? {$_ -notmatch '  -\d{9}$'} | sort
            }
            foreach ($acl in $acls) {
                #$temp = [regex]::split($acl, '(?<!(,|NT))\s+')
                $temp = [regex]::split($acl, '\s+(?=Allow|Deny)|(?<=Allow|Deny)\s+')                    
                if ($temp.count -eq 1) {
                    continue
                }

                # Check if account is Disabled
                if ($temp[0] -match "^$domain\\") {
                    if ((([adsi]([adsisearcher]"samaccountname=$($temp[0] -replace "^$domain\\")").findone().path).useraccountcontrol[0] -band 2) -ne 0) {
                        # account is disabled
                        $temp[0] += ' - DISABLED'
                    }
                }

                if (!$ShowAllAccounts) {
                    if ( Invoke-Expression $comparison ) {
                        $access = New-Object psobject
                        $access | Add-Member -MemberType NoteProperty -Name Folder -Value $directory.Folder.FullName
                        $access | Add-Member -MemberType NoteProperty -Name Name   -Value $temp[0]
                        $access | Add-Member -MemberType NoteProperty -Name Access -Value $temp[1]
                        $access | Add-Member -MemberType NoteProperty -Name Rights -Value $temp[2]
                        $access
                    }
                } else {
                    $access = New-Object psobject
                    $access | Add-Member -MemberType NoteProperty -Name Folder -Value $directory.Folder.FullName
                    $access | Add-Member -MemberType NoteProperty -Name Name   -Value $temp[0]
                    $access | Add-Member -MemberType NoteProperty -Name Access -Value $temp[1]
                    $access | Add-Member -MemberType NoteProperty -Name Rights -Value $temp[2]
                    $access
                }
            }
        }
    }
}

function acltoexcel ($colACLs, $ShowAllAccounts) {
    $saveDir = "$env:TEMP\Network Access"
    if (!(Test-Path $saveDir)) {mkdir "$saveDir\Logs" | Out-Null}
    $time = Get-Date -Format 'yyyyMMddHHmmss'
    $saveName = "Network Access $time"
    $report = "$saveDir\$saveName.csv"
    '' > $report

    acltovariable $colACLs $ShowAllAccounts | epcsv $report -NoTypeInformation

    $xl = New-Object -com 'Excel.Application'
    $wb = $xl.workbooks.open($report)
    $xlOut = $report.Replace('.csv', '')
    $ws = $wb.Worksheets.Item(1)
    $range = $ws.UsedRange 
    [void]$range.EntireColumn.Autofit()
    $wb.SaveAs($xlOut, 51)
    $xl.Quit()
    
    function Release-Ref ($ref) {
        ([System.Runtime.InteropServices.Marshal]::ReleaseComObject([System.__ComObject]$ref) -gt 0)
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
    
    $null = $ws, $wb, $xl | % {Release-Ref $_}

    del $report

    if (!$DontOpen) {
        . ($report -replace '.csv', '.xlsx')
    }
    ($report -replace '.csv', '.xlsx')
}

######### BEGIN DO STUFF ##########

    # set up defaults
    $domain = $env:USERDOMAIN
    if ($Path.EndsWith('\')) { $Path = $Path.Substring(0,$Path.Length - 1) }
    $allowedLevels = 6
    if ($Depth -gt $allowedLevels -or $Depth -lt -1) {Throw 'Level out of range.'}
    
    $comparison = '($acl -match "^$domain\\" -and $acl -notlike "*administrator*" -and $acl -notlike "*BUILTIN*" -and $acl -notlike "*NT AUTHORITY*" -and $acl -notlike "CREATOR*" -and $acl -notlike "S*")'
    
    # begin get all acls
    if ($Depth -eq 0) {
        # just continue
        #$colFiles = Get-ChildItem -path $Path -Filter *. -Recurse -Force | Sort-Object FullName
    } elseif ($Depth -ne -1) {
        1..$Depth | % { [array]$colFiles += Get-ChildItem -path ($Path + ('\*' * $_)) -Filter *. -Force | Sort-Object FullName }
    }

    $colACLs = @()
    $myobj = '' | Select-Object Folder,ACL,level
    $myobj.Folder = Get-Item $Path
    if (!$ExpandGroups) {
        $ShowAllAccounts = $true
        $myobj.ACL = Get-Acl $Path
    } else {
        $myobj.ACL = Get-FolderACL $Path $Rights
    }
    $myobj.level = 0
    $colACLs += $myobj

    #* $file = $colFiles[0]
    foreach($file in $colFiles)
    {
        $matches = (([regex]'\\').matches($file.FullName.substring($Path.length, $file.FullName.length - $Path.length))).count
        if ($file.Mode -notlike 'd*') {
                continue
        }
        $myobj = '' | Select-Object Folder, ACL, Level
        $myobj.Folder = $file
        $myobj.Level = $matches - 1
        if (!$ExpandGroups) {
            $ShowAllAccounts = $true
            $myobj.ACL = Get-Acl $file.FullName
        } else {
            $myobj.ACL = Get-FolderAcl $file.FullName $Rights #* $myobj.ACL = $CurrentACL
        }
        $colACLs += $myobj
    }

    # sort by folder then subs
    $colACLs = $colACLs | sort { $_.folder.fullname }

    # begin do stuff with all those acls...
    if ($ReportFormat -eq 'Console') {
        acltovariable $colACLs $ShowAllAccounts
    } elseif ($ReportFormat -eq 'HTML') {
        acltohtml $Path $colACLs $ShowAllAccounts
    } elseif ($ReportFormat -eq 'Excel') {
        acltoexcel $colACLs $ShowAllAccounts
    }
}

