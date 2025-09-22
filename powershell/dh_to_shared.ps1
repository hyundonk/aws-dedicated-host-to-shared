# PowerShell script for EC2 instance migration from dedicated host to shared tenancy
# It performs the following:
# 1. Gets rows of instance_id from input CSV file
# 2. For each instance, check if EC2 condition is ok to proceed migration. Specifically it checks if:
#    - the instance is in running state
#    - the instance is on a dedicated host
# 3. For each instance, starts a background job that does:
#    - Stop the instance and wait until it becomes 'stopped' state
#    - Modify the instance placement to shared tenancy
#    - Start the instance and wait until it becomes 'running' state

param(
    [Parameter(Mandatory=$true)]
    [string]$CsvFilePath
)

# Function to change tenancy to shared
function Change-TenancyToShared {
    param([string]$InstanceId)
    
    $InstanceId = $InstanceId.Trim()
    
    try {
        # Stop the EC2 instance
        Write-Host "Stopping instance $InstanceId..."
        aws ec2 stop-instances --instance-ids $InstanceId | Out-Null
        
        # Wait for instance to stop with timeout (8 minutes)
        $startTime = Get-Date
        Start-Sleep -Seconds 10
        
        while ($true) {
            $response = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0].State.Name' --output text
            
            if ($response -eq "stopped") {
                break
            }
            elseif (((Get-Date) - $startTime).TotalSeconds -gt 480) {
                Write-Host "Stopping instance $InstanceId forcefully..."
                aws ec2 stop-instances --instance-ids $InstanceId --force | Out-Null
                $startTime = Get-Date
            }
            else {
                Write-Host "Still Stopping $InstanceId state: $response..."
            }
            Start-Sleep -Seconds 10
        }
        
        Write-Host "Instance $InstanceId stopped."
        
        # Modify instance placement to shared tenancy
        $modifyResult = aws ec2 modify-instance-placement --instance-id $InstanceId --tenancy default --query 'Return' --output text
        
        if ($modifyResult -eq "True") {
            Write-Host "Successfully modified instance $InstanceId to shared tenancy"
        }
        else {
            Write-Host "Failed to modify instance placement $InstanceId"
            return
        }
        
        # Start the instance with shared tenancy
        Write-Host "Starting instance $InstanceId with shared tenancy..."
        aws ec2 start-instances --instance-ids $InstanceId | Out-Null
        
        # Wait for instance to start running
        Start-Sleep -Seconds 10
        while ($true) {
            $response = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0].State.Name' --output text
            
            if ($response -eq "running") {
                break
            }
            else {
                Write-Host "Still Starting instance $InstanceId with shared tenancy, state: $response..."
            }
            Start-Sleep -Seconds 10
        }
        
        Write-Host "Instance $InstanceId started and running with shared tenancy."
    }
    catch {
        Write-Host "Error processing instance $InstanceId : $($_.Exception.Message)"
    }
}

# Function to check instance conditions
function Test-InstanceConditions {
    param([string]$InstanceId)
    
    try {
        # Get instance details
        $instanceData = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0]' --output json | ConvertFrom-Json
        
        # Check if instance is on a dedicated host
        if (-not $instanceData.Placement.HostId) {
            Write-Host "Instance $InstanceId is not on a Dedicated Host."
            return $false
        }
        
        # Check tenancy
        if ($instanceData.Placement.Tenancy -ne "host") {
            Write-Host "Instance $InstanceId does not have tenancy set to 'host'."
            return $false
        }
        
        # Check if instance is running
        if ($instanceData.State.Name -ne "running") {
            Write-Host "Instance $InstanceId is not in the 'running' state."
            return $false
        }
        
        Write-Host "Instance $InstanceId is in 'running' state on a dedicated-host."
        return $true
    }
    catch {
        Write-Host "Error checking instance conditions: $($_.Exception.Message)"
        return $false
    }
}

# Function to check conditions for all instances
function Test-AllConditions {
    param([string]$FilePath)
    
    $csvContent = Get-Content -Path $FilePath
    
    foreach ($line in $csvContent) {
        $instanceId = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($instanceId)) {
            Write-Host "Skipping invalid row. Expected format: instance_id"
            continue
        }
        Test-InstanceConditions -InstanceId $instanceId
    }
}

# Function to prompt user
function Get-UserConfirmation {
    while ($true) {
        $proceed = Read-Host "Pre-condition check completed. Do you want to proceed? (y/n)"
        if ($proceed.ToLower() -eq 'y') {
            break
        }
        elseif ($proceed.ToLower() -eq 'n') {
            Write-Host "Exiting."
            exit 1
        }
        else {
            Write-Host "Invalid input. Please enter 'y' or 'n'."
        }
    }
}

# Function to detect UTF-8 BOM
function Test-Utf8Bom {
    param([string]$FilePath)
    
    $absolutePath = Resolve-Path $FilePath
    $bytes = [System.IO.File]::ReadAllBytes($absolutePath)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

# Main function
function Main {
    param([string]$CsvFilePath)
    
    if ([string]::IsNullOrWhiteSpace($CsvFilePath)) {
        Write-Host "Error: CSV file path is required."
        exit 1
    }
    
    if (-not (Test-Path $CsvFilePath)) {
        Write-Host "Error: File '$CsvFilePath' not found."
        exit 1
    }
    
    try {
        # Check for UTF-8 BOM
        if (Test-Utf8Bom -FilePath $CsvFilePath) {
            Write-Host "The file $CsvFilePath contains a UTF-8 BOM."
        }
        
        # Check conditions
        Test-AllConditions -FilePath $CsvFilePath
        
        # Get user confirmation
        Get-UserConfirmation
        
        # Process instances in parallel using runspaces
        $csvContent = Get-Content -Path $CsvFilePath
        # Recommended values: 5-10 (small batches), 15-25 (200+ instances), 30-50 (enterprise)
        # Consider AWS API limits, system resources, and network bandwidth
        $maxThreads = 120  # Aggressive parallelization for 20-minute target (200 instances)
        
        # Create shared output queue for real-time logging
        $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        
        # Create runspace pool
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxThreads)
        $runspacePool.Open()
        
        # Script block for parallel execution with real-time output
        $scriptBlock = {
            param($InstanceId, $OutputQueue)
            
            $InstanceId = $InstanceId.Trim()
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            
            try {
                # Random initial delay to spread API calls (0-15 seconds for 120 threads)
                $randomDelay = Get-Random -Minimum 0 -Maximum 15000
                Start-Sleep -Milliseconds $randomDelay
                
                # Step 1: Stop the EC2 instance
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 1/4: Initiating stop...")
                aws ec2 stop-instances --instance-ids $InstanceId | Out-Null
                
                # Wait for instance to stop with timeout (8 minutes)
                $startTime = Get-Date
                Start-Sleep -Seconds 10
                
                while ($true) {
                    $response = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0].State.Name' --output text
                    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    
                    if ($response -eq "stopped") {
                        $OutputQueue.Enqueue("[$currentTime] [$InstanceId] STEP 1/5: STOPPED successfully")
                        break
                    }
                    elseif (((Get-Date) - $startTime).TotalSeconds -gt 480) {
                        $OutputQueue.Enqueue("[$currentTime] [$InstanceId] STEP 1/5: Force stopping (timeout reached)...")
                        aws ec2 stop-instances --instance-ids $InstanceId --force | Out-Null
                        $startTime = Get-Date
                    }
                    else {
                        $OutputQueue.Enqueue("[$currentTime] [$InstanceId] STEP 1/5: Stopping... (state: $response)")
                    }
                    Start-Sleep -Seconds 10
                }
                
                # Step 2: Modify instance placement (with larger random delay)
                Start-Sleep -Milliseconds (Get-Random -Minimum 1000 -Maximum 3000)
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 2/5: Modifying tenancy to shared...")
                $modifyResult = aws ec2 modify-instance-placement --instance-id $InstanceId --tenancy default --query 'Return' --output text
                
                if ($modifyResult -eq "True") {
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 2/5: MODIFIED to shared tenancy successfully")
                }
                else {
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 2/5: FAILED to modify tenancy")
                    return
                }
                

                # Step 3: Construct instance ARN and create billing code conversion job
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $region = $env:AWS_REGION
                $accountId = aws sts get-caller-identity --query Account --output text
                $instanceArn = "arn:aws:ec2:${region}:${accountId}:instance/${InstanceId}"
                
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 3/5: Constructed ARN: $instanceArn")
                
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 3/5: Creating billing code conversion job...")
                $conversionResult = aws license-manager create-license-conversion-task-for-resource `
                    --resource-arn $instanceArn `
                    --source-license-context UsageOperation=RunInstances:0800 `
                    --destination-license-context UsageOperation=RunInstances:0002 | ConvertFrom-Json

                $taskId = $conversionResult.LicenseConversionTaskId
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 3/5: Created conversion task: $taskId")

                # Wait for conversion task to complete
                do {
                    Start-Sleep -Seconds 30
                    $taskStatus = aws license-manager get-license-conversion-task `
                        --license-conversion-task-id $taskId | ConvertFrom-Json
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 3/5: Conversion status: $($taskStatus.Status)")
                } while ($taskStatus.Status -notin @("SUCCEEDED", "FAILED"))

                if ($taskStatus.Status -eq "SUCCEEDED") {
                    $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 3/5: License conversion completed successfully")
                } else {
                    $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 3/5: License conversion failed")
                    return
                }

                # Step 4: Start the instance (with larger random delay)
                Start-Sleep -Milliseconds (Get-Random -Minimum 1000 -Maximum 3000)
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 4/5: Initiating start...")
                aws ec2 start-instances --instance-ids $InstanceId | Out-Null
                
                # Wait for instance to start running
                Start-Sleep -Seconds 10
                while ($true) {
                    $response = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0].State.Name' --output text
                    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    
                    if ($response -eq "running") {
                        $OutputQueue.Enqueue("[$currentTime] [$InstanceId] STEP 4/5: RUNNING successfully")
                        break
                    }
                    else {
                        $OutputQueue.Enqueue("[$currentTime] [$InstanceId] STEP 4/5: Starting... (state: $response)")
                    }
                    Start-Sleep -Seconds 10
                }
                
                # Step 4: Complete
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] STEP 5/5: COMPLETED - Migration to shared tenancy successful")
            }
            catch {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $OutputQueue.Enqueue("[$timestamp] [$InstanceId] ERROR: $($_.Exception.Message)")
            }
        }
        
        # Create and start runspaces
        $runspaces = @()
        $instanceCount = 0
        
        foreach ($line in $csvContent) {
            $instanceId = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($instanceId)) {
                Write-Host "Skipping invalid row. Expected format: instance_id"
                continue
            }
            
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $runspacePool
            $powershell.AddScript($scriptBlock).AddArgument($instanceId).AddArgument($outputQueue) | Out-Null
            
            $runspaces += @{
                PowerShell = $powershell
                Handle = $powershell.BeginInvoke()
                InstanceId = $instanceId
            }
            
            $instanceCount++
            
            # Staggered startup with larger delays for 120 threads
            if ($instanceCount % 5 -eq 0) {
                Start-Sleep -Milliseconds (Get-Random -Minimum 2000 -Maximum 5000)
            }
        }
        
        Write-Host "Started processing $instanceCount instances in parallel..."
        
        # Wait for all runspaces to complete with real-time output
        $completedRunspaces = @{}
        do {
            # Process output queue in real-time
            while ($outputQueue.Count -gt 0) {
                $message = $null
                if ($outputQueue.TryDequeue([ref]$message)) {
                    Write-Host $message
                }
            }
            
            Start-Sleep -Milliseconds 500
            $completed = 0
            
            # Check completion status
            foreach ($runspace in $runspaces) {
                if ($runspace.Handle.IsCompleted -and -not $completedRunspaces.ContainsKey($runspace.InstanceId)) {
                    try {
                        $runspace.PowerShell.EndInvoke($runspace.Handle) | Out-Null
                        $completedRunspaces[$runspace.InstanceId] = $true
                    }
                    catch {
                        Write-Host "Error in runspace for instance $($runspace.InstanceId): $($_.Exception.Message)"
                        $completedRunspaces[$runspace.InstanceId] = $true
                    }
                }
                
                if ($runspace.Handle.IsCompleted) {
                    $completed++
                }
            }
            
            # Show overall progress every 10 seconds
            $currentTime = Get-Date
            if (-not $script:lastProgressTime -or ($currentTime - $script:lastProgressTime).TotalSeconds -ge 10) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $percentage = [math]::Round(($completed / $instanceCount) * 100, 1)
                Write-Host "[$timestamp] OVERALL PROGRESS: $completed/$instanceCount instances completed ($percentage%)"
                $script:lastProgressTime = $currentTime
            }
        } while ($completed -lt $runspaces.Count)
        
        # Process any remaining messages in queue
        while ($outputQueue.Count -gt 0) {
            $message = $null
            if ($outputQueue.TryDequeue([ref]$message)) {
                Write-Host $message
            }
        }
        
        # Final cleanup
        foreach ($runspace in $runspaces) {
            try {
                if (-not $completedRunspaces.ContainsKey($runspace.InstanceId)) {
                    $output = $runspace.PowerShell.EndInvoke($runspace.Handle)
                    if ($output) {
                        $output | ForEach-Object { Write-Host $_ }
                    }
                }
            }
            catch { }
            finally {
                $runspace.PowerShell.Dispose()
            }
        }
        
        # Cleanup runspace pool
        $runspacePool.Close()
        $runspacePool.Dispose()
        
        Write-Host "All instances processed."
    }
    catch {
        Write-Host "An error occurred: $($_.Exception.Message)"
        exit 1
    }
}

# Check if AWS CLI is available
try {
    aws --version | Out-Null
}
catch {
    Write-Host "Error: AWS CLI is not installed or not in PATH."
    exit 1
}

# Run main function
Main -CsvFilePath $CsvFilePath