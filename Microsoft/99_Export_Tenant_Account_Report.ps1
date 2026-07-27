###################################################################
# Copyright (c) 2026 AdrenSnyder https://github.com/adrensnyder
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# DISCLAIMER:
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
###################################################################

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ("Tenant_Account_Report_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))),
    [char]$Delimiter = ';',
    [switch]$IncludeGuestUsers,
    [switch]$SkipFriendlyLicenseNames,
    [switch]$RefreshLicenseCatalog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LicenseCatalogUri = "https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv"
$LicenseCatalogCachePath = Join-Path -Path $env:TEMP -ChildPath "Microsoft365_License_Product_Names.csv"

function Assert-RequiredConnections {
    if (-not (Get-Command -Name Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw "Invoke-MgGraphRequest is not available. Connect to Microsoft Graph before running this script."
    }

    $graphContext = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $graphContext -or -not $graphContext.TenantId) {
        throw "No active Microsoft Graph connection was found. Run the tenant connection script first."
    }

    if (-not (Get-Command -Name Get-EXOMailbox -ErrorAction SilentlyContinue)) {
        throw "Get-EXOMailbox is not available. Connect to Exchange Online before running this script."
    }
}

function Invoke-GraphCollectionRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [hashtable]$Headers = @{}
    )

    $results = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri

    while ($nextUri) {
        $requestParameters = @{
            Method     = "GET"
            Uri        = $nextUri
            OutputType = "PSObject"
        }

        if ($Headers.Count -gt 0) {
            $requestParameters["Headers"] = $Headers
        }

        $response = Invoke-MgGraphRequest @requestParameters

        if ($null -ne $response.value) {
            foreach ($item in $response.value) {
                $results.Add($item)
            }
        }

        $nextUri = $null
        if ($response.PSObject.Properties.Name -contains "@odata.nextLink") {
            $nextUri = $response.'@odata.nextLink'
        }
    }

    return $results
}

function Get-FriendlyLicenseNameMap {
    param(
        [switch]$ForceRefresh
    )

    $nameMap = @{}

    try {
        $downloadRequired = $ForceRefresh -or -not (Test-Path -LiteralPath $LicenseCatalogCachePath)

        if (-not $downloadRequired) {
            $cacheAgeDays = ((Get-Date) - (Get-Item -LiteralPath $LicenseCatalogCachePath).LastWriteTime).TotalDays
            $downloadRequired = $cacheAgeDays -ge 30
        }

        if ($downloadRequired) {
            Write-Host "Downloading the Microsoft license product-name catalog..."
            $webClient = New-Object System.Net.WebClient
            try {
                $webClient.DownloadFile($LicenseCatalogUri, $LicenseCatalogCachePath)
            }
            finally {
                $webClient.Dispose()
            }
        }

        $catalogRows = Import-Csv -LiteralPath $LicenseCatalogCachePath
        foreach ($row in $catalogRows) {
            $skuId = [string]$row.GUID
            $productName = [string]$row.Product_Display_Name

            if (-not [string]::IsNullOrWhiteSpace($skuId) -and
                -not [string]::IsNullOrWhiteSpace($productName) -and
                -not $nameMap.ContainsKey($skuId)) {
                $nameMap[$skuId] = $productName
            }
        }
    }
    catch {
        Write-Warning ("The friendly license-name catalog could not be loaded. SKU part numbers will be used instead. Details: {0}" -f $_.Exception.Message)
    }

    return $nameMap
}

function Get-ActiveDirectoryRoleAssignments {
    # These RBAC endpoints support $select but do not support $top.
    $scheduleInstancesUri = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?$select=principalId,roleDefinitionId,directoryScopeId,assignmentType'
    $roleAssignmentsUri = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$select=principalId,roleDefinitionId,directoryScopeId'

    $graphContext = Get-MgContext -ErrorAction SilentlyContinue
    $grantedScopes = @($graphContext.Scopes)
    $pimReadScopes = @(
        'RoleAssignmentSchedule.Read.Directory',
        'RoleAssignmentSchedule.ReadWrite.Directory',
        'RoleManagement.Read.All',
        'RoleManagement.Read.Directory',
        'RoleManagement.ReadWrite.Directory'
    )

    $canReadPimAssignments = $false
    foreach ($scope in $pimReadScopes) {
        if ($grantedScopes -contains $scope) {
            $canReadPimAssignments = $true
            break
        }
    }

    if ($canReadPimAssignments) {
        try {
            Write-Host "Reading active Microsoft Entra role assignments, including current PIM activations..."
            return @{
                Assignments = Invoke-GraphCollectionRequest -Uri $scheduleInstancesUri
                IncludesPim = $true
            }
        }
        catch {
            Write-Warning ("Current PIM activations could not be queried. Falling back to standard active role assignments. Details: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Warning "Current PIM activations are not included because the Graph connection does not have RoleAssignmentSchedule.Read.Directory or RoleManagement.Read.Directory. Standard active role assignments will still be exported."
    }

    return @{
        Assignments = Invoke-GraphCollectionRequest -Uri $roleAssignmentsUri
        IncludesPim = $false
    }
}

function Get-RoleAssignmentLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleName,

        [string]$DirectoryScopeId,
        [string]$AssignmentType,
        [string]$GroupName
    )

    $label = $RoleName

    if (-not [string]::IsNullOrWhiteSpace($GroupName)) {
        $label += " (via group: $GroupName)"
    }

    if ($AssignmentType -eq "Activated") {
        $label += " [PIM activated]"
    }

    if (-not [string]::IsNullOrWhiteSpace($DirectoryScopeId) -and $DirectoryScopeId -ne "/") {
        $label += " [scope: $DirectoryScopeId]"
    }

    return $label
}

function Add-RoleLabelToUser {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RoleLabelsByUserId,

        [Parameter(Mandatory = $true)]
        [string]$UserId,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $RoleLabelsByUserId.ContainsKey($UserId)) {
        $RoleLabelsByUserId[$UserId] = New-Object System.Collections.Generic.List[string]
    }

    $RoleLabelsByUserId[$UserId].Add($Label)
}

function Test-IsRoleAssignableGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectId
    )

    try {
        $groupUri = "https://graph.microsoft.com/v1.0/groups/$ObjectId" + '?$select=id,displayName,isAssignableToRole'
        $group = Invoke-MgGraphRequest -Method GET -Uri $groupUri -OutputType PSObject

        if ($group.isAssignableToRole -eq $true) {
            return $group
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-TransitiveGroupUserIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    # OData casting and query parameters on transitiveMembers require advanced-query headers.
    $membersUri = "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMembers/microsoft.graph.user" + '?$count=true&$select=id&$top=999'
    $headers = @{ ConsistencyLevel = 'eventual' }
    $members = Invoke-GraphCollectionRequest -Uri $membersUri -Headers $headers
    return @($members | ForEach-Object { [string]$_.id })
}

Assert-RequiredConnections

Write-Host "Reading Microsoft Entra users..."
$usersUri = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,assignedLicenses,userType&$top=999'
$users = Invoke-GraphCollectionRequest -Uri $usersUri

if (-not $IncludeGuestUsers) {
    $users = @($users | Where-Object { $_.userType -ne "Guest" })
}

$userById = @{}
foreach ($user in $users) {
    $userById[[string]$user.id] = $user
}

Write-Host "Reading tenant license SKUs..."
$subscribedSkusUri = 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuId,skuPartNumber'
$subscribedSkus = Invoke-GraphCollectionRequest -Uri $subscribedSkusUri

$skuPartNumberById = @{}
foreach ($sku in $subscribedSkus) {
    $skuPartNumberById[[string]$sku.skuId] = [string]$sku.skuPartNumber
}

$friendlyLicenseNameById = @{}
if (-not $SkipFriendlyLicenseNames) {
    $friendlyLicenseNameById = Get-FriendlyLicenseNameMap -ForceRefresh:$RefreshLicenseCatalog
}

Write-Host "Reading Exchange Online shared mailboxes..."
$sharedMailboxes = Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -Properties ExternalDirectoryObjectId,UserPrincipalName,PrimarySmtpAddress

$sharedMailboxObjectIds = @{}
$sharedMailboxAddresses = @{}
foreach ($mailbox in $sharedMailboxes) {
    $externalDirectoryObjectId = [string]$mailbox.ExternalDirectoryObjectId
    if (-not [string]::IsNullOrWhiteSpace($externalDirectoryObjectId)) {
        $sharedMailboxObjectIds[$externalDirectoryObjectId] = $true
    }

    foreach ($address in @($mailbox.UserPrincipalName, $mailbox.PrimarySmtpAddress)) {
        $addressString = [string]$address
        if (-not [string]::IsNullOrWhiteSpace($addressString)) {
            $sharedMailboxAddresses[$addressString] = $true
        }
    }
}

$roleResult = Get-ActiveDirectoryRoleAssignments
$roleAssignments = @($roleResult.Assignments)

Write-Host "Reading Microsoft Entra role definitions..."
# The roleDefinitions collection supports $filter and $expand, but not $select or $top.
$roleDefinitionsUri = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions'
$roleDefinitions = Invoke-GraphCollectionRequest -Uri $roleDefinitionsUri

$roleNameById = @{}
foreach ($roleDefinition in $roleDefinitions) {
    $roleNameById[[string]$roleDefinition.id] = [string]$roleDefinition.displayName
}

$roleLabelsByUserId = @{}
$groupCache = @{}
$groupMemberCache = @{}

Write-Host "Resolving direct and group-inherited administrator roles..."
foreach ($assignment in $roleAssignments) {
    $principalId = [string]$assignment.principalId
    $roleDefinitionId = [string]$assignment.roleDefinitionId
    $directoryScopeId = [string]$assignment.directoryScopeId
    $assignmentType = ""

    if ($assignment.PSObject.Properties.Name -contains "assignmentType") {
        $assignmentType = [string]$assignment.assignmentType
    }

    if ($roleNameById.ContainsKey($roleDefinitionId)) {
        $roleName = $roleNameById[$roleDefinitionId]
    }
    else {
        $roleName = "Unknown role ($roleDefinitionId)"
    }

    if ($userById.ContainsKey($principalId)) {
        $label = Get-RoleAssignmentLabel -RoleName $roleName -DirectoryScopeId $directoryScopeId -AssignmentType $assignmentType
        Add-RoleLabelToUser -RoleLabelsByUserId $roleLabelsByUserId -UserId $principalId -Label $label
        continue
    }

    if (-not $groupCache.ContainsKey($principalId)) {
        $groupCache[$principalId] = Test-IsRoleAssignableGroup -ObjectId $principalId
    }

    $group = $groupCache[$principalId]
    if ($null -eq $group) {
        continue
    }

    if (-not $groupMemberCache.ContainsKey($principalId)) {
        $groupMemberCache[$principalId] = @(Get-TransitiveGroupUserIds -GroupId $principalId)
    }

    $groupName = [string]$group.displayName
    $groupLabel = Get-RoleAssignmentLabel -RoleName $roleName -DirectoryScopeId $directoryScopeId -AssignmentType $assignmentType -GroupName $groupName

    foreach ($memberUserId in $groupMemberCache[$principalId]) {
        if ($userById.ContainsKey($memberUserId)) {
            Add-RoleLabelToUser -RoleLabelsByUserId $roleLabelsByUserId -UserId $memberUserId -Label $groupLabel
        }
    }
}

Write-Host "Building the account report..."
$report = foreach ($user in ($users | Sort-Object -Property displayName, userPrincipalName)) {
    $userId = [string]$user.id
    $userPrincipalName = [string]$user.userPrincipalName

    $licenseNames = New-Object System.Collections.Generic.List[string]
    foreach ($assignedLicense in @($user.assignedLicenses)) {
        $skuId = [string]$assignedLicense.skuId
        if ([string]::IsNullOrWhiteSpace($skuId)) {
            continue
        }

        if ($friendlyLicenseNameById.ContainsKey($skuId)) {
            $licenseNames.Add($friendlyLicenseNameById[$skuId])
        }
        elseif ($skuPartNumberById.ContainsKey($skuId)) {
            $licenseNames.Add($skuPartNumberById[$skuId])
        }
        else {
            $licenseNames.Add($skuId)
        }
    }

    $licensesText = "None"
    if ($licenseNames.Count -gt 0) {
        $licensesText = (($licenseNames | Sort-Object -Unique) -join "; ")
    }

    $isSharedMailbox = $sharedMailboxObjectIds.ContainsKey($userId) -or $sharedMailboxAddresses.ContainsKey($userPrincipalName)
    $sharedMailboxText = if ($isSharedMailbox) { "Yes" } else { "No" }

    $notesText = ""
    if ($roleLabelsByUserId.ContainsKey($userId)) {
        $uniqueRoleLabels = @($roleLabelsByUserId[$userId] | Sort-Object -Unique)
        if ($uniqueRoleLabels.Count -gt 0) {
            $notesText = "Administrator roles: " + ($uniqueRoleLabels -join "; ")
        }
    }

    [PSCustomObject]@{
        "Display Name"        = [string]$user.displayName
        "User Principal Name" = $userPrincipalName
        "Licenses"            = $licensesText
        "Shared Mailbox"      = $sharedMailboxText
        "Notes"               = $notesText
    }
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$csvLines = $report | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter
$utf8WithBom = New-Object System.Text.UTF8Encoding -ArgumentList $true
[System.IO.File]::WriteAllLines($OutputPath, $csvLines, $utf8WithBom)

Write-Host ""
Write-Host "-------------------- REPORT COMPLETED --------------------"
Write-Host ("Users exported        : {0}" -f @($report).Count)
Write-Host ("Shared mailboxes found: {0}" -f @($sharedMailboxes).Count)
Write-Host ("Output file           : {0}" -f (Resolve-Path -LiteralPath $OutputPath).Path)
Write-Host "----------------------------------------------------------"
Write-Host ""