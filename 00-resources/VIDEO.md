#AWS #DataSync #DataSyncAgent #SMB #S3 #Terraform #CloudMigration #ActiveDirectory #Samba

*AWS DataSync Agent – SMB to S3 Data Migration with Terraform (Dual Agent)*

In this video, we extend our DataSync lab to demonstrate agent-based transfers — moving data from a Samba SMB share into S3 using two dedicated DataSync agent EC2 instances. Where the previous project showed how DataSync connects directly to EFS without an agent, this project covers the pattern you need when your source is SMB: a file share that DataSync cannot reach on its own.

The infrastructure is deployed in four phases with Terraform: a Samba 4 mini Active Directory domain controller, an EFS-backed Linux gateway that exposes the data as a Samba SMB share, an S3 destination bucket with IAM and CloudWatch support, and two DataSync agent EC2 instances provisioned in the VPC. After Terraform apply, a single shell script activates both agents via their HTTP endpoints, creates four SMB source locations and four S3 destination locations, wires them into four DataSync tasks (two per agent), and stores all task ARNs in SSM for concurrent automated execution.

This project demonstrates the real-world agent-based DataSync pattern: when your source is SMB — on-premises, in a VPC, or anywhere reachable from an agent — you deploy a DataSync agent to bridge the gap. And when scale matters, you add more agents. Everything from agent activation to task creation, concurrent execution, and CloudWatch log collection is fully automated with shell scripts.

What You'll Learn
- Understand when a DataSync agent is required versus agentless EFS-to-S3 transfers
- Provision DataSync agent EC2 instances using the AWS-provided AMI via SSM parameter
- Activate multiple DataSync agents by polling their HTTP endpoints for one-time activation keys
- Split transfers across multiple agents to run tasks concurrently and increase throughput
- Create SMB source locations scoped to specific subdirectories to avoid inaccessible paths
- Understand why a POSIX-mapped AD user (with uidNumber set) is required for SMB agent authentication
- Diagnose and fix winbind machine account trust failures that block NTLMv2 authentication
- Use net ads join alongside realm join to ensure winbind's trust is initialized correctly
- Store DataSync task ARNs in SSM Parameter Store for decoupled script-based execution
- Poll four concurrent DataSync task executions until all reach SUCCESS or any hits ERROR
- Download per-task CloudWatch logs for post-run inspection and audit
- Tear down CLI-created DataSync resources (tasks, locations, agents) before Terraform destroy

Resources Deployed
- VPC 10.0.0.0/24 with public and private subnets, NAT Gateway (us-east-1)
- Ubuntu EC2 instance running Samba 4 as a Domain Controller and DNS server
- Amazon EFS file system (mcloud-efs) with mount targets in two subnets
- Domain-joined Ubuntu EC2 instance (efs-client-gateway) mounting EFS and exposing it as a Samba SMB share
- Windows Server EC2 instance joined to the domain, accessible via RDP
- Two DataSync agent EC2 instances (t3.large each) using the AWS-provided DataSync agent AMI
- Shared security group allowing inbound HTTP/80 on each agent for one-time activation
- S3 bucket with server-side encryption, versioning, and public access blocked
- IAM role trusted by datasync.amazonaws.com with scoped S3 read/write permissions
- CloudWatch log group (/datasync/smb-to-s3) with resource policy for DataSync log writes
- Four SMB source locations, each pointing at a project subdirectory on efs-client-gateway (created by CLI)
- Four S3 destination locations, each under a per-project prefix in the bucket (created by CLI)
- Four DataSync tasks (sync-aws-efs, sync-aws-mgn-example, sync-aws-workspaces, sync-aws-mysql) with TRANSFER-level CloudWatch logging (created by CLI)
- SSM Parameter Store sentinels for EFS population gating and four SMB task ARN entries
- AWS Secrets Manager secrets for Active Directory user credentials


GitHub
https://github.com/mamonaco1973/aws-data-sync-agent

README
https://github.com/mamonaco1973/aws-data-sync-agent/blob/main/README.md

Timestamps

00:00 Introduction
00:30 Architecture
01:20 Build the Code
01:50 Build Results
02:45 DataSync Flow
03:30 Demo
