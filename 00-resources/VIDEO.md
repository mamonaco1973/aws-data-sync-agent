#AWS #DataSync #DataSyncAgent #SMB #S3 #Terraform #CloudMigration #ActiveDirectory #Samba

*AWS DataSync Agents – SMB to S3 Migration with Terraform*

Learn how to migrate SMB file shares to Amazon S3 using AWS DataSync agents. This project deploys a complete dual-agent DataSync architecture using Terraform.

Unlike EFS transfers that can run agentless, SMB sources require a DataSync agent. In this lab we deploy two DataSync agent EC2 instances to run transfers concurrently and increase throughput.

The environment includes a Samba 4 mini-Active Directory domain, an EFS-backed Linux gateway exposing an SMB share, an S3 destination bucket, and two DataSync agents inside the VPC. After Terraform deployment, a shell script activates the agents, creates SMB and S3 locations, builds four DataSync tasks, and executes them in parallel.

WHAT YOU'LL LEARN
• When AWS DataSync requires an agent vs agentless transfers
• Deploying DataSync agents using the AWS-provided AMI
• Activating agents automatically via HTTP activation keys
• Running concurrent transfers across multiple agents
• Creating SMB source locations scoped to subdirectories
• Handling Active Directory authentication for SMB access
• Monitoring DataSync tasks and reviewing CloudWatch logs

INFRASTRUCTURE DEPLOYED
• VPC with public and private subnets (us-east-1)
• Samba 4 mini Active Directory domain controller
• Amazon EFS file system with Linux SMB gateway
• Windows Server domain management host
• Two AWS DataSync agent EC2 instances
• Amazon S3 destination bucket with encryption and versioning
• IAM role allowing DataSync access to S3
• CloudWatch log group for DataSync transfer logs
• Four SMB source locations and four S3 destinations
• Four concurrent DataSync tasks

GitHub
https://github.com/mamonaco1973/aws-data-sync-agent

README
https://github.com/mamonaco1973/aws-data-sync-agent/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:28 Architecture
01:12 Build the Code
01:28 Build Results
02:19 Demo