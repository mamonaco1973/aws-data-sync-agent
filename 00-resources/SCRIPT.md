# Video Script — AWS DataSync Agent: SMB to S3 Data Migration

---

## Introduction

[Show DataSync console with a task ready to run]

AWS DataSync can move data between many storage systems.

But sometimes the storage system isn’t directly accessible from the AWS DataSync service.

[Show SMB share mounted on Linux server]

For example, an SMB file share running inside a private environment.

[Show DataSync agent EC2 instances]

In these situations DataSync uses agents — lightweight virtual appliances that act as a bridge between the storage system and the DataSync service.

[Show architecture diagram briefly]

In this project we’ll build a complete DataSync pipeline with Terraform that migrates data from an SMB file share to Amazon S3 using multiple DataSync agents.

---

## Architecture

[ FULL DIAGRAM ON SCREEN ]

Now let's review the architecture.

[ Highlight LEFT column: "SMB Source" ]

On the left side is the source storage. In this example the data lives on an SMB file share running on a Linux instance. This represents a common scenario where data is exposed through a network file protocol rather than directly through an AWS service.

[ Highlight SMB/445 arrows ]

The DataSync agents access this storage using the SMB protocol over port 445.

[ Highlight CENTER column: "DataSync Agents" ]

In the middle are the DataSync agents running as EC2 instances. Agents are required when the storage system cannot be accessed directly by the DataSync service. Each agent reads files from the SMB share and streams the data to AWS.

[ Highlight RIGHT column: "DataSync Tasks" ]

Next are the DataSync tasks. Each task defines a source location and a destination location. Because this architecture uses two agents, multiple tasks can run at the same time, allowing transfers to run in parallel and increasing overall throughput.

[ Highlight FAR RIGHT column: "S3 Destination" ]

When a task runs, the source data is written into the S3 destination.

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
