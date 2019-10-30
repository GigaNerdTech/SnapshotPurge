# Snapshot cleaner for vCenter

# Command line parameters
Param([string]$Cluster,[switch]$All=$false,[switch]$Purge=$false)

$check_all_clusters = $false
$cluster_name = $false

# tags to keep snapshots
$tag_category = "VM"
$tag_name = "keepsnap"

# Check options
if ([string]::IsNullOrEmpty($Cluster) -and ($All -eq $false)) {
    Write-Host "Specify -Cluster <name> or -All"
    exit
}
elseif (-not ([string]::IsNullOrEmpty($Cluster)) -and ($All -eq $true)) {
    Write-Host "-Cluster and -All incompatible options!"
    exit
}
elseif (-not ([string]::IsNullOrEmpty($Cluster))) {
    $cluster_name = $Cluster
}
elseif ($All -eq $true) {
    Write-Host "ALL $All so setting clusters to true!"
    $check_all_clusters = $true
}
else {
    # nothing
}

# exclusion patterns
$exclusion_patterns = @("Exclusion1","Exclusion2")

# Variable declarations
$snapshot_inventory = @{}
$old_snapshots = @()
$purge_limit = 7 #days


# Import and/or install modules
if (Get-Module -ListAvailable -Name VMware.VimAutomation.Core) {
    Import-Module VMware.VimAutomation.Core
}
else {
    if (Get-PSRepository | Where-Object { $_ -match "internal-repo" }) {
        Install-Module -Name VMware.PowerCLI -Repository "internal-repo" -AllowClobber
        Import-Module VMware.VimAutomation.Core
    }
    else {
        Register-PSRepository -Name 'internal-repo' -SourceLocation 'https://internal-repo/nuget' -InstallationPolicy Trusted
        Install-Module -Name VMware.PowerCLI -Repository "internal-repo" -AllowClobber
        Import-Module VMware.VimAutomation.Core
    }
}
Import-Module ActiveDirectory

# Start Transcript
$TranscriptFile = "\\networkshare\Powershell\PSLogs\VMwareSnapshotCleaner_$(get-date -f MMddyyyyHHmmss).txt"
$start_time = Get-Date
Start-Transcript -Path $TranscriptFile

# Vcenter hosts
$vhosts = @("vc01","vc02")

# Collect vSphere credentials
Write-Output "`n`nvSphere credentials:`n"
$vsphere_user = Read-Host -Prompt "Enter the user for the vCenter host"
$vsphere_pwd = Read-Host -Prompt "Enter the password for connecting to vSphere: " -AsSecureString
$vsphere_creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $vsphere_user,$vsphere_pwd -ErrorAction Stop

# Get snapshots
foreach ($vcenter_host in $vhosts) {
    # Connect to vCenter
    Write-Host "Gathering snapshots..."
    Connect-VIServer -Server $vcenter_host -Credential $vsphere_creds

    
    # Get tag object
    $tag = Get-Tag -Server $vcenter_host -Category $tag_category -Name $tag_name -ErrorAction SilentlyContinue

    $snapshot_collection = Get-VM -Server $vcenter_host| Where { ($_ | Get-TagAssignment -Server $vcenter_host).Tag.Name -notcontains $tag_name } | Get-Snapshot

    $snapshot_inventory[$vcenter_host] = $snapshot_collection
}



# Get today's date
$today = Get-Date

# Check the snapshots
Write-Host "Checking snapshots..."
foreach ($vcenter_host in $vhosts) {
    $snapshot_inventory[$vcenter_host] | ForEach-Object {
        $current_snapshot = $_
        $current_cluster = ""
        $current_vm = $current_snapshot.VM
        if ($check_all_clusters -eq $true) {
            $current_cluster = (Get-Cluster -VM $current_vm).Name
        }
        $snapshot_date = $current_snapshot.Created

        $date_difference = (New-TimeSpan -Start $snapshot_date -End $today).TotalDays
        if (($date_difference -gt $purge_limit) -and ($check_all_clusters -or ($current_cluster -eq $cluster_name))) {
            Write-Host ("Adding snapshot " + $current_snapshot.Description + " from VM " + $current_vm.Name)
            $old_snapshots += $current_snapshot
        }
    }
}

# Remove snapshots if -Purge is specified

if ($Purge) {
    Write-Host "Purging snapshots.."
    foreach ($snapshot in $old_snapshots) {
        Write-Host ("Purging snapshot " + $snapshot.Description + " from VM " + $snapshot.VM.Name)
        Remove-Snapshot -Snapshot $snapshot -Confirm:$true
    }
}


Stop-Transcript
# Generate email report

$username = $env:USERNAME
$email_user = (Get-ADUser -Properties EmailAddress -Identity $username | Select -ExpandProperty EmailAddress)

$email_list=@("email1@example.com", $email_user)
$subject = "VMware Snapshot Purge called by $username"

if ($Purge) {
    $subject += " - DELETION CALLED"
    $subject = ($subject | Out-String)
}
$body = @()

$body += "<h1>VMWare Old Snapshot Report</h1>"

if ($check_all_clusters) {
    $body += "`nScript ran against all clusters.`n`n"
}
if (-not [string]::IsNullOrEmpty($cluster_name)) {
    $body += "`nScript ran against cluster $cluster`n`n"
}
if ($Purge) {
    $body += "`nThese snapshots WERE deleted.`n`n"
}
else {
    $body += "`nThis is a report only.`n`n"
}


$table_body = "<table border=`"3`"><thead><tr><th>Virtual Machine</th><th>Snapshot Description</th><th>Snapshot Creation Time</th><th>Snapshot Size (GB)</th></tr></thead><tbody>"
foreach ($snapshot in $old_snapshots) {
     $table_body += ("<tr><td>" + $snapshot.VM.Name + "</td><td>" + $snapshot.Description + "</td><td>" + $snapshot.Created + "</td><td>" + ($snapshot.SizeGB.ToString() -replace "\..*","") +  "</td></tr>")
}
$table_body += "</tbody></table>"
$body += $table_body

$MailMessage = @{
    To = $email_list
    From = "SnapshotPurgeReport<Donotreply@example.com>"
    Subject = $subject
    Body = ($body -join "<br/>")
    SmtpServer = "smtp.example.com"
    Attachment = $TranscriptFile
    ErrorAction = "Stop"
}
Send-MailMessage @MailMessage -BodyAsHtml


Write-Host "Disconnecting from vCenter..."
foreach ($vcenter_host in $vhosts) {
    Disconnect-VIServer -Server $vcenter_host -Confirm:$false
}