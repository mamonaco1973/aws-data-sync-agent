# AWS EFS to S3 Data Migration with AWS DataSync

This project demonstrates a complete **EFS-to-S3 data migration pipeline** using **AWS DataSync**, built on top of a Mini Active Directory lab environment with shared NFS storage.

The infrastructure is deployed in three phases:

1. **Mini Active Directory** — Samba 4 on Ubuntu acting as a Domain Controller, providing authentication and DNS for the environment.
2. **EFS + Domain-Joined Clients** — An Amazon EFS file system mounted by a Linux client that also exposes the storage as a Samba share for Windows access. At boot, the Linux instance clones four GitHub repositories into EFS as sample data.
3. **AWS DataSync** — Four concurrent DataSync tasks transfer each repository from EFS into a dedicated S3 prefix, demonstrating parallelized cloud-native data migration without a DataSync agent.

![AWS diagram](aws-data-sync.png)

---

## Understanding AWS DataSync

**AWS DataSync** is a managed data transfer service that automates moving data between storage systems. It handles scheduling, monitoring, retries, and integrity verification — without requiring custom transfer scripts or a dedicated agent for AWS-to-AWS transfers.

![flow](datasync-flow.png)

### How This Project Uses DataSync

Four git repositories are cloned into EFS by the Linux instance at boot:

| EFS Path | S3 Destination |
|---|---|
| `/efs/aws-efs` | `s3://bucket/aws-efs/` |
| `/efs/aws-mgn-example` | `s3://bucket/aws-mgn-example/` |
| `/efs/aws-workspaces` | `s3://bucket/aws-workspaces/` |
| `/efs/aws-mysql` | `s3://bucket/aws-mysql/` |

Each path gets its own DataSync **source location** (EFS subdirectory), **destination location** (S3 prefix), and **task** — allowing all four transfers to run concurrently.

### No Agent Required

For EFS-to-S3 transfers, DataSync does not require a separate agent EC2 instance. It creates an elastic network interface directly in your VPC subnet and mounts the EFS file system internally. The only networking requirement is a security group that allows outbound NFS (TCP/2049) from that ENI to the EFS mount targets.

### Key DataSync Concepts

- **Location** — A pointer to a specific path in a storage system (EFS subdirectory or S3 prefix). The subdirectory is baked into the location, not the task, which is why each concurrent task needs its own source location.
- **Task** — Wires a source location to a destination location with transfer options (change detection, verification mode, deletion handling).
- **Task Execution** — A single run of a task. Tasks are defined by Terraform but triggered separately via `start-task-execution`.

---

## Prerequisites

* [An AWS Account](https://aws.amazon.com/console/)
* [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [Install Latest Terraform](https://developer.hashicorp.com/terraform/install)

If this is your first time following along, we recommend starting with this video: [AWS + Terraform: Easy Setup](https://youtu.be/BCMQo0CB9wk).

---

## Download this Repository

```bash
git clone https://github.com/mamonaco1973/aws-data-sync.git
cd aws-data-sync
```

---

## Build the Code

Run [check_env.sh](check_env.sh) to validate your environment, then run [apply.sh](apply.sh) to provision all three phases.

```bash
~/aws-data-sync$ ./apply.sh
NOTE: Running environment validation...
NOTE: Building Active Directory instance...
NOTE: Building EC2 server instances...
NOTE: Building DataSync infrastructure...
NOTE: Running build validation...
NOTE: Infrastructure build complete.
```

---

## Build Results

### Phase 1 — Active Directory (`01-directory/`)

- VPC `10.0.0.0/24` with public and private subnets
- Internet Gateway and NAT Gateway for outbound package installation from the private subnet
- Ubuntu EC2 instance running Samba 4 as a Domain Controller and DNS server
- Domain `mcloud.mikecloud.com`, Kerberos realm `MCLOUD.MIKECLOUD.COM`
- Four AD users and four groups created at boot; all credentials stored in AWS Secrets Manager

### Phase 2 — EFS + Clients (`02-servers/`)

- Amazon EFS file system (`mcloud-efs`) with mount targets in two subnets for multi-AZ access
- Domain-joined Ubuntu EC2 instance (`efs-client-gateway`):
  - Mounts EFS at `/efs` and `/home`
  - Clones four GitHub repositories into `/efs` as sample data for DataSync
  - Exposes `/efs` as a Samba share for Windows access
- Windows Server EC2 instance joined to the domain, accessible via RDP

### Phase 3 — DataSync (`03-datasync/`)

- S3 bucket with server-side encryption, versioning, and public access blocked
- IAM role trusted by `datasync.amazonaws.com` with S3 read/write permissions
- DataSync security group attached to the ENI DataSync creates in the VPC
- Four EFS source locations (one per repository subdirectory)
- Four S3 destination locations (one per S3 prefix)
- Four DataSync tasks — independent and ready to run concurrently

---

## Running the DataSync Tasks

`validate.sh` is called automatically at the end of `apply.sh`. It reads all four task ARNs from Terraform output, starts them concurrently, and polls until every task reaches `SUCCESS` (or exits on `ERROR`). A transfer summary is printed at the end.

To re-run the tasks manually after the initial deploy:

```bash
./validate.sh
```

To inspect task ARNs or trigger a single task manually:

```bash
cd 03-datasync
terraform output datasync_task_arns
aws datasync start-task-execution --task-arn <arn>
```

## Clean Up

```bash
./destroy.sh
```

Teardown order: DataSync tasks and S3 bucket → EC2 instances and EFS → Secrets Manager secrets → Active Directory infrastructure.
