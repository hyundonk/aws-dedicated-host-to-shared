# aws-dedicated-host-to-shared
PowerShell script for bulk migration of instances in dedicated host to shared tenancy

### How it works
'dh_to_shared.ps1' powershell script is designed to migrate hundreds of instances running on EC2 dedicated hosts to shared instances (default tenancy).

This script uses 'Runspace threads' for parallel threads execution to execute migrate each instance in its own thread.

Runspace threads CANNOT directly write to the main thread's console. So to write each thread's log to the console, the script uses a queue ($outputQueue) for each thread sends logs to the queue and the main thread output logs from the queue.




