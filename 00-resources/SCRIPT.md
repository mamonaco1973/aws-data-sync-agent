# Video Script — AWS DataSync Agent: SMB to S3 Data Migration

---

## Introduction

[Show DataSync task execution running with throughput and file counts updating]

In the last video we used AWS DataSync to move data from Amazon EFS directly into S3 without any agent — DataSync injected a network interface into our VPC and mounted EFS internally.

[Show the DataSync Agents console page — empty or showing the new agent]

But what happens when your source storage isn't a native AWS service? What if your data lives on an SMB file share — the kind of share that Windows clients connect to?

[Show a Windows File Explorer connected to the Samba share]

That's where the DataSync agent comes in.

[Show the DataSync agent EC2 instance in the EC2 console]

In this project we'll deploy a DataSync agent — a purpose-built EC2 instance that runs inside your VPC and acts as a bridge between the DataSync service and an SMB source that DataSync cannot reach on its own.

[Show the flow diagram]

The source is a Samba share running on our domain-joined Linux gateway, backed by Amazon EFS. The agent mounts that share over SMB and streams the data through DataSync into S3.

---

## Architecture

[FULL ARCHITECTURE DIAGRAM ON SCREEN]

Let's walk through the architecture.

[Highlight ad-subnet with AD DC]

Phase one is the same Mini Active Directory setup we've used in previous projects. Samba 4 on Ubuntu acts as the domain controller for the mcloud.mikecloud.com domain, handling authentication and DNS for everything in the VPC.

[Highlight efs-client-gateway in vm-subnet-1]

Phase two is the Linux gateway instance. It mounts Amazon EFS over NFS, and then re-exports that storage as a Samba SMB share named efs. This is the data source that DataSync will read from.

[Highlight datasync-agent EC2 in vm-subnet-1]

Phase three provisions the DataSync agent — a t3.large EC2 running the AWS-provided agent AMI. This instance lives inside the VPC so it can reach the Samba share on port 445. It has no IAM role — it authenticates to the DataSync service using an activation key, not instance credentials.

[Show activate-agent.sh in the terminal]

After Terraform provisions the agent EC2, we run activate-agent.sh. This script polls the agent's HTTP endpoint on port 80, retrieves a one-time activation key, and registers the agent with DataSync using the AWS CLI. From that point the agent is fully managed by the service.

[Highlight the SMB/445 arrow between datasync-agent and efs-client-gateway]

Once activated, the agent mounts the Samba share over SMB using Active Directory credentials and makes the data available to the DataSync task.

[Highlight the HTTPS dashed arrow between DataSync service and datasync-agent]

The DataSync service communicates with the agent over HTTPS to coordinate the transfer. The agent reads from the SMB share, and the service writes the data directly into S3.

[Highlight the S3 bucket]

The destination is the same encrypted, versioned S3 bucket we use in our other DataSync projects — with the data landing under the /efs prefix.

---

## Flow Diagram

[FLOW DIAGRAM ON SCREEN]

[Highlight the activation note box at the top]

The one-time activation step is worth calling out. The agent EC2 boots and immediately exposes an HTTP endpoint. activate-agent.sh polls that endpoint, collects the key, and calls aws datasync create-agent. After that the HTTP port is no longer needed.

[Highlight SMB source → DataSync agent arrow]

During a task execution the agent mounts the share as the rpatel domain user and reads files from the efs share root.

[Highlight DataSync agent → task → S3]

The DataSync service coordinates the transfer, handles retries and integrity verification, and writes the result into S3.

[Highlight the lifecycle strip at the bottom]

The task execution follows the same lifecycle as any DataSync task — queued, launching, preparing, transferring, verifying, and finally success.

---

## Build Results

[Show EC2 console — datasync-agent instance running]

After apply.sh completes, the agent EC2 is running alongside the efs-client-gateway in vm-subnet-1.

[Show DataSync console — Agents page]

In the DataSync console under Agents we can see the registered agent, its status, and the VPC it's connected to.

[Show DataSync console — Locations page]

activate-agent.sh created two locations. The SMB source location points at the private IP of efs-client-gateway using the efs share name. The S3 destination location points at our bucket under the /efs prefix.

[Click the SMB location — show the server, subdirectory, and agent ARN]

If we open the SMB location you can see the server hostname, the subdirectory which maps to the share name, and the agent ARN that will be used to mount it.

[Show DataSync console — Tasks page — sync-smb-efs]

There is a single task — sync-smb-efs — wiring the SMB source to the S3 destination. The task is configured to transfer changed files only, remove deleted files from S3, verify transferred files, and log at the TRANSFER level to CloudWatch.

[Show SSM Parameter Store — /datasync/smb-task-arn]

The task ARN is stored in SSM Parameter Store under /datasync/smb-task-arn. validate.sh reads this at runtime to start and monitor the task.

---

## Demo

[Show validate.sh running in the terminal]

Let's run the migration. validate.sh reads the task ARN from SSM, starts the execution, and polls every fifteen seconds until the task completes.

[Show status lines updating: LAUNCHING → PREPARING → TRANSFERRING]

You can see the task moving through the lifecycle — launching the agent connection, preparing the file inventory, then transferring.

[Show VERIFYING then SUCCESS]

After the transfer DataSync verifies every file that was moved before marking the execution as successful.

[Show the transfer summary printed by validate.sh]

The summary shows the transferred and verified file counts.

[Show CloudWatch Logs — log group /datasync/smb-to-s3]

validate.sh also downloads the CloudWatch execution logs to a timestamped file in the project root. Every transferred and skipped file is recorded here, which is useful for auditing large migrations.

[Show S3 bucket — /efs prefix — open a few folders]

In S3 we can see the data has landed under the /efs prefix, matching the directory structure from the Samba share.

[Show re-running validate.sh with no changes]

If we run the task again with no changes to the source, DataSync scans the share, finds nothing new, and completes immediately. This incremental behavior is exactly what makes DataSync useful for large migrations — you can keep the destination synchronized and then do a final lightweight sync right before cutover.

---

## Wrap Up

[Show the architecture diagram one more time]

This project shows the two main DataSync patterns side by side. When your source is native AWS storage like EFS, DataSync connects directly with no agent required. When your source is SMB — whether that's an on-premises file server or a Samba share in your VPC — you deploy an agent to bridge the gap.

The agent activation, location creation, and task wiring are all handled by a single shell script using the AWS CLI, keeping the Terraform footprint focused on infrastructure and leaving the DataSync configuration fully automated and repeatable.

[Show the GitHub link or repo]

All the code for this project is available on GitHub. Links are in the description below.
