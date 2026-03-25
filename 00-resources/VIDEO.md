#AWS #DataSync #EFS #S3 #Terraform #CloudMigration #DataTransfer #ActiveDirectory

*AWS DataSync – EFS to S3 Data Migration with Terraform*

In this video, we build a fully automated EFS-to-S3 data migration pipeline using AWS DataSync — Amazon's managed transfer service that handles scheduling, monitoring, retries, and integrity verification without custom scripts or a dedicated agent for AWS-to-AWS transfers.

The infrastructure is deployed in three phases with Terraform: a Samba 4 mini Active Directory domain controller, an EFS file system mounted by a domain-joined Linux client that clones four GitHub repositories as sample data, and four concurrent DataSync tasks that migrate each repository from EFS into a dedicated S3 prefix. Everything from provisioning to task execution and validation is fully automated with shell scripts.

This project demonstrates a real-world pattern for cloud-native data migration: structured source data in EFS, parallel transfer tasks for throughput, and S3 as a durable low-cost destination — with no DataSync agent required for the EFS-to-S3 path.

What You'll Learn
- Understand how AWS DataSync works for EFS-to-S3 transfers without a dedicated agent
- Structure a three-phase Terraform deployment with strict phase ordering
- Create DataSync EFS source locations, S3 destination locations, and tasks using Terraform for_each
- Configure a DataSync security group that allows outbound NFS/2049 to EFS mount targets from a VPC ENI
- Grant DataSync the correct S3 IAM permissions via a scoped bucket access role
- Use SSM Parameter Store as a sentinel to gate DataSync execution until EFS population is complete
- Run four DataSync tasks concurrently and poll execution status until SUCCESS or ERROR
- Understand the DataSync task execution lifecycle: QUEUED → LAUNCHING → PREPARING → TRANSFERRING → VERIFYING → SUCCESS
- Integrate Samba 4 on Ubuntu as a mini Active Directory domain controller for lab authentication
- Tear down DataSync resources before EFS and VPC to avoid dependency violations

Resources Deployed
- VPC 10.0.0.0/24 with public and private subnets, NAT Gateway (us-east-1)
- Ubuntu EC2 instance running Samba 4 as a Domain Controller and DNS server
- Amazon EFS file system (mcloud-efs) with mount targets in two subnets
- Domain-joined Ubuntu EC2 instance (efs-client-gateway) that mounts EFS and clones four GitHub repositories as sample data
- Windows Server EC2 instance joined to the domain, accessible via RDP
- S3 bucket with server-side encryption, versioning, and public access blocked
- IAM role trusted by datasync.amazonaws.com with scoped S3 read/write permissions
- DataSync security group for the ENI DataSync creates in the VPC subnet
- Four EFS source locations (one per repository subdirectory)
- Four S3 destination locations (one per S3 prefix)
- Four DataSync tasks running concurrently
- SSM Parameter Store sentinel (/datasync/efs-ready) for EFS population gating
- AWS Secrets Manager secrets for Active Directory user credentials


GitHub
https://github.com/mamonaco1973/aws-data-sync

README
https://github.com/mamonaco1973/aws-data-sync/blob/main/README.md

Timestamps

00:00 Introduction
00:22 Architecture
01:10 Build the Code
01:35 Build Results
02:20 DataSync Flow
03:05 Demo
