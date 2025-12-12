
##############################################################################
#
#.SYNOPSIS
# Get the Vms Disk foot print
#
#.DESCRIPTION
# Disk foot print is calculated below file which makes an VM
# Config files (.vmx, .vmxf, .vmsd, .nvram)
# Log files (.log)
# Disk files (.vmdk)
# Snapshots (delta.vmdk, .vmsn)
# Swapfile (.vswp)
#
# Get-View -VIObject centOs-1
# TypeName: VMware.Vim.VirtualMachineFileInfo

# FtMetadataDirectory Property   string FtMetadataDirectory {get;set;}
# LogDirectory        Property   string LogDirectory {get;set;}
# SnapshotDirectory   Property   string SnapshotDirectory {get;set;}
# SuspendDirectory    Property   string SuspendDirectory {get;set;}
# VmPathName          Property   string VmPathName {get;set;}
#
#.PARAMETER vm
# VM Object returned by Get-VM cmdlet
#
#.EXAMPLE
# $vmSize = Get-VmDisksFootPrint($vm)
#
##############################################################################

Function Get-VmDisksFootPrint($vm) {
   #Initialize variables
   $VmDirs = @()
   $VmSize = 0
   $vmDsIdMap = @{}
   $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
   $searchSpec.details = New-Object VMware.Vim.FileQueryFlags
   $searchSpec.details.fileSize = $TRUE

   Get-View -VIObject $vm | % {
      #Populate the array with the vm's directories
      $VmDirs += $_.Config.Files.VmPathName.split("/")[0]
      $VmDirs += $_.Config.Files.SnapshotDirectory.split("/")[0]
      $VmDirs += $_.Config.Files.SuspendDirectory.split("/")[0]
      $VmDirs += $_.Config.Files.LogDirectory.split("/")[0]
      foreach ($dsMoref in $_.Datastore){
         $vmDsIdMap[(Get-Datastore -Id $dsMoref).Name] = $dsMoRef
      }
      #Add directories of the vm's virtual disk files
      foreach ($disk in $_.Layout.Disk) {
         foreach ($diskfile in $disk.diskfile) {
            $VmDirs += $diskfile.split("/")[0]
         }
      }

      #Only take unique array items
      $VmDirs = $VmDirs | Sort-Object | Get-Unique

      foreach ($dir in $VmDirs) {
         $datastoreObj = $vmDsIdMap[ ($dir.split("[")[1]).split("]")[0] ]
         $datastoreBrowser = Get-View (( Get-Datastore -Id $datastoreObj | get-view).Browser)
         $taskMoRef  = $datastoreBrowser.SearchDatastoreSubFolders_Task($dir,$searchSpec)
         $task = Get-View $taskMoRef
         while($task.Info.State -eq "running" -or $task.Info.State -eq "queued") {$task = Get-View $taskMoRef }
         foreach ($result in $task.Info.Result){
            foreach ($file in $result.File){
               $VmSize += $file.FileSize
            }
         }
      }
   }

   return $VmSize
}

##############################################################################
#
#.SYNOPSIS
# Get the ESX version of the Host
#
#.DESCRIPTION
# Return the ESX product version of the HostObjects supplied in parameter
#
#.PARAMETER EsxHosts
# Host Objects
#
#.EXAMPLE
# $HostObjects = Get-View -ViewType HostSystem
# $Hash = Get-HostVersion -EsxHosts $HostObjects
#
##############################################################################
Function Get-HostVersion {
   param([Object]$EsxHosts= "")
   $EsxHostVersion = @{}
   Foreach ($esx in $HostObjects) {
      $version = $esx.Config.Product.version
      $EsxHostVersion[$esx] = $version
   }

   return $EsxHostVersion
}

##################################################################################################################
#
#.SYNOPSIS
# Perform preflight check before proceeding with migration
#
#.DESCRIPTION
# Top level function calling respective preflight checks before proceeding
#  with migration
#
#.PARAMETER Function
# Function to call
#
#.PARAMETER TargetObjects
# Target Object is being verified
#
#.PARAMETER ExpectedValue
# Attribute to verify
#
#.EXAMPLE
# PreFlightCheck -Function "CheckHostVersion" -TargetObjects $HostObjects -ExpectedValue $TargettedHostVersion
#
##################################################################################################################

Function PreFlightCheck {
   param(
      [parameter(Mandatory=$true)][string]$Function,
      [object]$TargetObjects,
      [object]$ExpectedValue
   )

   if(Get-Command $Function -ea SilentlyContinue) {
      #write-host $Function $TargetObjects $ExpectedValue
      & $Function $TargetObjects $ExpectedValue
   } else {
      # ignore
   }
}


##############################################################################
#.SYNOPSIS
# PreFLight check for ESX version
#
#.DESCRIPTION
# Function check the host version
#
#.PARAMETER HostObjects
# Target Object is being verified
#
#.PARAMETER Version
# Expected Version
#
#.EXAMPLE
# $status = CheckHostVersion -HostObjects $hostObject -Version $version
##############################################################################

Function CheckHostVersion {
   param(
      [parameter(Mandatory=$true)][object]$HostObjects,
      [String]$Version
   )

   $status = $true
   $targetVersion = New-Object System.Version($version)
   $Hash = Get-HostVersion -EsxHosts $HostObjects
   foreach ($host in $HostObjects) {
      $hostName = $host.Name
      $hostVersion = New-Object System.Version($host.Config.Product.version)
      if($hostVersion -ge $targetVersion) {
         $status = $status -And $true
         Format-output -Text "VM host $hostName is of version $hostVersion" -Level "SUCCESS" -Phase "Pre-Check"
      } else {
         $status = $status -And $false
         Format-output -Text "VM host $hostName is of version $hostVersion" -Level "ERROR" -Phase "Pre-Check"
      }
   }

   return $status
}

##############################################################################
#
#.SYNOPSIS
# Format the log messages
#
#.DESCRIPTION
# Format the log message printed on the screen
# Also redirect the message to a log file
#
#.PARAMETER
# Text - log message to be printed
# Level - SUCCESS,INFO,ERROR
# Phase - Different phase of commandlet, Preperation,Migration,Roll back
#
#
#.EXAMPLE
# Format-output -Text $MsgText -Level "INFO" -Phase "Migration Pre-Check phase"
#
##############################################################################

Function Format-output {
   param (
      [Parameter(Mandatory=$true)][string]$Text,
      [Parameter(Mandatory=$true)][string]$Level,
      [Parameter(Mandatory=$false)][string]$Phase
   )

   BEGIN {
      filter timestamp {"$(Get-Date -Format s) `[$Phase`] $Text" }
   }

   PROCESS {
      $Text | timestamp | Out-File -FilePath $global:LogFile -Append -Force
      if($Level -eq "SUCCESS" ) {
         $Text | timestamp | write-host -foregroundcolor "green"
      } elseif ( $Level -eq "INFO") {
         $Text | timestamp | write-host -foregroundcolor "yellow"
      } else {
         $Text | timestamp | write-host -foregroundcolor "red"
      }
   }
}

<#
.SYNOPSIS
    Wrapper Funtion to Call Storage Vmotion
.DESCRIPTION
    You may send a list of vm names
.PARAMETER VM
    Pass vmnames
.PARAMETER Destination
    PASS Destination datastore name
.PARAMETER Destination
    PASS ParallelTasks to perform
.INPUTS
.OUTPUTS
.EXAMPLE
    Storage-Vmotion -VM $vmlist -Destination 'Datastore_1' -ParallelTasks 2
#>
Function Concurrent-SvMotion {
   [CmdletBinding()]
   param (
      [Parameter(Mandatory = $true)][VMware.VimAutomation.ViCore.Util10.VersionedObjectImpl]$session,
      [Parameter(Mandatory = $true)][string[]]$VM,
      [Parameter(Mandatory = $true)][string]$SourceId,
      [Parameter(Mandatory = $true)][string]$DestinationId,
      [Parameter(Mandatory = $true)][int]$ParallelTasks
   )

   BEGIN {
       $TargetDatastoreId = $DestinationId
       $Date = get-date
       $VmsToMigrate = $VM
       $Failures = 0;
       $LoopCtrl = 1
       $VmInput = $VM
       $GB = 1024 * 1024 * 1024
       $BufferSize = 5
       $RelocateTaskList = @()
   }

   PROCESS {
      while ($LoopCtrl -gt 0) {
         $shiftedVm = shift -array ([ref]$vmInput) -numberOfElements $ParallelTasks
         $vmToMigrate = $shiftedVm
         $LoopCtrl = $vmInput.Count
         #Check the datastore contain sufficient space
         foreach ($TargetVm in $vmToMigrate) {
            $vm = Get-VM $TargetVm
            $vmSize += Get-VmDisksFootPrint $vm
         }
         $vmSize = [math]::Round(($vmSize / $GB) + $BufferSize)
         $tagetDatastoreObj = Get-Datastore -Id  $TargetDatastoreId
         if($tagetDatastoreObj.FreeSpaceGB -gt $vmSize) {
            $MsgText = "$TargetDatastore Contain FreeSpace of $($tagetDatastoreObj.FreeSpaceGB) GB to accomodate $vmToMigrate of size $vmSize GB"
            Format-output -Text $MsgText -Level "INFO" -Phase "Migration Pre-Check phase"
            $RelocateTaskList += Storage-Vmotion -session $session -Source $SourceId -VM $vmToMigrate -Destination $DestinationId
            # Iterate through has list of TaskMap and check for task failures
            foreach ($Task in $RelocateTaskList ) {
               if ( $Task["State"] -ne "Success" ) {
                  $Failure += 1
                  return $RelocateTaskList
               } else {
                  $Success += 1
               }
            }
         } else {
            #If insufficient datastore space just mark the migration task as failure
            $MsgText = "$TargetDatastore have insufficient space. FreeSpace of $($tagetDatastoreObj.FreeSpaceGB) GB to accomdate $vmToMigrate of size $vmSize GB"
            Format-output -Text $MsgText -Level "INFO" -Phase "Migration Pre-Check phase"
            $TaskMap = @{}
            $TaskMap["Name"] = $TargetVm
            $TaskMap["State"] = "Error"
            $TaskMap["Cause"] = "INSUFFICIENT_DATASTORE_SPACE"
            $RelocTaskList += $TaskMap
            return $RelocateTaskList
         }
      }
      return $RelocateTaskList
   }
}

Function MoveTheVM {
   [CmdletBinding()]
   param (
      [Parameter(Mandatory=$true)][VMware.VimAutomation.ViCore.Util10.VersionedObjectImpl]$session,
      [Parameter(Mandatory=$true)][String]$VM,
      [Parameter(Mandatory=$true)][string]$SourceId,
      [Parameter(Mandatory=$true)][string]$DestinationId
   )

   BEGIN {
      $vm = $VM
      $datastore = (Get-Datastore -id $SourceId)
      $tempdatastore = (Get-Datastore -id $DestinationId)
   }

   PROCESS {
      try {
         $vmName=Get-VM -Name $vm
         $vmId = $vmName.id
         $MsgText ="VM = $vm, Datastore = $datastore and Target datastore = $tempdatastore and id is $vmId"
         Format-output -Text $MsgText -Level "INFO" -Phase "VM migration"
         $hds = Get-HardDisk -VM $vm
         $spec = New-Object VMware.Vim.VirtualMachineRelocateSpec
         $vmView=get-view -id $vmId
         if($vmView.Summary.Config.VmPathName.Contains($datastore)) {
            $spec.datastore = ($tempdatastore).Extensiondata.MoRef
         }

         $hds | %{
            if ($_.Filename.Contains($datastore)) {
               $disk = New-Object VMware.Vim.VirtualMachineRelocateSpecDiskLocator
               $disk.diskId = $_.ExtensionData.Key
               $disk.datastore = ($tempdatastore).Extensiondata.MoRef
               $spec.disk += $disk
            } else {
               $extendedDs = $_.ExtensionData.Backing.Datastore
               $disk = New-Object VMware.Vim.VirtualMachineRelocateSpecDiskLocator
               $disk.diskId = $_.ExtensionData.Key
               $disk.datastore = $extendedDs
               $spec.disk += $disk
		      }
         }

         $task = $vmName.Extensiondata.RelocateVM_Task($spec, "defaultPriority")
         $task1 = Get-Task -server $session | where { $_.id -eq $task }
         return $task1
      } catch {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Moving Virtual Machines"
         Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move all the VMs from $Source to $Destination manually and then try again." -Level "Error" -Phase "Moving Virtual Machines"
         Return
      }
   }
}

########################################################################################################
#
#.SYNOPSIS
# Perform Concurrent Storage VMotion
#
#.DESCRIPTION
# Perform concurrent Migration based on no of Async task to run
# Continous DS space validation before migration
#
#.PARAMETER
# VM  - List of VM names to Migrate
# Destination - Destination Datastore Names
# Return the TaskMap about VC migration task
#
#
#.EXAMPLE
# $RelocTaskList = Concurrent-SvMotion -VM $vmList -Destination $TemporaryDatastore -ParallelTasks 2
#
########################################################################################################

function Storage-Vmotion {
   [CmdletBinding()]
   param (
      [Parameter(Mandatory=$true)][VMware.VimAutomation.ViCore.Util10.VersionedObjectImpl]$session,
      [Parameter(Mandatory=$true)][string[]]$VM,
      [Parameter(Mandatory=$true)][string]$SourceId,
      [Parameter(Mandatory=$true)][string]$DestinationId
   )

   BEGIN {
      $TargetDatastoreId = $DestinationId
      $VmsToMigrate = $VM
      $RelocateTaskStatus = @()
      $Failures = 0
      $Success = 0
      $TaskTab = @{}
      $GB = 1024 * 1024 * 1024
   }

   PROCESS {
      foreach ($TargetVm in $VmsToMigrate) {
         $date = get-date
         Format-output -Text "$TargetVm : Migration is in progress From:$Source To:$TargetDatastoreId" -Level "INFO" -Phase "Migration"
         $task = MoveTheVM -VM $TargetVm -session $session -SourceId $SourceId -DestinationId $TargetDatastoreId
         $TaskTab[$task.id] = $TargetVm
      }

      # Get the status of running tasks
      $RunningTasks = $TaskTab.Count
      while($RunningTasks -gt 0) {
         Get-Task | % {
            if ($TaskTab.ContainsKey($_.Id) -and $_.State -eq "Success") {
               $TaskMap = @{}
               $Success += 1
               $TaskMap["Name"] = $TaskTab[$_.Id]
               $TaskMap["TaskId"] = $_.Id
               $TaskMap["StartTime"] = $_.StartTime
               $TaskMap["EndTime"] = $_.FinishTime
               $TaskMap["State"] = $_.State
               $TaskMap["Cause"] = ""
               $TaskTab.Remove($_.Id)
               $RunningTasks--
               $RelocateTaskStatus += $TaskMap
            } elseif ($TaskTab.ContainsKey($_.Id) -and $_.State -eq "Error") {
               $TaskMap = @{}
               $Failures += 1
               $TaskMap["Name"] = $TaskTab[$_.Id]
               $TaskMap["TaskId"] = $_.Id
               $TaskMap["StartTime"] = $_.StartTime
               $TaskMap["EndTime"] = $_.FinishTime
               $TaskMap["State"] = $_.State
               $TaskMap["Cause"] = ""
               $TaskTab.Remove($_.Id)
               $RunningTasks--
               $RelocateTaskStatus += $TaskMap
            }
         }

         Start-Sleep -Seconds 15
      }
   }

   END {
      Foreach ($Tasks in $RelocateTaskStatus) {
         if ($Tasks["State"] -eq "Success") {
            $MsgText = "Migration of $($Tasks["Name"]) is successful Start Time : $($Tasks["StartTime"]) End Time : $($Tasks["EndTime"])"
            Format-output -Text $MsgText -Level "SUCCESS" -Phase "Migration"
         } else {
            $MsgText = "Migration of $($Tasks["Name"]) is failure    Start Time : $($Tasks["StartTime"]) End Time : $($Tasks["EndTime"])"
            Format-output -Text $MsgText -Level "FAILURE" -Phase "Migration"
         }
      }

      return  $RelocateTaskStatus
   }
}

##############################################################################
#
#.SYNOPSIS
# Function to shift an array
#
#.DESCRIPTION
# Perform shift action similar to Perl shift
#
#.PARAMETER
# array  - Array to shift
# numberOfElements - No of elements to shift
# On success Orginal array is resized
#
#
#.EXAMPLE
#
# $shiftedVm = shift -array ([ref]$array) -numberOfElements 2
#
##############################################################################

Function shift {
   param (
      [Parameter(Mandatory=$true)][ref]$array,
      [Parameter(Mandatory=$true)][int]$numberOfElements
   )

   BEGIN {
      $shiftedValue = @()
      $temp = @()
      $temp = $array.Value
   }

   PROCESS {
      if ($temp.Count -ge $numberOfElements) {
         $Iterate =  $numberOfElements
      } else {
         $Iterate = $temp.Count
      }

      for ($i = $Iterate; $i -gt 0; $i -= 1) {
         $firstElement,$temp = $temp;
         $shiftedValue += $firstElement
      }
   }

   END {
      $array.value = $temp
      return $shiftedValue
   }
}

###############################################################################
#
#.SYNOPSIS
# Get the Items in a Datastore
#
#.DESCRIPTION
# Get the list of Items in a Datastore
#
#.PARAMETER
# Datastore - UUID/ID of the Datastore
#
#.EXAMPLE
# $list = Get-DataStoreItems -Datastore "local-0"
#
##############################################################################

Function Get-DataStoreItems {
   param(
      [Parameter(Mandatory=$true)][string]$DatastoreId,
      [Parameter()][Switch]$Recurse,
      [Parameter()][string]$fileType
   )

   $childItems = @()
   $datastoreObj = Get-Datastore -Id  $DatastoreId
   if ($Recurse) {
      $childItems = Get-ChildItem -Recurse $datastoreObj.DatastoreBrowserPath | Where-Object {$_.name.EndsWith($fileType)} 
   } else {
      $childItems = Get-ChildItem $datastoreObj.DatastoreBrowserPath | Where-Object {$_.name -notmatch "^[.]"}
   }

   return $childItems 
}

###################################################################################################
#
#.SYNOPSIS
# Copy files from Source to Desintation
#
#.DESCRIPTION
# Copy Orphaned files, not registered in VC
#
#.PARAMETER
# SourceDatastore - Source
# DestinationDatastore - Destination
#
#.EXAMPLE
# $Return Status = Copy-DatastoreItems -SourceDatastore "local-0" -DestinationDatastore "local-1"
#
###################################################################################################

Function Copy-DatastoreItems {
   param(
      [Parameter(Mandatory=$true)][string]$SourceDatastoreId,
      [Parameter(Mandatory=$true)][string]$DestinationDatastoreId
   )

   $copyOrphanPhase = "Copying Orphaned data"
   $SrcChildItems = @()
   $DstChildItems = @()
   $sourceDsObj = Get-Datastore -Id  $SourceDatastoreId
   $targetDsObj = Get-Datastore -Id  $DestinationDatastoreId

   #Map Drives
   try {
      $sourceDrive = new-psdrive -Location $sourceDsObj -Name sourcePsDrive -PSProvider VimDatastore -Root "/"
      $targetDrive = new-psdrive -Location $targetDsObj -Name targetPsDrive -PSProvider VimDatastore -Root "/"
      $SrcChildItems = Get-DataStoreItems -DatastoreId $SourceDatastoreId
      $DstChildItems = Get-DataStoreItems -DatastoreId $DestinationDatastoreId
      Format-output -Text "Copying Orphaned Items: $SrcChildItems" -Level "INFO" -Phase $copyOrphanPhase
      $Fileinfo = Copy-DatastoreItem -Recurse -Item sourcePsDrive:/* targetPsDrive:/ -Force
   } catch [Exception] {
      Remove-PSDrive -Name sourcePsDrive
      Remove-PSDrive -Name targetPsDrive
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase $copyOrphanPhase
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move all the orphaned data from $SourceDatastore to $DestinationDatastore manually and then try again." -Level "ERROR" -Phase $copyOrphanPhase
      Return $false
   }

   Remove-PSDrive -Name sourcePsDrive
   Remove-PSDrive -Name targetPsDrive
   Return $true
}

####################################################################################
#
#.SYNOPSIS
# Return Success or Failure list of Tasks
#
#.DESCRIPTION
# This Function checks through the list of Task and return a list of success or
# Failure tasks based on the input
#
#.PARAMETER
# RelocateTasksList = List containing the Relocate Task Map
#
#.EXAMPLE
# $SuccessTaskList=Get-RelocTask -RelocateTasksList $migrateTaskList -State "SUCCESS"
#
####################################################################################

Function Get-RelocTask {
   param (
      [Parameter(Mandatory=$true)][hashtable[]]$TasksList,
      [Parameter(Mandatory=$true)][string]$State
   )

   BEGIN {
      $SuccessList = @()
      $FailureList = @()
   }

   PROCESS {
      # Iterate through has list of TaskMap hash and check for task failures
      foreach ($Task in $TasksList ) {
         $NumberOfMigration += 1
         if ($Task["State"] -ne "Success") {
            $FailureList += $Task
         } else {
            $SuccessList += $Task
         }
      }
   }

   END {
      if ($State -eq "SUCCESS") {
         return $SuccessList
      } else {
         return $FailureList
      }
   }
}

####################################################################################
#.SYNOPSIS
#  Creats Zip file with the log folder
#
#.PARAMETER
# $logdir = Log directory to zip/archive
#
#
#
####################################################################################
Function Zip-Logs {
   param([Parameter(Mandatory=$true)][string] $logdir)

   $sourceDir = Join-Path -Path $pwd -ChildPath $logdir
   $LogTime = Get-Date -Format "MM-dd-yyyy_hh-mm-ss"
   $destination = "$sourceDir" + "_" + "$LogTime.zip"
	If (Test-path $destination) {
      Remove-item $destination
   }

   Add-Type -assembly "system.io.compression.filesystem"
   [io.compression.zipfile]::CreateFromDirectory($sourceDir, $destination) 
	Format-output -Text "Zip file is available at: $destination" -Level "INFO" -Phase "Log Zip"
}


####################################################################################
#
#.SYNOPSIS
# Unmount the datastore
#
#.DESCRIPTION
# Unmount the datastore from all connected hosts
#
#.PARAMETER
# Datastore = Datastore to unmount
#
#.EXAMPLE
#
# Unmount-Datastore -Datastore "local-0"
#
####################################################################################

Function Unmount-Datastore {
   [CmdletBinding()]
   Param ([Parameter(ValueFromPipeline=$true)][string]$DatastoreId)

   BEGIN {
      $dsObject = Get-Datastore -Id $DatastoreId
   }

   Process {
      Foreach ($eachDsObj in $dsObject) {
         if ($eachDsObj.ExtensionData.Host) {
            $attachedHosts = $eachDsObj.ExtensionData.Host
            Foreach ($VMHost in $attachedHosts) {
               $hostview = Get-View $VMHost.Key
               $mounted = $VMHost.MountInfo.Mounted
               #If the device is mounted then unmount it
               if ($mounted -eq $true) {
                  $StorageSys = Get-View $HostView.ConfigManager.StorageSystem
                  Format-output -Text "Unmounting VMFS Datastore $($eachDsObj.Name) from host $($hostview.Name)..." -Level "INFO" -Phase "Unmount Datastore"
                  $StorageSys.UnmountVmfsVolume($eachDsObj.ExtensionData.Info.vmfs.uuid);
               } else {
                  Format-output -Text "VMFS Datastore $($eachDsObj.Name) is already unmounted on host $($hostview.Name)..." -Level "INFO" -Phase "Unmount Datastore"
               }
            }
         }
      }
   }
}

####################################################################################
#
#.SYNOPSIS
# Remove a datastore
#
#.DESCRIPTION
# Remove a datastore
#
#.PARAMETER
# Datastore = Datastore to delete
#
#.EXAMPLE
#
# Delete-Datastore -Datastore "local-0"
#
####################################################################################

Function Delete-Datastore {
   [CmdletBinding()]
   Param (
      [Parameter(ValueFromPipeline=$true)] [string]$DatastoreId
   )

   BEGIN {
      $dsObjectList = Get-Datastore -Id $DatastoreId
   }

   Process {
      Foreach ($eachDsObj in $dsObjectList) {
         if ($eachDsObj.ExtensionData.Host) {
            $attachedHosts = $ds.ExtensionData.Host
            $deleted = $false
            Foreach ($VMHost in $attachedHosts) {
               $hostview = Get-View $VMHost.Key
               if($deleted -eq $false) {
                  Format-output -Text "Removing Datastore $($eachDsObj.Name) on host $($hostview.Name)..." -Level "INFO" -Phase "Delete Datastore"
                  Remove-Datastore -Datastore (Get-Datastore -Id $DatastoreId) -VMHost $hostview.Name -Confirm:$false
                  $deleted = $true
               }
            }
         }
      }
   }
}

####################################################################################
#
#.SYNOPSIS
# Create a Vmfs6 datastore
#
#.DESCRIPTION
# Create a New Vmfs6 volume on the give Lun a datastore
#
#.PARAMETER
# LunCanonical = Canonical name of lun
# hostConnected = Hostobjects
#
#.EXAMPLE
#
# $LunCanonical = Get-ScsiLun -Datastore $Datastore | select -Property CanonicalName
# $hostConnected = Get-VMHost -Datastore $Datastore
# Create-Datastore -LunCanonical $LunCanonical -hostConnected $hostConnected
#
#
####################################################################################

Function Create-Datastore {
   [CmdletBinding()]
   Param (
      [Parameter(ValueFromPipeline=$true)] $LunCanonical,
      [Parameter(ValueFromPipeline=$true)] $hostConnected
   )

   Process {
      $device = $LunCanonical
      $isCreated = $false
      $found = $True
      $DatastoreId = 0
      #check if the Datastore is still mounted or not in a busy vCenter
      $cliXmlPath = Join-Path -Path $variableFolder -ChildPath ("Vmfs6Datastore" + ".xml")
      if (Test-Path $cliXmlPath) {
         $newVmfs6Datastore = Import-Clixml $cliXmlPath
         $DatastoreId = Get-Datastore -Id  $newVmfs6Datastore.Id
		 $fileSystemVersion = $DatastoreId.FileSystemVersion.split('.')[0]
      }

      $fileSystemVersion  = $Datastore.FileSystemVersion.split('.')[0]
      while ($found -and ($fileSystemVersion -eq 5)) {
         $srcDs = @()
         $srcDs  += Get-Datastore
         if (!$srcDs.contains($Datastore)) {
            $found = $False
         }
      }
      $hostScsiDisk = @()
      foreach ($mgdHost in $hostConnected) {
         $path = $null
         if ($isCreated -eq $false) { 
            if ($device -is [System.Array]) { 
               $path = $device[0]
            } else {
               $path = $device
            }

            if ($fileSystemVersion -lt 6) {
               New-Datastore -VMHost $mgdHost.Name  -Name $Datastore.Name -Path $path -Vmfs -FileSystemVersion $TargetVmfsVersion | Out-Null
               Format-output -Text "Create new datastore is done" -Level "INFO" -Phase "Datastore Create"
			   #$newVmfs6Datastore | Export-Clixml $cliXmlPath
			   # query the newly created datastore from the mgdHost
               $newVmfs6Datastore = Get-Datastore  -VMHost $mgdHost.Name|where{ $_.name -eq $Datastore.Name }
               $DatastoreId = $newVmfs6Datastore.Id
               $newVmfs6Datastore | Export-Clixml $cliXmlPath
            }

            # if we have more than one unique $device per datastore, we need to expand the current DS.
            if ($device.Count -gt 1) {
               $newDatastoreObj = Get-Datastore -Id $DatastoreId -ErrorAction SilentlyContinue
               $BaseExtent = $newDatastoreObj.ExtensionData.Info.Vmfs.Extent | Select -ExpandProperty DiskName
               $hostSys = Get-View -Id ($newDatastoreObj.ExtensionData.Host | Get-Random | Select -ExpandProperty Key)
               $DataStoreSys = Get-View -Id $hostSys.ConfigManager.DatastoreSystem
               $hostScsiDisk = $DataStoreSys.QueryAvailableDisksForVmfs($newDatastoreObj.ExtensionData.MoRef)
               $existingLuns = Get-ScsiLun -Datastore $newDatastoreObj |select -ExpandProperty CanonicalName|select -Unique
               $newDevList = Compare-Object  $device $existingLuns -PassThru
               foreach ($eachDevice in $newDevList) {
                  # expand the datastore.
                  $canName = Get-ScsiLun -CanonicalName $eachDevice -VmHost $mgdHost
                  $lun = $hostScsiDisk | where{ $BaseExtent -notcontains $_.CanonicalName -and $_.CanonicalName -eq $CanName }
                  $vmfsExtendOpts = $DataStoreSys.QueryVmfsDatastoreExtendOptions($newDatastoreObj.ExtensionData.MoRef, $lun.DevicePath, $null)
   	              $spec = $vmfsExtendOpts.Spec
                  $DataStoreSys.ExtendVmfsDatastore($newDatastoreObj.ExtensionData.MoRef, $spec)
                  Format-output -Text "Extending of datastore is done" -Level "INFO" -Phase "Extend Datastore"
               }
            }
            $isCreated = $true
         }

         #refresh storage on this host and see if the datastore created can be fetched from $mdgHost.
         $mgdHostDatastores = Get-Datastore -VMHost $mgdHost.Name
         if($mgdHostDatastores -contains $DatastoreId ){
            Format-output -Text "The datastore $Datastore found on host: $mgdHost " -Level "INFO" -Phase "VMFS6 Verify"
         }
      }
   }
}

#.ExternalHelp StorageUtility.psm1-help.xml
Function Update-VmfsDatastore {
   [CmdletBinding(SupportsShouldProcess=$true,  ConfirmImpact='High')]
   param (
      [Parameter(Mandatory=$true)][VMware.VimAutomation.ViCore.Types.V1.VIServer]$Server,
      [Parameter(Mandatory=$true, ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Types.V1.DatastoreManagement.Datastore]$Datastore,
      [Parameter(Mandatory=$true)][VMware.VimAutomation.ViCore.Types.V1.DatastoreManagement.Datastore]$TemporaryDatastore,
      [Parameter()][Int32]$TargetVmfsVersion,
      [Switch]$Rollback,
      [Switch]$Resume,
      [Switch]$Force
   )

   $variableFolder = "log_folder_$($Server.Name)_$($Datastore.Name)"
   if(!(Test-Path $variableFolder)) {
      New-Item -ItemType directory -Path $variableFolder | Out-Null
   }

   #check point saved for each stage
   $checkFile = "check$($Server.Name)$($Datastore.Name)"
   $LogTime = Get-Date -Format "MM-dd-yyyy_hh-mm-ss"
   $workingDirectory = (Get-Item -Path $variableFolder -Verbose).FullName
   $logFileName = "Datastore_Upgrade_" + $LogTime + ".log"
   $global:LogFile = Join-Path $workingDirectory $logFileName
   Format-output -Text "Log  folder path: $workingDirectory" -Level "INFO" -Phase  "Preparation"
   Format-output -Text "Log  file path: $global:LogFile" -Level "INFO" -Phase  "Preparation"
   Format-output -Text "Checkpoint file path: $checkFile" -Level "INFO" -Phase  "Preparation"
   $caption = "WARNING !!"
   $warning = "Update VMFS datastore. This operation will delete the datastore to update and will re-create the VMFS 6 datastore using the same LUN. Do yo want to continue?"
   $description = "This operation will delete the datastore to update and will re-create the VMFS 6 datastore using the same LUN."
   Format-output -Text "The datastore $Datastore will deleted and Recreated with VMFS-6." -Level "ERROR" -Phase "Preparation"
   if ($PSCmdlet.ShouldProcess($description, $warning, $caption) -eq $false) {
      Return
   }

   # Check if HBR or SRM is enabled
   $warningCaption = "WARNING !!"
   $warningQuery = "The update to VMFS-6 of VMFS-5 datastore should not be done if HBR or SRM is enabled. Do you still want to continue?"
   Format-output -Text "The datastore $Datastore Should not be part of HBR[Target/Source] / SRM config." -Level "ERROR" -Phase "Preparation"
   if (($Force -Or $PSCmdlet.ShouldContinue($warningQuery, $warningCaption)) -eq $false) {
      Return
   }

   #Workflow begins here

   # Check that target VMFS version is 6. only 6 is supported at present
   if ($TargetVmfsVersion -eq 0 -or $TargetVmfsVersion -ne 6) {
      Format-output -Text "Update to target VMFS version $TargetVmfsVersion is not supported. Only VMFS 6 is supported as target VMFS version" -Level "ERROR" -Phase "Preparation"
      Return
   }

   #Check PrimaryDatastore is present in the Datastore list from VC
   $PrimaryDsStaus = Get-Datastore |where { $_ -eq $Datastore}
   $DatastoreName = $null
   if ($PrimaryDsStaus -ne $null) {
      $PrimaryDatastore = Get-Datastore -Id $Datastore.Id
      if ($PrimaryDatastore -eq $null) {
         Format-output -Text "The datastore $Datastore does not exist or has been removed." -Level "ERROR" -Phase "Preparation"
         Return
      }
      $Datastore | Export-Clixml (Join-Path $variableFolder 'PrimaryDs.xml')
   }

   # Verify thet the specified server is vCenter server
   if (-not $server.ExtensionData.Content.About.Name.Contains("vCenter")) {
      Format-output -Text "The specified server is not a vCenter server." -Level "ERROR" -Phase "Preparation"
      Return
   }

   # Verify the vCenter server is of $targetServerVersion or higher
   $targetServerVersion = New-Object System.Version("6.5.0")
   $vcVersion = New-Object System.Version($Server.Version)
   if ($vcVersion -lt $targetServerVersion) {
      Format-output -Text "The vCenter server is not upgraded to $targetServerVersion." -Level "ERROR" -Phase "Preflight Check"
      Return
   }

   # Verify that $PrimaryDatastore and $TemporaryDatastore are in specified vCenter server
   if ($PrimaryDsStaus -ne $null) {
      $ds = Get-Datastore -Id  $PrimaryDatastore.Id -Server $Server
      if ($ds -eq $null -Or $ds.Uid -ne $PrimaryDatastore.Uid) {
         Format-output -Text "The datastore $PrimaryDatastore is not present in specified vCenter $Server." -Level "ERROR" -Phase "Preflight Check"
         Return
      }
   }
   $tempDs = Get-Datastore -Id  $TemporaryDatastore.Id -Server $Server
   if ($tempDs -eq $null -Or $tempDs.Uid -ne $TemporaryDatastore.Uid) {
      Format-output -Text "The temporary datastore $TemporaryDatastore is not present in specified vCenter $Server." -Level "ERROR" -Phase "Preflight Check"
      Return
   }

   $precheck = $null
   if ( $Resume ) {
      $precheckXml = Join-Path $variableFolder 'precheck.xml'
      if ( Test-Path $precheckXml){
         $precheck = Import-Clixml $precheckXml
	  }
   }

   if ( $precheck -ne 'Done' ) {
      #Verify if first class disks are present in the primary datastore
      $vdisk = Get-VDisk -Datastore $PrimaryDatastore
      if ($vdisk -ne $null) {
         $msgText = "FCD disks can't be moved. Please migrate them then start the commandlet again."
         Format-output -Text "$msg1" -Level "ERROR" -Phase "Preflight Check"
         Return
      }

      #Verify if the Host connected to Primary datastore is part of HA
      $cluster = Get-VMHost -Datastore $PrimaryDatastore | Get-Cluster
      if($cluster) {
         if($cluster.HAEnabled){
            $msg1 = "The host connected to datastore $PrimaryDatastore is part of HA cluster"
            Format-output -Text "$msg1" -Level "INFO" -Phase "Preflight Check"
         }
      }

      # Verify that VADP is disable. If enabled quit
      Format-output -Text "checking if VADP is enabled on any of the VMs" -Level "INFO" -Phase "Preflight Check"
      if ($PrimaryDsStaus -ne $null) {
         $vmList = Get-VM -Datastore $PrimaryDatastore
         Format-output -Text "Checking for VADP enabled VM(s)" -Level "INFO" -Phase "Preflight Check"
         foreach ($vm in $vmList) {
            $disabledMethods = $vm.ExtensionData.DisabledMethod
            if ($disabledMethods -contains 'RelocateVM_Task') {
               Format-output -Text "Cannot move virtual machine $vm because migration is disabled on it." -Level "ERROR" -Phase "Preflight Check"
               Return
            }
         }

         # Verify that SMPFT is not turned ON
         Format-output -Text "checking if SMPFT is enabled on any of the VMs" -Level "INFO" -Phase "Preflight Check"
         foreach ($vm in $vmList) {
            $vmRuntime = $vm.ExtensionData.Runtime
            if ($vmRuntime -ne $null -and $vmRuntime.FaultToleranceState -ne 'notConfigured') {
               Format-output -Text "Cannot move VM $vm because FT is configured for this VM." -Level "ERROR" -Phase "Preflight Check"
               Return
            }
         }
         $precheck = 'Done'
         $precheck | Export-CliXml (Join-Path $variableFolder 'precheck.xml')
      }

      #If PrimaryDs is part of DsCluster the TempDs should be part of same DsCluster
      if( !$Resume ) {
         $primeDsCluster = Get-DatastoreCluster -Datastore $PrimaryDatastore
         $tempDsCluster  = Get-DatastoreCluster -Datastore $TemporaryDatastore
      }
      if (($primeDsCluster -ne $tempDsCluster) -and !$Resume) {
         Format-output -Text "Both Primary/Source Datastore and Temparory Datastore should be part of same sDrs-Cluster : $primeDsCluster" -Level "ERROR" -Phase "Preflight Check"
         Return
      }

      # Verify MSCS, Oracle cluster is not enabled
      Format-output -Text "checking if MSCS/Oracle[RAC] Cluster is configured on any of the VMs" -Level "INFO" -Phase "Preflight Check"
      if ($vmList -ne $null){
         $hdList = Get-HardDisk -VM $vmList
         foreach ($hd in $hdList) {
            if ($hd.ExtensionData.Backing.Sharing -eq 'sharingMultiWriter') {
               $vm = $hd.Parent
               $msg1= "The disk:$hd is in Sharing mode -Multi-writer flag is on. The virtual machine:$vm may be part of a cluster"
               $msg2= "If you want to proceed please disable the cluster settings on VM and -Resume again."
               Format-output -Text "$msg1, $msg2" -Level "ERROR" -Phase "Preflight Check"
               Return
            } else {
               $scsiController = Get-ScsiController -HardDisk $hd
               if (($scsiController.UnitNumber -ge 1) -and ($scsiController.BusSharingMode -ne 'NoSharing')) {
                  $msg1= "The scsi controller:$scsiController attached to the $vm is in sharing mode and hence the VM cannot be migrated. The VM may be part of a cluster"
                  $msg2= "If you want to proceed please disable the cluster settings on VM and -Resume again."
                  Format-output -Text "$msg1,$msg2" -Level "ERROR" -Phase "Preflight Check"
                  Return
               }
            }
         }
      }
   }

   $ErrorActionPreference = "stop"
   $checkCompleted = $null
   $ImportPrimeDs = Import-Clixml (Join-Path $variableFolder 'PrimaryDs.xml')
   $DatastoreName = Get-Datastore -Id $ImportPrimeDs.Id
   $RollBackOption = $Rollback
   if($RollBackOption -eq $true -and $Resume -eq $true) {
      write-host "Both Resume and Staging-rollback cannot be true at the same time. Returning.."
      Return
   }

   if ($Resume -eq $true -or $RollBackOption -eq $true) {
      if (Test-Path $checkFile) {
         $checkCompleted = get-content $checkFile
         $checkCompleted = $checkCompleted -as [int]
         if ($checkCompleted -eq $null -and $Resume -eq $True) {
            $datastoreFsVersion = (Get-Datastore -Id  $DatastoreName.id).FileSystemVersion.split('.')[0]
            if($datastoreFsVersion -eq 6) {
               # In case post vmfs update, if the checkpoint get corrupted then cmdlet can't proceed futher.
               Format-output -Text "Datastore is of VMFS-6 type and " -Level "ERROR" -Phase "Resume-Post Update" 
               Format-output -Text "check-point file is corrupted so cannot proceed further. Manually move back the contents from Temporary Datastore " -Level "ERROR" -Phase "Resume-Post Update" 
               Return
            }
            Format-output -Text "check-point file is corrupted/not found, proceeds from beginning" -Level "INFO" -Phase "Preparation" 
         }
      } elseif ($RollBackOption -eq $false) {
         $datastoreFsVersion = (Get-Datastore -Id  $DatastoreName.id).FileSystemVersion.split('.')[0]
         if ($datastoreFsVersion -eq 6 -and $Resume -eq $true) {
            # In case post vmfs update, if the checkpoint file removed then cmdlet can't proceed futher.
            # If checkpoint file is missing post vmfs update cmdlet don't know the progress, so throw error
            Format-output -Text "Datastore is of VMFS-6 type and " -Level "ERROR" -Phase "Resume-Post Update" 
            Format-output -Text "check-point file is not available so cannot proceed further. Manually move back the contents from Temporary Datastore " -Level "ERROR" -Phase "Resume-Post Update" 
            Return
         } 

         #pre vmfs6 update proceed the resume from beginning
         $checkCompleted = 0
         Format-output -Text "Writing checkCompleted :  $checkCompleted" -Level "INFO" -Phase "Preparation"
         $checkCompleted | out-file $checkFile
      }
   } else {
      $checkCompleted = 0
      $checkCompleted | out-file $checkFile
   }

   if ($RollBackOption -eq $true) {
      if($checkCompleted -eq $null){
         Format-output -Text "check-point file is corrupted/not found cannot roll back. Manually move back the contents from Temporary Datastore " -Level "ERROR" -Phase "Roll Back" 
         Return
      } elseif ($checkCompleted -lt 5) {
         $msgText = "No action performed previously to Roll back, Rollback is not needed"
         Format-output -Text $msgText -Level "INFO" -Phase "Roll-back"
         Return
      }

      $checkCompleted = $checkCompleted + 1
      $dsCheck = Get-Datastore -Id $DatastoreName.Id
      if ($dsCheck.Type.Equals('VMFS')) {
         if (($dsCheck.FileSystemVersion).split('.')[0] -eq 6) {
            $msgText1 = "Datastore is upgraded to VMFS6.Upgrade is in post-upgrade stage,can not rollback. Returning"
            $msgText2 = "At this stage only -Resume is allowed"
            Format-output -Text "$msgText1, $msgText2" -Level "Error" -Phase "Pre-Roll Back Check"
            Return
         }
      } else {
         $msgText = "Datastore to upgrade is not of VMFS type. Returning."
         Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
         Return
      }

      if ($checkCompleted -ge 9) {
         $msgText = "Moving VMs back to original datastore, if present."
         Format-output -Text $msgText -Level "INFO" -Phase "VM Migration"
         $vmList = @()
         $vms = Get-Datastore -Id $TemporaryDatastore.Id | Get-VM

         try {
            if ($vms.Count -gt 0) {
               $RelocTaskList = Concurrent-SvMotion -session $Server -SourceId $TemporaryDatastore.Id -VM $vms -DestinationId $DatastoreName.Id -ParallelTasks 2
               foreach ($eachTask in $RelocTaskList) {
                  if ($eachTask["State"] -ne "Success") { 
                     Format-output -Text "VM failed to Migrate try running the commandlet again with -Resume option." -Level "Error" -Phase "VM Migration"
                     Return
                  }
               }
            }
         } catch {
            $errName = $_.Exception.GetType().FullName
            $errMsg = $_.Exception.Message
            Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Moving Vms during Rollback."
            Format-output -Text "Unable to proceed, try running the commandlet again. If problem persists, move all the VMs from $TemporaryDataStore to $DatastoreName manually and then try again." -Level "ERROR" -Phase "Moving VMs during rollback."
            Return
         }
      }

      if ($checkCompleted -ge 11) {
         $msgText = "Moving orphaned data back to original datastore, if present"
         Format-output -Text $msgText -Level "INFO" -Phase "Roll-back Orphan data"
         try {
            $dsItems = Get-DataStoreItems -DatastoreId $TemporaryDatastore.id
            if (($dsItems -ne $null) -and ($dsItems.Count) -gt 0 ) {
               Format-output -Text "Moving Orphaned items to $DatastoreName" -Level "INFO" -Phase "Copying Orphaned Items"
               Format-output -Text "all the contents already available in $DatastoreName; so skip copy from $TemporaryDatastore" -Level "INFO" -Phase "Copying Orphaned Items"
            }

            #Register template VM[s] back in respective hosts.
            $SrcTemplateMapXml = Join-Path $variableFolder 'SrcTemplateMap.xml'
            if (Test-Path SrcTemplateMapFilepath) {
               $SrcTemplateMap = Import-Clixml $SrcTemplateMapXml
               foreach ($templatePath in $SrcTemplateMap.Keys) {
                  try {
                     $register = New-Template –VMHost $SrcTemplateMap[$templatePath] -TemplateFilePath $templatePath
                     $esxHost= $SrcTemplateMap[$templatePath]
                     Format-output -Text "Template VM registered in host $esxHost " -Level "INFO" -Phase "Template Register" 
                  } catch {
                     $errName = $_.Exception.GetType().FullName
                     if ($errName -match  "AlreadyExists") {
                        Format-output -Text "$templatePath :Template already registered" -Level "INFO" -Phase "Template Register"
                     }
                  }
               }
            } 
         } catch {
            $errName = $_.Exception.GetType().FullName
            $errMsg = $_.Exception.Message
            Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Moving orphaned data"
            Format-output -Text "Unable to proceed, try running the commandlet again. If problem persists, move all the orphaned data from $TemporaryDataStore to $DatastoreName manually and then try again." -Level "ERROR" -Phase "Moving orphaned data."
            Return
         }
      }

      if ($checkCompleted -ge 8) {
         $msgText = "Changing back datastore cluster properties to previous State."
         Format-output -Text $msgText -Level "INFO" -Phase "SDRS Cluster"
         $sdrsClusterXml = Join-Path $variableFolder 'sdrsCluster.xml'
         if (Test-Path $sdrsClusterXml) {
            $dsCluster =  Import-CliXml $sdrsClusterXml
            if ($dsCluster.Name -ne $null) {
               $datastorecluster = Get-DatastoreCluster -Name $dsCluster.Name
            }
         }

         $oldAutomationLevelXml = Join-Path $variableFolder 'oldAutomationLevel.xml'
         if (Test-Path $oldAutomationLevelXml) {
            $oldAutomationLevel = Import-CliXml $oldAutomationLevelXml
         }

         $ioloadbalancedXml = Join-Path $variableFolder 'ioloadbalanced.xml'
         if (Test-Path $ioloadbalancedXml) {
            $ioloadbalanced = Import-CliXml $ioloadbalancedXml
         }

         if ($oldAutomationLevel) {
            Set-DatastoreCluster -DatastoreCluster $datastorecluster -SdrsAutomationLevel $oldAutomationLevel | Out-Null
         }

         if ($ioloadbalanced) {
            Set-DatastoreCluster -DatastoreCluster $datastorecluster -IOLoadBalanceEnabled $ioloadbalanced | Out-Null
         }
      }

      if ($checkCompleted -ge 7) {
         $msgText = "Changing datastore properties to previous State"
         Format-output -Text $msgText -Level "INFO" -Phase "StorageIOControl"

         $ds1iocontrolXml = Join-Path $variableFolder 'ds1iocontrol.xml'
         if (Test-Path $ds1iocontrolXml) {
            $ds1iocontrol = Import-CliXml $ds1iocontrolXml
         }

         $ds2iocontrolXml = Join-Path $variableFolder 'ds2iocontrol.xml'
         if (Test-Path $ds2iocontrolXml) {
            $ds2iocontrol = Import-CliXml $ds2iocontrolXml
         }

         if ($ds1iocontrol) {
            (Get-Datastore -Id  $DatastoreName.Id) | set-datastore -storageIOControlEnabled $ds1iocontrol | Out-Null
         }

         if ($ds2iocontrol) {
            (Get-Datastore -Id  $TemporaryDatastore.Id) | set-datastore -storageIOControlEnable $ds2iocontrol | Out-Null
         }
      }

      if ($checkCompleted -ge 6) {
         $msgText = "Changing cluster properties to previous State"
         Format-output -Text $msgText -Level "INFO" -Phase "Cluster properties"
         $drsMapXml = Join-Path $variableFolder 'drsMap.xml'
         if (Test-Path $drsMapXml) {
            $drsMap = Import-CliXml $drsMapXml
         }

         $clustersXml = Join-Path $variableFolder 'clusters.xml'
         if (Test-Path $clustersXml) {
            $tempClus = Import-CliXml $Set-DatastoreClusterXml
            if ($tempClus.Name -ne $null) {
               $clusters = Get-Cluster -Id $tempClus.Id
            }
         }

         if ($clusters -and $drsMap) {
            foreach ($clus in $clusters) {
               Set-Cluster -Cluster $clus -DrsAutomationLevel $drsMap[$clus.Id] -Confirm:$false | Out-Null
            }
         }
      }

      Format-output -Text "Rollback completed successfully" -Level "INFO" -Phase "Rollback successful"
      Zip-Logs -logdir $variableFolder
      Remove-Item $variableFolder -recurse
      Remove-Item $checkFile
      $errorActionPreference = 'continue'
      Return
   }

   #check 1
   $tempDsItems = Get-DataStoreItems -DatastoreId  $TemporaryDatastore.Id
   try {
      if ($checkCompleted -lt 1) {
         if ($tempDsItems -ne $null -and !$RollBackOption -and !$Resume) {
            Format-output -Text "$TemporaryDatastore is not Empty:$tempDsItems this operation could cause damage to files in $TemporaryDatastore. Returning" -Level "Error" -Phase "Querying Temporary datastore"
            Return
         }

         $checkCompleted = 1
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Querying Temporary datastore"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Querying Temporary datastore"
      Return
   }

   # check 2
   # Check if hosts connected to DS are upgraded
   try {
      if ($checkCompleted -lt 2) {
         $hostConnectedToDs = Get-VMHost -Datastore $Datastore
         $hostObjects = Get-View -VIObject $hostConnectedToDs
         $status = CheckHostVersion -HostObjects $hostObjects -Version $targetServerVersion
         if ($status -eq $false) {
            Format-output -Text "Hosts are not upgraded to $targetServerVersion. Returning " -Level "INFO" -Phase "Preflight Check"
            Return
         }

         # All hosts connected to DS should be also connected to temp DS
         $hostConnectedToTempDs = Get-VMHost -Datastore $TemporaryDatastore
         Format-output -Text "checking if the Target Datastore is accessbile to all the Hosts, as of Source" -Level "INFO" -Phase "Preflight Check"
         if (Compare-Object $hostConnectedToDs $hostConnectedToTempDs -PassThru) {
            $msg1= "Temporary datastore $TemporaryDatstore is not accessible from one or more host(s)"
            $msg2= "Ensure the Hosts connected to Source and Temporary Datastores are same."
            Format-output -Text "$msg1,$msg2" -Level "ERROR" -Phase "Preflight Check" 
            Return
         }

         $checkCompleted = 2
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Querying Hosts"
      $msg1= "Unable to proceed, try running the commandlet again with -Resume option"
      $msg2= "Or Source datastore might be re-created with VMFS-6 filesystem"
      Format-output -Text "$msg1, $msg2" -Level "Error" -Phase "Querying Hosts"
      Return
   }

   # Check if the Temporary DS size is >= Size of DS requiring Vmfs6 upgrade
   $tmpDs = $TemporaryDatastore
   $tmpDsSize = [math]::Round($tmpDs.CapacityMB)

   # Check 3
   try {
      if ($checkCompleted -lt 3) {
         if ($tmpDs.Type.Equals('VMFS')) {
            Format-output -Text "checking if Temporary Datastore is of VMFS-5 type" -Level "INFO" -Phase "Preflight Check"
            if ($tmpDs.FileSystemVersion -lt 6 -and $tmpDs.FileSystemVersion -gt 4.999) {
               $msgText = "$TemporaryDatastore is of VMFS 5 type"
               Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
            } else {
               $msgText = "$TemporaryDatastore is not of VMFS 5 type, Returning."
               Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
               Return
            }
         } else {
            $msgText = "$TemporaryDatastore is not of VMFS 5 type, Returning.."
            Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
            Return
         }

         $checkCompleted = 3
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Querying Temporary datastore"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Querying Temporary datastore"
      Return
   }

   # Check 4
   try {
      if ($checkCompleted -lt 4){
         $datastoreObj1 = Get-Datastore -Id  $DatastoreName.Id
         $dsSize = [math]::Round($datastoreObj1.CapacityMB)
         Format-output -Text "checking Datastores capacity" -Level "INFO" -Phase "Preflight Check"
         if ($tmpDsSize -ge $dsSize) {
            $msgText = "$TemporaryDatastore having Capacity : $tmpDsSize MB Greater or Equal than $DatastoreName capacity : $dsSize MB"
            Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
         } else {
            $msgText = "$TemporaryDatastore having Capacity : $tmpDsSize MB lesser than $DatastoreName capacity : $dsSize MB. Returning.."
            Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
            Return
         }
         $checkCompleted = 4
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Querying Temporary datastore"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Querying Temporary datastore"
      Return
   }

   $RelocTaskList = @()
   $RelocTaskList1 = @()
   $esxMap = @{}
   $esxUser = @{}
   $esxPass = @{}
   $esxLoc = @{}
   $countesx=0
   #check 5
   try {
      if ($checkCompleted -lt 5) {
         $dsCheck = Get-Datastore -Id  $DatastoreName.Id
         if ($dsCheck.Type.Equals('VMFS')) {
            if ($dsCheck.FileSystemVersion -lt 6 -and $dsCheck.FileSystemVersion -gt 4.999) {
               $msgText = "$DatastoreName to upgrade is of VMFS 5 type"
               Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
            } else {
               $msgText = "$DatastoreName to upgrade is not of VMFS 5 type, Returning."
               Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
               Return
            }
         } else {
            $msgText = "$DatastoreName to upgrade is not of VMFS 5 type, Returning.."
            Format-output -Text $msgText -Level "INFO" -Phase "Preflight Check"
            Return
         }
         $checkCompleted = 5
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Querying datastore version"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Querying datastore version"
      Return
   }

   # Setting DRS automation level to manual of cluster.
   $drsAutoLevel = $null
   try {
      # $dsCluster = Get-Datastore -IdCluster -datastore $DatastoreName
      $drsMap = @{}
      $clusters = @()
      # check 6
      if ($checkCompleted -lt 6) {
         #$clusters=get-cluster
         $clusters = Get-Datastore -Id $DatastoreName.Id |Get-VMHost|Get-Cluster
         $datastoreCluster = Get-DatastoreCluster -datastore $DatastoreName
         $msgText = "Changing DrsAutomationLevel of clusters to manual. Will be reverted to original once operation is completed."
         foreach ($clus in $clusters) {
            $drsMap[$clus.Id]=$clus.DrsAutomationLevel
         }
         if ($drsMap -ne $null) {
            $drsMap | Export-CliXml (Join-Path $variableFolder 'drsMap.xml')
         }
         if ($datastoreCluster-ne $null) {
            $datastoreCluster | Export-CliXml (Join-Path $variableFolder 'sdrsCluster.xml')
         }
         if ($clusters -ne $null) {
            $clusters | Export-CliXml (Join-Path $variableFolder 'clusters.xml')
         }
         foreach ($clus in $clusters) {
            if ($clus.DrsEnabled) {
               Format-output -Text $msgText -Level "INFO" -Phase "DRS Cluster Settings"
               Set-Cluster -Cluster $clus -DrsAutomationLevel Manual -confirm:$false | Out-Null
            }
         }
         $checkCompleted = 6
         $checkCompleted | out-file $checkFile
      } else {
         $drsMapXml = Join-Path $variableFolder 'drsMap.xml'
         if (Test-Path $drsMapXml) {
            $drsMap = Import-CliXml $drsMapXml
         } else {
            Format-output -Text "Unable to find the configuration files no changes done to DRS cluster." -Level "INFO" -Phase "Querying DRS"
         }

         $sdrsClusterXml = Join-Path $variableFolder 'sdrsCluster.xml'
         if (Test-Path $sdrsClusterXml) {
            $datastoreCluster = Import-CliXml $sdrsClusterXml
         } else {
            Format-output -Text "Unable to find the configuration files no changes will be done SDRS cluster." -Level "INFO" -Phase "Querying SDRS"
         }

         $clustersXml = Join-Path $variableFolder 'clusters.xml'
         if (Test-Path $clustersXml) {
            $tempClus = Import-CliXml $clustersXml
            if ($tempClus.Name -ne $null) {
               $clusters = get-cluster -Id $tempClus.Id
            }
         } else {
            Format-output -Text "Unable to find the DRS and SDRS configuration files, No action will be take on these clusters." -Level "INFO" -Phase "Querying DRS and SDRS config"
         }
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Capturing settings."
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Capturing settings."
   }

   #check 7 : getting and setting storageIOControlEnabled
   $ds1iocontrol = $false
   $ds2iocontrol = $false
   try {
      if ($checkCompleted -lt 7) {
         $msgText = "Changing storageIOControlEnabled to false. It will be reverted to original once operation is complete."
         $ds1iocontrol=(Get-Datastore -Id $DatastoreName.Id).StorageIOControlEnabled
         $ds2iocontrol=(Get-Datastore -Id $TemporaryDatastore.Id).StorageIOControlEnabled
         $ds1iocontrol | Export-CliXml (Join-Path $variableFolder 'ds1iocontrol.xml')
         $ds2iocontrol | Export-CliXml (Join-Path $variableFolder 'ds2iocontrol.xml')
         if ($ds1iocontrol) {
            Format-output -Text $msgText -Level "INFO" -Phase "StorageIOControl"
            (Get-Datastore -Id  $DatastoreName.Id) | set-datastore -storageIOControlEnabled $false | Out-Null
         }
         if ($ds2iocontrol) {
            Format-output -Text $msgText -Level "INFO" -Phase "StorageIOControl"
            (Get-Datastore -Id $TemporaryDatastore.Id) | set-datastore -storageIOControlEnabled $false | Out-Null
         }
         $checkCompleted = 7
         $checkCompleted | out-file $checkFile
      } else {
         $ds1iocontrolXml = Join-Path $variableFolder 'ds1iocontrol.xml'
         if (Test-Path $ds1iocontrolXml) {
            $ds1iocontrol = Import-CliXml $ds1iocontrolXml
         }

         $ds2iocontrolXml = Join-Path $variableFolder 'ds2iocontrol.xml'
         if (Test-Path $ds2iocontrolXml) {
            $ds2iocontrol = Import-CliXml $ds2iocontrolXml
         }
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "StorageIOControl."
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "StorageIOControl"
      Return
   }

   $tmpDs = Get-Datastore -Id $TemporaryDatastore.Id
   #check 8 : getting and setting stuffs related to datastore cluster
   $datastorecluster = Get-Datastorecluster -Datastore $tmpDs
   $oldAutomationLevel = 0
   $ioloadbalanced = 0
   try {
      if ($checkCompleted -lt 8) {
         if ($datastorecluster) {
            $msgText = "Save properties of datastore cluster. It will be reverted to original once operation is complete."
            Format-output -Text $msgText -Level "INFO" -Phase "DRS Cluster"
            $oldAutomationLevel = $datastorecluster.SdrsAutomationLevel
            $ioloadbalanced = $datastorecluster.IOLoadBalanceEnabled
            $oldAutomationLevel | Export-CliXml (Join-Path $variableFolder 'oldAutomationLevel.xml')
            $ioloadbalanced | Export-CliXml (Join-Path $variableFolder 'ioloadbalanced.xml')
            Set-DatastoreCluster -DatastoreCluster $datastorecluster -SdrsAutomationLevel Manual -IOLoadBalanceEnabled $false | Out-Null
         }
         $checkCompleted = 8
         $checkCompleted | out-file $checkFile
      } else {
         $sdrsClusterXml = Join-Path $variableFolder 'sdrsCluster.xml'
         if (Test-Path $sdrsClusterXml) {
            $dsClusterExists = Import-CliXml $sdrsClusterXml
         }

         if ($dsClusterExists) {
            $oldAutomationLevelXml = Join-Path $variableFolder 'oldAutomationLevel.xml'
            if (Test-Path $oldAutomationLevelXml) {
               $oldAutomationLevel = Import-CliXml $oldAutomationLevelXml
            }

            $ioloadbalancedXml = Join-Path $variableFolder 'ioloadbalanced.xml'
            if (Test-Path $ioloadbalancedXml) {
               $ioloadbalanced = Import-CliXml $ioloadbalancedXml
            } 
         }  
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Moving datastore to same cluster"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move both the datastores to same cluster manually and then try again." -Level "Error" -Phase "Moving datastore to same cluster"
      Return
   }

   # Getting list of VMs present on datastore to migrate.
   $vmList = @()

   #check 9 : Move VMs across datastores
   try {
      if ($checkCompleted -lt 9) {
         # Getting list of VMs present on datastore to migrate.
         $vms = Get-Datastore -Id $DatastoreName.Id | Get-VM
         if ($vms.Count -gt 0) {
            Format-output -Text "Moving list of VMs to temporary datastore." -Level "INFO" -Phase "Preparation"
            Format-output -Text "$vms" -Level "INFO" -Phase "Preparation"
            $RelocTaskList = Concurrent-SvMotion -session $Server -SourceId $Datastore.Id -VM $vms -DestinationId $TemporaryDatastore.Id -ParallelTasks 2 
            foreach ($eachTask in $RelocTaskList) {
               if ($eachTask["State"] -ne "Success") { 
                  Format-output -Text "VM failed to Migrate try running the commandlet again with -Resume option." -Level "Error" -Phase "Preperation"
                  Return
               }
            }

            # if there are any active VMs left , throw error
            $vms = Get-Datastore -Id $DatastoreName.Id | Get-VM
            if ($vms -ne $null) { 
               $vswapItems = Get-DataStoreItems -DatastoreId $DatastoreName.Id -Recurse -fileType $vswap
               if ($vswapItems) {
                  $msgText1 = "There are still active  .vswp :$vswapItems files in $DatastoreName, which can't be migrated "
                  $msgText2 = "Please move these files to other datastore then try again with -Resume option "
                  Format-output -Text "$msgText1, $msgText2"  -Level "ERROR" -Phase "Migraton"
                  Return
               }
               Return
            }            
         } else {
            Format-output -Text "No VirtualMachine is running from $DatastoreName" -Level "INFO" -Phase "Preperation"
         }
         $checkCompleted = 9
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Moving Virtual Machines"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move all the VMs from $DatastoreName to $TemporaryDatastore manually and then try again." -Level "Error" -Phase "Moving Virtual Machines"
      Return
   }

   $tagList = $null
   # check 10 : Datastore Tag
   if ($checkCompleted -lt 10) {
      # Save Tags attached to the Source Datastore
      $msgText = "Getting list of tags assigned to datastore. These tags will be applied to final VMFS 6 datastore."
      try {
         $tagList = Get-TagAssignment -Entity $DatastoreName | Select -ExpandProperty Tag
         if ($tagList) { 
            Format-output -Text $msgText -Level "INFO" -Phase "Datastore Tagging"
            $tagList | Export-CliXml (Join-Path $variableFolder 'TagList.xml')
         }
      } catch {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Datastore Tagging"
         Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Datastore Tagging"
         Return
       } 
       $checkCompleted = 10
       $checkCompleted | out-file $checkFile
   }
	
   # check 11 : move orphaned data to temporary datastore
   $SrcTemplateMap = @{}
   if ($checkCompleted -lt 11) {
      try{
         $vswap = ".vswp"
         $snapShotDelta = "-delta.vmdk"
         $vswapItems = Get-DataStoreItems -DatastoreId $DatastoreName.Id -Recurse -fileType $vswap
         $snapShotDeltaItems = Get-DataStoreItems -DatastoreId $DatastoreName.Id -Recurse -fileType $snapShotDelta
         if ($vswapItems -or $snapShotDeltaItems ) {
            $msgText1 = "SnapShot delta disks:$snapShotDeltaItems (or) .vswp :$vswapItems files can't be moved "
            $msgText2 = "Please move these files to other datastore then try again with -Resume option "
            Format-output -Text "$msgText1, $msgText2"  -Level "ERROR" -Phase "Copying Orphaned Items"
            Format-output -Text "SnapShot delta disks:$snapShotDeltaItems (or) .vswp :$vswapItems" -Level "ERROR" -Phase "Copying Orphaned data"
            Return
         }

         $templates = Get-Template -Datastore $DatastoreName
         #Cache template VM DS PathName and respective Host
         $SrcTemplateMapXml = Join-Path $variableFolder 'SrcTemplateMap.xml'
         if ($Resume -and (Test-Path $SrcTemplateMapXml)) {
            $SrcTemplateMap = Import-Clixml $SrcTemplateMapXml
         }

         foreach ( $eachtemplate in $templates) {
            $hostId=$eachTemplate.HostId
            $hostRef = Get-VMHost -Id $hostId
            $templateVmPath = $eachTemplate.ExtensionData.Config.Files.VmPathName
            $SrcTemplateMap[$templateVmPath] = $hostRef
            Remove-Template  $eachtemplate
            Format-output -Text "Template $eachtemplate unregistered from host $hostRef" -Level "INFO" -Phase "Copying Orphaned data"
            $SrcTemplateMap | Export-CliXml (Join-Path $variableFolder 'SrcTemplateMap.xml')
         }
      } catch [Exception] {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Copying orphaned data"
         Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move all the orphaned data from $DatastoreName to $TemporaryDatastore manually and then try again." -Level "ERROR" -Phase "Copying orphaned data."
         Return
      }
      $dsItems = Get-DataStoreItems -DatastoreId $DatastoreName.Id
      if (($dsItems -ne $null) -and ($dsItems.Count  -gt 0)) {
         # Copy all the orphaned items
         Format-output -Text "copying Orphaned items to $TemporaryDatastore" -Level "INFO" -Phase "Copying Orphaned data"
         $result = Copy-DatastoreItems -SourceDatastoreId $DatastoreName.Id -DestinationDatastoreId $TemporaryDatastore.Id
         if (!$result) {
            Format-output -Text "Try again with -Resume option" -Level "ERROR" -Phase "Copying orphaned data"
            Return
         }
      }
      $checkCompleted = 11
      $checkCompleted | out-file $checkFile
   }

   $hostConnected = @()
   $LunCanonical = @()
   #check 12 : Unmount datastore 
   if ($checkCompleted -lt 12) {
      $msgText = "Unmounting  datastore from all Hosts"
      Format-output -Text $msgText -Level "INFO" -Phase "Unmount Datastore"
      try {
         $hostConnected = Get-VMHost -Datastore $DatastoreName
         $LunCanonical = $DatastoreName.ExtensionData.Info.vmfs.extent|select -ExpandProperty DiskName
         #ExportCLI
         $hostConnected  | Export-CliXml (Join-Path $variableFolder 'srcHosts.xml')
         $LunCanonical   | Export-CliXml (Join-Path $variableFolder 'srcLunCanonical.xml')
         # Unmount the Source datastore from all the host
         Format-output -Text "Unmounting datastore $DSName..." -Level "INFO" -Phase "Unmount Datastore"
         Unmount-Datastore $DatastoreName.Id
      } catch [Exception] {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Unmount Datastore"
         Format-output -Text "Caught the exception while unmounting the datastore. Try again with -Resume option." -Level "ERROR" -Phase "Unmount Datastore"
         Return
      }
      $checkCompleted = 12
      $checkCompleted | out-file $checkFile
   }

   #check 13 : delete datastore 
   #Get the Lun
   if ($checkCompleted -lt 13) {
      $msgText = "Deleting and recreating VMFS-6 Filesystem."
      Format-output -Text $msgText -Level "INFO" -Phase "Delete  Datastore"
      try {
         #Delete the Source datastore from all the host
         Format-output -Text "Deleting datastore $DSName from hosts..." -Level "INFO" -Phase "Delete  Datastore"
         Delete-Datastore $DatastoreName.Id
      } catch [Exception] {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Delete  Datastore"
         Format-output -Text "Caught the exception while  deleting the datastore. Try again with -Resume option." -Level "ERROR" -Phase "Delete  Datastore"
         Return
      }
      $checkCompleted = 13
      $checkCompleted | out-file $checkFile
   }

   #check 14 : Create datastore and create new one with VMFS 6
   #Get the Lun
   if ($checkCompleted -lt 14) {
      $msgText = " Creating VMFS-6 Filesystem"
      Format-output -Text $msgText -Level "INFO" -Phase "Create VMFS-6"
      try {
         if ($Resume) {
            #Read $host $luncan
            $hostConnected = Import-CliXml (Join-Path $variableFolder 'srcHosts.xml')
            $LunCanonical  = Import-CliXml (Join-Path $variableFolder 'srcLunCanonical.xml')
         }  
         Format-output -Text "Creating Datastore..." -Level "INFO" -Phase "Datastore Create"
         Create-Datastore -LunCanonical $LunCanonical -hostConnected $hostConnected    
      } catch [Exception] {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Datastore Create"
         Format-output -Text "Caught the exception creating new datastore. Try again with -Resume option." -Level "ERROR" -Phase "Datastore Create"
         Return
      }
      $checkCompleted = 14
      $checkCompleted | out-file $checkFile
   }

   $DatastoreName = Import-CliXml (Join-Path $variableFolder 'Vmfs6Datastore.xml')

   #check 15 : move the created datastore to cluster 
   #Move Ds to its respective cluster
   try {
      $msgText = "Moving newly created datastore to its original datastore cluster."
      if ($checkCompleted -lt 15) {
         $sdrsClusterXml = Join-Path $variableFolder 'sdrsCluster.xml'
         if ($Resume -and (Test-Path $sdrsClusterXml)) {
            $datastorecluster = Import-CliXml $sdrsClusterXml
         }
         if ($datastorecluster) {
            Format-output -Text $msgText -Level "INFO" -Phase "SDRS Cluster"
            $datastoreObj = Get-Datastore -Id $DatastoreName.Id
            $datastorecluster = Get-DatastoreCluster -Id $datastorecluster.Id
            Move-Datastore $datastoreObj -Destination $datastorecluster | Out-Null
         }  
         $checkCompleted = 15
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Moving datastore"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move the newly created datastore to the same cluster as $TemporaryDatastore" -Level "Error" -Phase "Moving datastore."
      Return
   }

   Format-output -Text "Entering restoration phase.." -Level "INFO" -Phase "Restoring VMs"
   # Getting list of VMs present on temporary datastore.
   $dsArray = @()
   $vms = Get-Datastore -Id $TemporaryDatastore.Id | Get-VM

   # check 16 : move the vms back to original datastore.
   try {
      $msgText = "Moving VMs back to original datastore, if present"
      $msgText = "Moving VMs back to original datastore, if present"
      if ($checkCompleted -lt 16) {
         Format-output -Text $msgText -Level "INFO" -Phase "Migration"
         if ($vms.Count -gt 0) {
            $RelocTaskList = Concurrent-SvMotion -session $Server -SourceId $TemporaryDatastore.Id -VM $vms -DestinationId $DatastoreName.Id -ParallelTasks 2
            foreach ($eachTask in $RelocTaskList) {
               if ($eachTask["State"] -ne "Success") { 
                  Format-output -Text "VM failed to Migrate try running the commandlet again with -Resume option." -Level "Error" -Phase "Migration"
                  Return
               }
            }
         }
         # if there are any active VMs left , throw error
         $vms = Get-Datastore -Id $TemporaryDatastore.Id | Get-VM
         if($vms -ne $null){ 
            Format-output -Text "VM(s)-$vms still left in Datastore $TemporaryDatastore,Try w/ Resume again" -Level "Error" -Phase "Migraton"
            Return
         }
         $checkCompleted = 16
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Moving Virtual Machines"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move all the VMs from $TemporaryDataStore to $DatastoreName manually and then try again." -Level "Error" -Phase "Moving Virtual Machines"
      Return
   }

   # Attaching tags back to original datastore
   if ($checkCompleted -lt 17) {
      # Attach Tags to the datastore
      $TagListXml = Join-Path $variableFolder 'TagList.xml'
      if ($Resume -and (Test-Path $TagListXml)) {
         $tagList = Import-CliXml $TagListXml
      }
 
      $msgText = "Attaching Tags back to original datastore."
      try {
         foreach ($tag in $tagList) {
            $tagObj = $null
            $tagObj = Get-Tag -Name $tag.Name -Category $tag.Category.Name
            $msgText = "Adding back the Tags to Datastore :$DatastoreName.Name"
            Format-output -Text $msgText -Level "INFO" -Phase "Datastore Tags"
            $newTag = New-TagAssignment -Tag $tagObj -Entity $DatastoreName
         }
      } catch {
         $errName = $_.Exception.GetType().FullName
         $errMsg = $_.Exception.Message
         Format-output -Text "$errName, $errMsg" -Level "Error" -Phase "Datastore Tag"
         Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "Error" -Phase "Datastore Tag"
         Return
      }
      $checkCompleted = 17
      $checkCompleted | out-file $checkFile
   }

   # check 17 : move the orphaned data back to original datastore.
   try {
      $msgText = "Moving orphaned data back to original datastore, if present."
      $dsItems = Get-DataStoreItems -DatastoreId $TemporaryDatastore.Id
      if ($checkCompleted -lt 18) {
         Format-output -Text $msgText -Level "INFO" -Phase "Restoring Orphan data"
         if (($dsItems -ne $null) -and ($dsItems.Count) -gt 0) {
            Format-output -Text "Copying Orphaned items to $DatastoreName" -Level "INFO" -Phase "Copying Orphaned Items"
            $result = Copy-DatastoreItems -SourceDatastoreId $TemporaryDatastore.Id -DestinationDatastoreId $DatastoreName.Id
            if (!$result) {
               Format-output -Text "Try again with -Resume option" -Level "ERROR" -Phase "Copying orphaned data"
               Return
            }
            $tempds = Get-Datastore -Id $TemporaryDatastore.Id
            New-PSDrive -Location $tempds -Name tempds -PSProvider VimDatastore -Root "/" | Out-Null
            # Remove contents from temporary Datastore
            Remove-Item tempds:/* -Recurse
         } 

         # Register templateVM(s) back in the respective hosts
         $SrcTemplateMapXml = Join-Path $variableFolder 'SrcTemplateMap.xml'
         if ($Resume -and (Test-Path $SrcTemplateMapXml)) {
            $SrcTemplateMap = Import-Clixml $SrcTemplateMapXml
         }

         foreach ($templatePath in $SrcTemplateMap.Keys) {
            try {
               $register = New-Template –VMHost (Get-VMHost -Name $SrcTemplateMap[$templatePath]) -TemplateFilePath $templatePath
               $esxHost= $SrcTemplateMap[$templatePath]
               Format-output -Text "Template VM registered in host $esxHost " -Level "INFO" -Phase "Template Register"
            } catch {
               $errName = $_.Exception.GetType().FullName
               if ( $errName -match  "AlreadyExists") {
                  Format-output -Text "$templatePath :Template already registered" -Level "INFO" -Phase "Template Register"
               } else {
                  throw  $_.Exception
               }
            }
         }
         $checkCompleted = 18
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Moving orphaned data"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option. If problem persists, move all the orphaned data from $TemporaryDataStore to $DatastoreName manually and then try again." -Level "ERROR" -Phase "Moving orphaned data."
      Return
   }

   # check 18 : Update SRDS properties of cluster.-SDRS
   try {
      if ($checkCompleted -lt 19) {
         $sdrsClusterXml = Join-Path $variableFolder 'sdrsCluster.xml'
         if ($Resume -and (Test-Path $sdrsClusterXml)) {
            $datastorecluster = Import-CliXml $sdrsClusterXml
         }

         if ($datastorecluster) {
            $msgText = "Setting datastore-cluster properties to previous State."
            Format-output -Text "$msgText : $oldAutomationLevel" -Level "INFO" -Phase "SDRS Cluster"
            if ($Resume) {
               $oldAutomationLevel = Import-CliXml (Join-Path $variableFolder 'oldAutomationLevel.xml')
               $ioloadbalanced = Import-CliXml (Join-Path $variableFolder 'ioloadbalanced.xml')
            }
            $datastorecluster = Get-DatastoreCluster -Id $datastorecluster.Id
            Set-DatastoreCluster -DatastoreCluster $datastorecluster -SdrsAutomationLevel $oldAutomationLevel -IOLoadBalanceEnabled $ioloadbalanced | Out-Null
         }
         $checkCompleted = 19
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Reverting to original datastore settings"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "ERROR" -Phase "Reverting to original datastore settings."
      Return
   }
	
   try { 
      # check 20 : set datastore storageIOControlEnabled to previous value.
      if ($checkCompleted -lt 20) {
         $msgText = "Setting datastore properties to previous State."
         $ds1iocontrolXml = Join-Path $variableFolder 'ds1iocontrol.xml'
         if ($Resume -and (Test-Path $ds1iocontrolXml)) {
            $ds1iocontrol = Import-CliXml $ds1iocontrolXml
         }

         $ds2iocontrolXml = Join-Path $variableFolder 'ds2iocontrol.xml'
         if ($Resume -and (Test-Path $ds2iocontrolXml)) {
            $ds2iocontrol = Import-CliXml $ds2iocontrolXml
         }

         Format-output -Text $msgText -Level "INFO" -Phase "Datastore Settings"
         (Get-Datastore -Id  $DatastoreName.Id) | set-datastore -storageIOControlEnabled $ds1iocontrol | Out-Null
         (Get-Datastore -Id  $TemporaryDatastore.Id) | set-datastore -storageIOControlEnable $ds2iocontrol | Out-Null

         $checkCompleted = 20
         $checkCompleted | out-file $checkFile
      }

      # check 21 : set cluster DrsAutomationLevel to previous value. -DRS
      if ($checkCompleted -lt 21) {
         $msgText = "Setting cluster properties to previous State."
         Format-output -Text $msgText -Level "INFO" -Phase "DRS Cluster"
         foreach ($clus in $clusters) {
            if ($clus.DrsEnabled) {
               $drsMapXml = Join-Path $variableFolder 'drsMap.xml'
               if ($Resume -and (Test-Path $drsMapXml)) {
                  $drsMap = Import-Clixml $drsMapXml
               }

               Set-Cluster -Cluster $clus -DrsAutomationLevel $drsMap[$clus.Id] -Confirm:$false | Out-Null
            }
         }
         $checkCompleted = 21
         $checkCompleted | out-file $checkFile
      }
   } catch {
      $errName = $_.Exception.GetType().FullName
      $errMsg = $_.Exception.Message
      Format-output -Text "$errName, $errMsg" -Level "ERROR" -Phase "Reverting to original datastore and datastore cluster settings"
      Format-output -Text "Unable to proceed, try running the commandlet again with -Resume option." -Level "ERROR" -Phase "Reverting to original datastore and datastore-cluster settings."
      Return
   }

   Format-output -Text "Datastore upgraded successfully" -Level "INFO" -Phase "Upgrade successful"
   Format-output -Text "Zip the log directory " -Level "INFO" -Phase "Upgrade successful"
   Zip-Logs -logdir $variableFolder
   Remove-Item $variableFolder -Recurse
   Remove-Item $checkFile
   $errorActionPreference = 'continue'
}
# SIG # Begin signature block
# MIIpiAYJKoZIhvcNAQcCoIIpeTCCKXUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDMaSkaPmTZxUkk
# a0tk1fQG1z4kRCD9WEhPcxiseqVfE6CCDnQwggawMIIEmKADAgECAhAIrUCyYNKc
# TJ9ezam9k67ZMA0GCSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0z
# NjA0MjgyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDVtC9C0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0
# JAfhS0/TeEP0F9ce2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJr
# Q5qZ8sU7H/Lvy0daE6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhF
# LqGfLOEYwhrMxe6TSXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+F
# LEikVoQ11vkunKoAFdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh
# 3K3kGKDYwSNHR7OhD26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJ
# wZPt4bRc4G/rJvmM1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQay
# g9Rc9hUZTO1i4F4z8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbI
# YViY9XwCFjyDKK05huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchAp
# QfDVxW0mdmgRQRNYmtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRro
# OBl8ZhzNeDhFMJlP/2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IB
# WTCCAVUwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+
# YXsIiGX0TkIwHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAC
# hjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAED
# MAgGBmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql
# +Eg08yy25nRm95RysQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFF
# UP2cvbaF4HZ+N3HLIvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1h
# mYFW9snjdufE5BtfQ/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3Ryw
# YFzzDaju4ImhvTnhOE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5Ubdld
# AhQfQDN8A+KVssIhdXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw
# 8MzK7/0pNVwfiThV9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnP
# LqR0kq3bPKSchh/jwVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatE
# QOON8BUozu3xGFYHKi8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bn
# KD+sEq6lLyJsQfmCXBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQji
# WQ1tygVQK+pKHJ6l/aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbq
# yK+p/pQd52MbOoZWeE4wgge8MIIFpKADAgECAhAGQAJb/wxIlzKZ1GMgg8N7MA0G
# CSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjQwMzI4MDAwMDAwWhcNMjcwMzMw
# MjM1OTU5WjCBxDETMBEGCysGAQQBgjc8AgEDEwJVUzEZMBcGCysGAQQBgjc8AgEC
# EwhEZWxhd2FyZTEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xEDAOBgNV
# BAUTBzY2MTAxMTcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlhMREw
# DwYDVQQHEwhTYW4gSm9zZTEVMBMGA1UEChMMQnJvYWRjb20gSW5jMRUwEwYDVQQD
# EwxCcm9hZGNvbSBJbmMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC6
# 8C+jJxKfxp9c1A6fghwSNjnvV+Y1my2XmTHEPmk7COFTWw1VRBZBtv/zUXrSStlW
# 9Qqqp48wk+H+H5oM0qL9jsUQ6wAJpmjt33F3xvKqc8ehzVZLXUEACQBXTo30Hnbh
# bcacKAyX9sGByGqKlR6cHHrEebSWMoxOO6TOgYg06xfeYzxpx8HqMQjOKgNEbh4c
# m1Yx+ER/4BmWmYcvVHR9KtXwJWxmzUJCaS5OB9lp8JqO5+uAHvpGtQEAb39/h/vy
# 290isCYw16/uaLOz5Epchv5fogTBTh4o6SXWHam03FfMNVbmbMVuciTzfPSDt0i5
# xQWYtVkwVU+NGE4XUutX4zbaing53QYKNAa+NW9FiWcaoEwE1qTvk7ilsucPzdqC
# ikQpHyaaGCzHoDhveSLiJKgKRiDqee8KXfa/hkCoat9AtCihyd899kJ1kSlTO9fk
# ci5/CdKwmwXQIKh6OPueKr+OJ69XPx0V+RaaMAkkVtFb7/VwecFmFgsXFkAK8ulP
# aGYyIFOFqLMqH8ZuKiLVP5HkxDgSitJcWbaSf89TJuxNqh0vV1k4iwaQpcmQZhPK
# 49pNlj5j0cyw8B+xTYNDwnKvyoWgqKAb2cfzc6pCLk2GJLBwakKZ5YKC50XdhPlS
# yrqlLTb5otZRoYWFGKL1SqxxrBjRqg4qp1RvuxRcBQIDAQABo4ICAjCCAf4wHwYD
# VR0jBBgwFoAUaDfg67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFL9ZTMS/Phgv
# GnXZm3XOrmDoJSIfMD0GA1UdIAQ2MDQwMgYFZ4EMAQMwKTAnBggrBgEFBQcCARYb
# aHR0cDovL3d3dy5kaWdpY2VydC5jb20vQ1BTMA4GA1UdDwEB/wQEAwIHgDATBgNV
# HSUEDDAKBggrBgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQw
# OTZTSEEzODQyMDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAy
# MUNBMS5jcmwwgZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNI
# QTM4NDIwMjFDQTEuY3J0MAkGA1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggIBAMLk
# M/5BZB1j2xjjR9IkyDYtLrqS9IztErzl4ogf2dXuAgBJP1EKm/EN4oOi/BHxLW0T
# VuclGZ3aEa3/n3UlHxqmvKm+4elD5oh4sEOm7+J7ECV0HobeZhRiLmdyla1Mqbxw
# xp56AVvhG/++nf+AVzw95c671a3kb+6VXMDzZK1qcUh6zyLklZ/vfjKipry9KgMR
# sXd81I+PRr+99iRI+5pUsF7ixmS4vTldNh2r/VRFKLtXtTefZ20Q55Efu/8NefJf
# fD/+LLmHszB3LRlguFYOUGon7q8eQKi20PMW6PQb8az4mn6MfA1Y2x+L7HFDiy//
# VMOy5DqcKOHWqz/NZr7/VEPtywoLbHlUwNJyFY0wnQhzvPCg67YpDEYERDnggtpe
# OchKlJoqLKQInq6xDLTtco+ynR6IHnWRcz+oYhm6TdvRcmP7giiqObKEFXQwLsjS
# HsqRluk2FQ4DhG63+8gyD4rKQVoybP0obE7Gi2RYHOT0qwPos6GklZraht/capa7
# wos1gNKXJL7G6BaCXQWCyakT76ZOJOdHzHjJ2n+yBgKWWGBv186nrP5nfuRu0vJE
# HG74cy5oRwe3vme6ztPQy9VSgSrP+g67bZ6yPe+z09T7NczW4aXrXbMUdTb02zKQ
# sK8WEKfcvzBmZ115SwMuf3g34C5yRhOsWInfosmAMYIaajCCGmYCAQEwfTBpMQsw
# CQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERp
# Z2lDZXJ0IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIw
# MjEgQ0ExAhAGQAJb/wxIlzKZ1GMgg8N7MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPqN+Trg/KLl3q8R
# etJjAcGduA6iCE39/hSYi42PkpM+MA0GCSqGSIb3DQEBAQUABIICAKzlcvltIIW9
# AsqiVuDqn9VZakdT4ogvADHLkrjqIsQbedD+nSnQrZBH7hzzDIgH6m9GKT5zCN5U
# UvpVC7xNXhpRCHIgbmYZ/Ia7AaNT/HqfOtG1mpuEAAA9MifPyZQTA/zbq6YZ4UTD
# tVgNpdlNK2i+8i2DCusxWgTjXkLBFXB7B28/ZpX8i0MdESeLQegjTZw2sVP+Mz1W
# yABOQS6eDmBtkGlscxCuQxV0dadXkWdbWjao8eQwU8yrj82Yb28IFmMvELMObRkJ
# /eA4qgnP+/HzVutjLs362oaijXbQzgeZosr6Lwp7rKOXZVo71xKCM5FP8FKfSbAN
# 2lovTFtiJtTwHMqz+Pl7QAyC5kUCY5fNTgCUBFGpm9NQKsT9UbnknEaMmrMnzXWi
# 37BoGi1g3P0puQ1jYXQ0BmUBFEc/fm/DzQvxdFSfiZbFDeW6L/2IAIYfBFTjdwy7
# t90UHSLINSW5u92Yn+Ydm9uoMfoHb8bQ+O4xvWNPLBvrIAhBL/65F59vsP5/Lb6T
# PQEYLraoJl7B0aloyK53lMKAG54bvjg/VyEj//0TkVbRhh0bEuKAlTE8r+dZ+q8J
# /o+dtlEN4Mmw6ls4b7tPWW2BLFMgcwx+HIHT/8WrygFAMe24vMfMxq13/iOFtkp4
# QEVQT9T9ckRtqY9lWzU6lJRXMZQM5pUGoYIXQDCCFzwGCisGAQQBgjcDAwExghcs
# MIIXKAYJKoZIhvcNAQcCoIIXGTCCFxUCAQMxDzANBglghkgBZQMEAgEFADB4Bgsq
# hkiG9w0BCRABBKBpBGcwZQIBAQYJYIZIAYb9bAcBMDEwDQYJYIZIAWUDBAIBBQAE
# IPUrPnCNlWV4Ig8CJVD9pvJdVWV3IlI09K05KlR5jDLVAhEA/0RO3BlGUV3oZY9x
# Ovn7FBgPMjAyNDA3MjQxOTQ4MzVaoIITCTCCBsIwggSqoAMCAQICEAVEr/OUnQg5
# pr/bP1/lYRYwDQYJKoZIhvcNAQELBQAwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoT
# DkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJT
# QTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQTAeFw0yMzA3MTQwMDAwMDBaFw0z
# NDEwMTMyMzU5NTlaMEgxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjEgMB4GA1UEAxMXRGlnaUNlcnQgVGltZXN0YW1wIDIwMjMwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCjU0WHHYOOW6w+VLMj4M+f1+XS512hDgnc
# L0ijl3o7Kpxn3GIVWMGpkxGnzaqyat0QKYoeYmNp01icNXG/OpfrlFCPHCDqx5o7
# L5Zm42nnaf5bw9YrIBzBl5S0pVCB8s/LB6YwaMqDQtr8fwkklKSCGtpqutg7yl3e
# GRiF+0XqDWFsnf5xXsQGmjzwxS55DxtmUuPI1j5f2kPThPXQx/ZILV5FdZZ1/t0Q
# oRuDwbjmUpW1R9d4KTlr4HhZl+NEK0rVlc7vCBfqgmRN/yPjyobutKQhZHDr1eWg
# 2mOzLukF7qr2JPUdvJscsrdf3/Dudn0xmWVHVZ1KJC+sK5e+n+T9e3M+Mu5SNPvU
# u+vUoCw0m+PebmQZBzcBkQ8ctVHNqkxmg4hoYru8QRt4GW3k2Q/gWEH72LEs4VGv
# tK0VBhTqYggT02kefGRNnQ/fztFejKqrUBXJs8q818Q7aESjpTtC/XN97t0K/3k0
# EH6mXApYTAA+hWl1x4Nk1nXNjxJ2VqUk+tfEayG66B80mC866msBsPf7Kobse1I4
# qZgJoXGybHGvPrhvltXhEBP+YUcKjP7wtsfVx95sJPC/QoLKoHE9nJKTBLRpcCcN
# T7e1NtHJXwikcKPsCvERLmTgyyIryvEoEyFJUX4GZtM7vvrrkTjYUQfKlLfiUKHz
# OtOKg8tAewIDAQABo4IBizCCAYcwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwIAYDVR0gBBkwFzAIBgZngQwBBAIw
# CwYJYIZIAYb9bAcBMB8GA1UdIwQYMBaAFLoW2W1NhS9zKXaaL3WMaiCPnshvMB0G
# A1UdDgQWBBSltu8T5+/N0GSh1VapZTGj3tXjSTBaBgNVHR8EUzBRME+gTaBLhklo
# dHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRSU0E0MDk2
# U0hBMjU2VGltZVN0YW1waW5nQ0EuY3JsMIGQBggrBgEFBQcBAQSBgzCBgDAkBggr
# BgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFgGCCsGAQUFBzAChkxo
# dHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRSU0E0
# MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCB
# GtbeoKm1mBe8cI1PijxonNgl/8ss5M3qXSKS7IwiAqm4z4Co2efjxe0mgopxLxjd
# TrbebNfhYJwr7e09SI64a7p8Xb3CYTdoSXej65CqEtcnhfOOHpLawkA4n13IoC4l
# eCWdKgV6hCmYtld5j9smViuw86e9NwzYmHZPVrlSwradOKmB521BXIxp0bkrxMZ7
# z5z6eOKTGnaiaXXTUOREEr4gDZ6pRND45Ul3CFohxbTPmJUaVLq5vMFpGbrPFvKD
# NzRusEEm3d5al08zjdSNd311RaGlWCZqA0Xe2VC1UIyvVr1MxeFGxSjTredDAHDe
# zJieGYkD6tSRN+9NUvPJYCHEVkft2hFLjDLDiOZY4rbbPvlfsELWj+MXkdGqwFXj
# hr+sJyxB0JozSqg21Llyln6XeThIX8rC3D0y33XWNmdaifj2p8flTzU8AL2+nCps
# eQHc2kTmOt44OwdeOVj0fHMxVaCAEcsUDH6uvP6k63llqmjWIso765qCNVcoFstp
# 8jKastLYOrixRoZruhf9xHdsFWyuq69zOuhJRrfVf8y2OMDY7Bz1tqG4QyzfTkx9
# HmhwwHcK1ALgXGC7KP845VJa1qwXIiNO9OzTF/tQa/8Hdx9xl0RBybhG02wyfFgv
# Z0dl5Rtztpn5aywGRu9BHvDwX+Db2a2QgESvgBBBijCCBq4wggSWoAMCAQICEAc2
# N7ckVHzYR6z9KGYqXlswDQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMCVVMxFTAT
# BgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEh
# MB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4XDTIyMDMyMzAwMDAw
# MFoXDTM3MDMyMjIzNTk1OVowYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYg
# U0hBMjU2IFRpbWVTdGFtcGluZyBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAMaGNQZJs8E9cklRVcclA8TykTepl1Gh1tKD0Z5Mom2gsMyD+Vr2EaFE
# FUJfpIjzaPp985yJC3+dH54PMx9QEwsmc5Zt+FeoAn39Q7SE2hHxc7Gz7iuAhIoi
# GN/r2j3EF3+rGSs+QtxnjupRPfDWVtTnKC3r07G1decfBmWNlCnT2exp39mQh0YA
# e9tEQYncfGpXevA3eZ9drMvohGS0UvJ2R/dhgxndX7RUCyFobjchu0CsX7LeSn3O
# 9TkSZ+8OpWNs5KbFHc02DVzV5huowWR0QKfAcsW6Th+xtVhNef7Xj3OTrCw54qVI
# 1vCwMROpVymWJy71h6aPTnYVVSZwmCZ/oBpHIEPjQ2OAe3VuJyWQmDo4EbP29p7m
# O1vsgd4iFNmCKseSv6De4z6ic/rnH1pslPJSlRErWHRAKKtzQ87fSqEcazjFKfPK
# qpZzQmiftkaznTqj1QPgv/CiPMpC3BhIfxQ0z9JMq++bPf4OuGQq+nUoJEHtQr8F
# nGZJUlD0UfM2SU2LINIsVzV5K6jzRWC8I41Y99xh3pP+OcD5sjClTNfpmEpYPtMD
# iP6zj9NeS3YSUZPJjAw7W4oiqMEmCPkUEBIDfV8ju2TjY+Cm4T72wnSyPx4Jduyr
# XUZ14mCjWAkBKAAOhFTuzuldyF4wEr1GnrXTdrnSDmuZDNIztM2xAgMBAAGjggFd
# MIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBS6FtltTYUvcyl2mi91
# jGogj57IbzAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8B
# Af8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgwdwYIKwYBBQUHAQEEazBpMCQG
# CCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQQYIKwYBBQUHMAKG
# NWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290
# RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQC
# MAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAfVmOwJO2b5ipRCIBfmbW
# 2CFC4bAYLhBNE88wU86/GPvHUF3iSyn7cIoNqilp/GnBzx0H6T5gyNgL5Vxb122H
# +oQgJTQxZ822EpZvxFBMYh0MCIKoFr2pVs8Vc40BIiXOlWk/R3f7cnQU1/+rT4os
# equFzUNf7WC2qk+RZp4snuCKrOX9jLxkJodskr2dfNBwCnzvqLx1T7pa96kQsl3p
# /yhUifDVinF2ZdrM8HKjI/rAJ4JErpknG6skHibBt94q6/aesXmZgaNWhqsKRcnf
# xI2g55j7+6adcq/Ex8HBanHZxhOACcS2n82HhyS7T6NJuXdmkfFynOlLAlKnN36T
# U6w7HQhJD5TNOXrd/yVjmScsPT9rp/Fmw0HNT7ZAmyEhQNC3EyTN3B14OuSereU0
# cZLXJmvkOHOrpgFPvT87eK1MrfvElXvtCl8zOYdBeHo46Zzh3SP9HSjTx/no8Zhf
# +yvYfvJGnXUsHicsJttvFXseGYs2uJPU5vIXmVnKcPA3v5gA3yAWTyf7YGcWoWa6
# 3VXAOimGsJigK+2VQbc61RWYMbRiCQ8KvYHZE/6/pNHzV9m8BPqC3jLfBInwAM1d
# wvnQI38AC+R2AibZ8GV2QqYphwlHK+Z/GqSFD/yYlvZVVCsfgPrA8g4r5db7qS9E
# FUrnEw4d2zc4GqEr9u3WfPwwggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBha
# MA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lD
# ZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDky
# MzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAX
# BgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0
# ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo
# 3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutW
# xpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQ
# RBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nP
# zaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6P
# gNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEB
# fCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3
# wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2
# mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2
# Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF1
# 3nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+d
# IPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMB
# Af8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSME
# GDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYB
# BQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20w
# QwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2Ny
# bDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNV
# HSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9
# thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4
# offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cG
# AxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9
# HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvP
# J6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXiji
# uZQxggN2MIIDcgIBATB3MGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2Vy
# dCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1c3RlZCBHNCBSU0E0MDk2IFNI
# QTI1NiBUaW1lU3RhbXBpbmcgQ0ECEAVEr/OUnQg5pr/bP1/lYRYwDQYJYIZIAWUD
# BAIBBQCggdEwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3DQEJ
# BTEPFw0yNDA3MjQxOTQ4MzVaMCsGCyqGSIb3DQEJEAIMMRwwGjAYMBYEFGbwKzLC
# wskPgl3OqorJxk8ZnM9AMC8GCSqGSIb3DQEJBDEiBCCMoPVPTBhtlFZtkc2UA2QL
# k7JKXhGr+uV1anF0sEJEeTA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCDS9uRt7XQi
# zNHUQFdoQTZvgoraVZquMxavTRqa1Ax4KDANBgkqhkiG9w0BAQEFAASCAgBdMvtI
# DgS1GaZ9Q33ZOY8PbZYv53aq9GVr+cd9kRO4p5xePqx1sgXboSWcBsMmQalgNvbU
# KWBc6/ZR3iE9FzvvHiYi1loXuKC7VHkHXjKg1bRtENB7Y0IJtRoziNc1UwiaxTVX
# qLCXLq6Ba7xKGToq25GPegkexiYReKM19utWLEBjISFGZIkRf/0Vojv3xuVT+6xE
# yCTBgYJ5iboleSsVKXV+1BWTw47iVEpZcMGq8E8fpXcea5XnI9+oAgWEW9trZBP1
# L1qgvkQcAKWFI7wuRPpAqG488ep7dvNVJn9pqnV7GYBbU1zOhB6L9i5MKJvk9+ob
# Yv10/mM0kwK3Y8sawHQvINtJZ1GPOvhlBo2XDGoI2KNOi37cMZyq5bT5Y4Rij/Ba
# EQkWgE55qr0iSQS1mTkFuKhGLN3k11Zl3/gxvnFHLYKeMsY6xAn5/VDmWAwpka39
# gHOHMDZjv4tgdz5/6qW4vk358ToJNBSX4c2pgBaDN1+hj4msoGj4mRUovRy5NzKU
# b2vYwOvYjDxnSZvb3OMI+mLFeVoLnIeiuJeChS8gXJC/R2RAqPJCoSkFVyYoamEa
# k2RKgCuU+zOARGbPEGa22SFLEdsd9vYNnf4P750ays8aOEVZHZcQMmvzHtimMdxN
# D1tiP4rLmsq+6w/bNsgTUJwe7UvVu41BMUYAvg==
# SIG # End signature block
