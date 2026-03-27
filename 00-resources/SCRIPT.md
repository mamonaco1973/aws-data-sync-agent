# Video Script — AWS DataSync Agent: SMB to S3 Data Migration

---

## Introduction

[Show DataSync task execution running with throughput and file counts updating]

In the last video we used AWS DataSync to move data from Amazon EFS directly into S3 without any agent — DataSync injected a network interface into our VPC and mounted EFS internally.

[Show the DataSync Agents console page — empty or showing the new agents]

But what happens when your source storage isn't a native AWS service? What if your data lives on an SMB file share — the kind of share that Windows clients connect to?

[Show a Windows File Explorer connected to the Samba share]

That's where the DataSync agent comes in.

[Show two DataSync agent EC2 instances in the EC2 console]

In this project we'll deploy two DataSync agents — purpose-built EC2 instances that run inside your VPC and act as a bridge between the DataSync service and an SMB source that DataSync cannot reach on its own.

[Show the flow diagram]

The source is a Samba share running on our domain-joined Linux gateway, backed by Amazon EFS. Each agent mounts that share over SMB and streams its assigned data through DataSync into S3 — all four transfers running concurrently.

---

## Architecture

[FULL ARCHITECTURE DIAGRAM ON SCREEN]

Let's walk through the architecture.

[Highlight ad-subnet with AD DC]

Phase one is the same Mini Active Directory setup we've used in previous projects. Samba 4 on Ubuntu acts as the domain controller for the mcloud.mikecloud.com domain, handling authentication and DNS for everything in the VPC.

[Highlight efs-client-gateway in vm-subnet-1]

Phase two is the Linux gateway instance. It mounts Amazon EFS over NFS, and then re-exports that storage as a Samba SMB share named efs. Four GitHub repositories are cloned into EFS at boot — these are the data that DataSync will transfer.

[Highlight both datasync-agent instances in vm-subnet-1]

Phase four provisions two DataSync agents — both t3.large EC2 instances running the AWS-provided agent AMI. They live inside the VPC so they can reach the Samba share on port 445. Neither has an IAM role — they authenticate to the DataSync service using activation keys.

[Show activate-agent.sh in the terminal]

After Terraform provisions the agent EC2 instances, we run activate-agent.sh. This script polls each agent's HTTP endpoint on port 80, retrieves a one-time activation key, and registers each agent with DataSync using the AWS CLI.

[Highlight the SMB/445 arrows between each datasync-agent and efs-client-gateway]

Once activated, each agent mounts the Samba share over SMB using Active Directory credentials and makes its assigned data available to its DataSync tasks.

[Highlight the HTTPS dashed arrows between DataSync service and both agents]

The DataSync service communicates with each agent over HTTPS to coordinate the transfer. Agent one handles the aws-efs and aws-mgn-example repositories. Agent two handles aws-workspaces and aws-mysql. All four tasks run at the same time.

[Highlight the S3 bucket]

All four tasks write to the same encrypted, versioned S3 bucket, each landing under its own prefix inside the /efs path.

---

## Flow Diagram

[FLOW DIAGRAM ON SCREEN]

[Highlight the activation note box]

The one-time activation step happens once per agent. activate-agent.sh polls each HTTP endpoint, collects the key, and calls aws datasync create-agent. After that the HTTP port is no longer needed for either agent.

[Highlight SMB source → both agent arrows]

During a task execution both agents mount the same Samba share as the rpatel domain user, but each reads from a specific subdirectory — pointing only at the project repos assigned to that agent.

[Highlight each agent's task arrows → S3]

Each agent drives two DataSync tasks concurrently, and all four write to the same S3 bucket under separate prefixes. The service handles retries and integrity verification for each transfer independently.

[Highlight the lifecycle strip at the bottom]

Every task execution follows the same lifecycle — queued, launching, preparing, transferring, verifying, and finally success.

---

## Build Results

[Show EC2 console — both datasync-agent instances running alongside efs-client-gateway]

After apply.sh completes, both agent EC2 instances are running alongside the efs-client-gateway in vm-subnet-1.

[Show DataSync console — Agents page]

In the DataSync console under Agents we can see both registered agents, their status, and the VPC they're connected to.

[Show DataSync console — Locations page]

activate-agent.sh created eight locations total — four SMB source locations, each pointing at a specific project subdirectory on efs-client-gateway, and four S3 destination locations each under a different prefix in the bucket.

[Click an SMB location — show the server, subdirectory, and agent ARN]

If we open one of the SMB locations you can see the server hostname, the subdirectory which maps to a specific project directory inside the efs share, and the agent ARN assigned to mount it.

[Show DataSync console — Tasks page — four tasks]

There are four tasks in total — sync-aws-efs and sync-aws-mgn-example on agent one, sync-aws-workspaces and sync-aws-mysql on agent two. Each task is configured to transfer changed files only, remove deleted files from S3, verify transferred files, and log at the TRANSFER level to CloudWatch.

[Show SSM Parameter Store — /datasync/smb-task-arn/ prefix]

Each task ARN is stored in SSM Parameter Store under /datasync/smb-task-arn/<project>. validate.sh reads all four at runtime to start and monitor the tasks.

---

## Demo

[Show validate.sh running in the terminal]

Let's run the migration. validate.sh reads all four task ARNs from SSM, starts all four executions concurrently, and polls every fifteen seconds until every task completes.

[Show status lines updating for all four tasks: LAUNCHING → PREPARING → TRANSFERRING]

You can see all four tasks moving through the lifecycle in parallel — launching the agent connections, preparing the file inventories, then transferring.

[Show VERIFYING then SUCCESS for each task]

After each transfer DataSync verifies every file that was moved before marking that execution as successful.

[Show the transfer summary printed by validate.sh]

The summary shows the transferred and verified file counts for each of the four tasks.

[Show CloudWatch Logs — log group /datasync/smb-to-s3]

validate.sh downloads the CloudWatch execution logs for each task to a separate timestamped file in the project root. Every transferred and skipped file is recorded, which is useful for auditing large migrations.

[Show S3 bucket — /efs prefix — open a few project folders]

In S3 we can see the data has landed under separate prefixes — one per project — matching the directory structure from the Samba share.

[Show re-running validate.sh with no changes]

If we run the tasks again with no changes to the source, DataSync scans each subdirectory, finds nothing new, and all four tasks complete immediately. This incremental behavior is exactly what makes DataSync useful for large migrations — you can keep the destination synchronized and do a final lightweight sync right before cutover.

---

## Wrap Up

[Show the architecture diagram one more time]

This project shows the two main DataSync patterns side by side. When your source is native AWS storage like EFS, DataSync connects directly with no agent required. When your source is SMB — whether that's an on-premises file server or a Samba share in your VPC — you deploy an agent to bridge the gap.

And when you have more data to move, you simply add more agents. Here we split four project directories across two agents running concurrently, halving the transfer time compared to a single agent.

The agent activation, location creation, and task wiring are all handled by a single shell script using the AWS CLI, keeping the Terraform footprint focused on infrastructure and leaving the DataSync configuration fully automated and repeatable.

[Show the GitHub link or repo]

All the code for this project is available on GitHub. Links are in the description below.
