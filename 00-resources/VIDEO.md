#AWS #DataSync #DataSyncAgent #SMB #S3 #Terraform #CloudMigration #ActiveDirectory #Samba

*AWS DataSync Agent – SMB to S3 Data Migration with Terraform*

In this video, we extend our DataSync lab to demonstrate agent-based transfers — moving data from a Samba SMB share into S3 using a dedicated DataSync agent EC2 instance. Where the previous project showed how DataSync connects directly to EFS without an agent, this project covers the pattern you need when your source is SMB: a file share that DataSync cannot reach on its own.

The infrastructure is deployed in four phases with Terraform: a Samba 4 mini Active Directory domain controller, an EFS-backed Linux gateway that exposes the data as a Samba SMB share, an S3 destination bucket with IAM and CloudWatch support, and a DataSync agent EC2 instance provisioned in the VPC. After Terraform apply, a single shell script activates the agent via its HTTP endpoint, creates the SMB source location and S3 destination location, wires them into a DataSync task, and stores the task ARN in SSM for automated execution.

This project demonstrates the real-world agent-based DataSync pattern: when your source is SMB — on-premises, in a VPC, or anywhere reachable from an agent — you deploy a DataSync agent to bridge the gap. Everything from agent activation to task creation, execution, and CloudWatch log collection is fully automated with shell scripts.

What You'll Learn
- Understand when a DataSync agent is required versus agentless EFS-to-S3 transfers
- Provision a DataSync agent EC2 using the AWS-provided AMI via SSM parameter
- Activate a DataSync agent by polling its HTTP endpoint for a one-time activation key
- Create an SMB source location with Active Directory credentials using the AWS CLI
- Understand why a POSIX-mapped AD user (with uidNumber set) is required for SMB agent authentication
- Diagnose and fix winbind machine account trust failures that block NTLMv2 authentication
- Use net ads join alongside realm join to ensure winbind's trust is initialized correctly
- Exclude inaccessible paths from a DataSync task using SIMPLE_PATTERN filters
- Store DataSync task ARNs in SSM Parameter Store for decoupled script-based execution
- Poll DataSync task execution status until SUCCESS or ERROR with CloudWatch log download
- Tear down CLI-created DataSync resources (task, locations, agent) before Terraform destroy

Resources Deployed
- VPC 10.0.0.0/24 with public and private subnets, NAT Gateway (us-east-1)
- Ubuntu EC2 instance running Samba 4 as a Domain Controller and DNS server
- Amazon EFS file system (mcloud-efs) with mount targets in two subnets
- Domain-joined Ubuntu EC2 instance (efs-client-gateway) mounting EFS and exposing it as a Samba SMB share
- Windows Server EC2 instance joined to the domain, accessible via RDP
- DataSync agent EC2 instance (t3.large) using the AWS-provided DataSync agent AMI
- Security group allowing inbound HTTP/80 on the agent for one-time activation
- S3 bucket with server-side encryption, versioning, and public access blocked
- IAM role trusted by datasync.amazonaws.com with scoped S3 read/write permissions
- CloudWatch log group (/datasync/smb-to-s3) with resource policy for DataSync log writes
- SMB source location pointing at the Samba share on efs-client-gateway (created by CLI)
- S3 destination location under the /efs prefix (created by CLI)
- One DataSync task (sync-smb-efs) with TRANSFER-level CloudWatch logging (created by CLI)
- SSM Parameter Store sentinels for EFS population gating and SMB task ARN storage
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
