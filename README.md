# aws-dedicated-host-to-shared
Sample PowerShell script for bulk migration of instances in dedicated host to shared tenancy with billing code change from RunInstances:0800 to RunInstances:0200

### How it works
'dh_to_shared.ps1' powershell script is designed to migrate hundreds of instances running on EC2 dedicated hosts to shared instances (default tenancy).

This script uses 'Runspace threads' for parallel threads execution to execute migrate each instance in its own thread.

Runspace threads CANNOT directly write to the main thread's console. So to write each thread's log to the console, the script uses a queue ($outputQueue) for each thread sends logs to the queue and the main thread output logs from the queue.

Also to avoid reaching AWS API throttling limit, each thread has random delay (0 ~ 15 sec) before calling EC2 APIs.



### How to run

0/ Pre-requisite 
Target EC2 instances with custom AMI shall be running on EC2 dedicatd hosts.
Ensure that each instance has the following configuration::
  Usage operation: RunInstances:0800
  Host ID: h-01111111111111111 (sample example)
  Tenancy: host

1/ Open a PowerShall command promopt and configure environment variables

```
$env:AWS_REGION = "ap-southeast-1"
$env:AWS_PROFILE = "default"
```

2/ Prepare instances.csv, each row with target EC2 instance ID.

3/ Run dh_to_shared.ps1
```
> .\dh_to_shared.ps1 ..\instances.csv
The file ..\instances.csv contains a UTF-8 BOM.
Instance i-01111222233334444 is in 'running' state on a dedicated-host.
True
Instance i-01111222233335555 is in 'running' state on a dedicated-host.
True
Skipping invalid row. Expected format: instance_id
Pre-condition check completed. Do you want to proceed? (y/n): y
Skipping invalid row. Expected format: instance_id
Started processing 2 instances in parallel...
...
```

Note that this is sample test script not for production usage. 
