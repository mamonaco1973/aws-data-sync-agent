# CLAUDE.md — aws-data-sync (aws-efs)

## Project Overview

This project extends a **Mini Active Directory** lab by adding **Amazon Elastic
File System (EFS)** as a shared storage backend. It demonstrates two access
patterns for cloud-native NFS storage:

1. **Direct NFS mount on Linux** — domain-joined Ubuntu client mounts EFS
   directly at `/efs` and `/home` for POSIX-compliant shared storage.
2. **SMB via Samba on Linux** — the same Linux client re-exports the EFS mount
   as a Samba share, allowing Windows clients to access EFS over SMB without
   native NFS support.

Active Directory (Samba 4 on Ubuntu) provides authentication and DNS. EFS
provides elastic, multi-AZ NFS storage. Together they form a hybrid setup where
both Linux and Windows domain-joined clients consume the same cloud storage.

The Active Directory controller is provisioned via an external reusable
Terraform module: `github.com/mamonaco1973/module-aws-mini-ad`.

## Project Structure

```
aws-data-sync/
├── 01-directory/              # Phase 1: AD domain controller (us-east-1)
│   ├── scripts/
│   │   └── users.json.template  # User/group provisioning template;
│   │                            #   passwords injected at apply time
│   ├── accounts.tf            # Random passwords + Secrets Manager storage
│   ├── ad.tf                  # mini-ad module invocation; renders users.json
│   │                          #   from template with dynamic passwords
│   ├── main.tf                # AWS provider
│   ├── networking.tf          # VPC 10.0.0.0/24, public/private subnets,
│   │                          #   IGW, NAT Gateway, route tables
│   └── variables.tf           # dns_zone, realm, netbios, user_base_dn,
│                              #   vpc_name
├── 02-servers/                # Phase 2: EFS + EC2 clients (us-east-1)
│   ├── scripts/
│   │   └── userdata.sh        # Ubuntu bootstrap: installs packages, mounts
│   │                          #   EFS, joins AD domain, configures SSSD +
│   │                          #   Samba, sets permissions
│   ├── efs.tf                 # EFS file system (encrypted), mount targets
│   │                          #   in both subnets, NFS security group
│   ├── linux.tf               # Ubuntu 24.04 EC2 (t3.medium), AMI via SSM
│   │                          #   parameter, outputs: public DNS
│   ├── main.tf                # AWS provider, data sources for VPC/subnets
│   │                          #   from Phase 1
│   ├── roles.tf               # EC2 IAM role + instance profile:
│   │                          #   SSM + scoped Secrets Manager read
│   ├── security_groups.tf     # SSH (22) + SMB (445) SG for Linux client;
│   │                          #   RDP (3389) SG for Windows client
│   └── variables.tf           # dns_zone, realm, netbios, user_base_dn,
│                              #   vpc_name
├── apply.sh                   # Two-phase deploy: 01-directory then
│                              #   02-servers, then validate.sh
├── check_env.sh               # Validates aws, terraform, jq in PATH and
│                              #   AWS CLI authentication
├── destroy.sh                 # Tears down 02-servers first, deletes 5
│                              #   Secrets Manager secrets, then destroys
│                              #   01-directory
└── validate.sh                # Prints public DNS for efs-client-gateway
                               #   and windows-ad-admin instances
```

## Deployment Workflow

### Prerequisites

- `terraform` >= 1.5.0
- `aws` CLI configured with credentials for us-east-1
- `jq`

### Deploy

```bash
./check_env.sh   # Validate tools and AWS credentials
./apply.sh       # Deploy 01-directory, then 02-servers, then validate
```

### Destroy

```bash
./destroy.sh     # Full cleanup — see destroy order below
```

## Phase Details

### Phase 1 — Active Directory (`01-directory/`) — us-east-1

- VPC `10.0.0.0/24`
- Public subnet `vm-subnet-1` (`10.0.0.64/26`, AZ use1-az6)
- Private subnet `ad-subnet` (`10.0.0.0/26`, AZ use1-az4)
- NAT Gateway in the public subnet — required for the AD instance to reach
  package repositories during bootstrap
- AD controller provisioned via external module
  `github.com/mamonaco1973/module-aws-mini-ad`:
  - Domain: `mcloud.mikecloud.com`
  - Kerberos realm: `MCLOUD.MIKECLOUD.COM`
  - NetBIOS: `MCLOUD`
  - Samba 4 on Ubuntu acting as Domain Controller and DNS server
- 4 users (`jsmith`, `edavis`, `rpatel`, `akumar`) and 4 groups
  (`mcloud-users`, `india`, `us`, `linux-admins`) created at first boot via
  rendered `users.json`
- Passwords randomly generated at apply time, stored in Secrets Manager with
  suffix `_efs` (e.g. `admin_ad_credentials_efs`)
- `jsmith` and `rpatel` are Domain Admins; `jsmith` and `rpatel` are in
  `linux-admins` for passwordless sudo

### Phase 2 — EFS + Clients (`02-servers/`) — us-east-1

- Reads VPC and subnet IDs from Phase 1 via data sources (vpc_name = `efs-vpc`)
- **EFS File System** (`mcloud-efs`):
  - Encrypted at rest
  - Mount targets in both subnets for multi-AZ access
  - Security group allows TCP/2049 (NFS) — open to `0.0.0.0/0` in demo;
    restrict to VPC CIDR or specific SGs in production
- **Linux client** (`efs-client-gateway`):
  - Ubuntu 24.04 LTS, `t3.medium`, AMI resolved via SSM parameter
  - `userdata.sh` runs at boot:
    1. Installs SSSD + realmd + adcli for AD domain join
    2. Installs Samba + Winbind for SMB re-export
    3. Installs nfs-common + efs-utils (cloned from GitHub)
    4. Installs AWS CLI v2
    5. Mounts EFS at `/efs` (NFS with TLS) and `/home` (shared home dirs)
    6. Joins AD domain using admin credentials from Secrets Manager
    7. Configures SSSD: disables FQDN login, disables LDAP ID mapping
       (uses POSIX uidNumber/gidNumber from AD)
    8. Configures Samba: bridges NFS→SMB, workgroup = MCLOUD,
       security = ADS, id mapping via sss
    9. Grants passwordless sudo to `linux-admins` group
    10. Initialises home directories for AD users on EFS
    11. Sets `/efs` ownership to `mcloud-users`, permissions `0770`
- **Windows client** (provisioned separately — see `windows.tf` if present):
  - Joins AD domain, installs AD tools and AWS CLI via PowerShell userdata
  - Accesses EFS via SMB share on the Linux client (`\\efs-client-gateway\efs`)
  - RDP access using `admin_ad_credentials_efs` secret

## Script Details

### `apply.sh`
Sets `AWS_DEFAULT_REGION=us-east-1`, runs `check_env.sh`, then deploys
`01-directory` and `02-servers` with `terraform init` + `apply -auto-approve`,
then calls `validate.sh`.

### `destroy.sh`
1. `terraform destroy` on `02-servers`
2. Force-deletes 5 Secrets Manager secrets (no recovery window):
   `akumar_ad_credentials_efs`, `jsmith_ad_credentials_efs`,
   `edavis_ad_credentials_efs`, `rpatel_ad_credentials_efs`,
   `admin_ad_credentials_efs`
3. `terraform destroy` on `01-directory`

Secrets must be deleted before `01-directory` destroy or the module teardown
will fail on resources that reference them.

### `validate.sh`
Queries EC2 by Name tags `efs-client-gateway` and `windows-ad-admin`, prints
their public DNS names for SSH and RDP access.

## Key IAM Resources

| Resource | Purpose |
|---|---|
| `ec2-secrets-role-*` | EC2 instance role (random suffix for uniqueness) |
| `AmazonSSMManagedInstanceCore` | SSM Session Manager access on clients |
| `secretsmanager:GetSecretValue` | Scoped to `admin_ad_credentials_efs` — used by userdata to join AD |

## Domain Users and Groups

| Username | uidNumber | Groups | Domain Admin |
|---|---|---|---|
| `jsmith` | 10001 | mcloud-users, us, linux-admins | Yes |
| `edavis` | 10002 | mcloud-users, us | No |
| `rpatel` | 10003 | mcloud-users, india, linux-admins | Yes |
| `akumar` | 10004 | mcloud-users, india | No |

| Group | gidNumber |
|---|---|
| `mcloud-users` | 10001 |
| `india` | 10002 |
| `us` | 10003 |
| `linux-admins` | 10004 |

`uidNumber` and `gidNumber` are POSIX attributes stored in AD — critical for
SSSD to map AD identities to Linux UIDs/GIDs without LDAP ID mapping.

## Terraform Providers

| Provider | Version |
|---|---|
| `hashicorp/aws` | ~> 5.0 |
| `hashicorp/random` | Password generation |

## Important Notes

- **Module dependency**: `01-directory` uses an external Terraform module
  (`github.com/mamonaco1973/module-aws-mini-ad`). Internet access is required
  during `terraform init` to clone it.
- **NAT Gateway required**: The AD instance in the private subnet needs
  outbound access to install packages. NAT Gateway must be up before the
  instance bootstraps — enforced via `depends_on` in `ad.tf`.
- **Phase ordering is strict**: `02-servers` reads VPC/subnet IDs from
  `01-directory` state via data sources. Phase 1 must be fully applied before
  Phase 2 can plan or apply.
- **Windows cannot mount EFS directly**: EFS is NFS-only. Windows access goes
  through the Samba share on the Linux client (`\\efs-client-gateway\efs`).
- **POSIX ID mapping**: SSSD is configured with `ldap_id_mapping = false`,
  meaning Linux UIDs/GIDs come from `uidNumber`/`gidNumber` AD attributes.
  These must be set on every AD user or Linux login will fail.
- **EFS cost**: EFS Standard is ~$0.30/GB-month — significantly more expensive
  than EBS (~$0.08) or S3 (~$0.023). This is a demo/lab environment.
- **Secret naming suffix**: All Secrets Manager secrets use the `_efs` suffix
  (e.g. `admin_ad_credentials_efs`) to avoid collisions with other lab projects
  that use the same mini-ad module.
- **Local Terraform state only** — no backend configured. Never commit
  `*.tfstate` or `*.tfstate.backup`.

## Code Commenting Standards

Claude should apply consistent, professional commenting when modifying code.

### General Rules

- Keep comment lines **≤ 80 characters**
- Do **not change code behavior**
- Preserve existing variable names and structure
- Comments should explain **intent**, not restate obvious code
- Prefer concise, structured comments

### Terraform Files

```hcl
# ================================================================================
# Section Name
# Description of resources created in this block
# ================================================================================
```

Comments should explain **why infrastructure exists**, not repeat the resource
definition.

### Shell Scripts

```bash
# ================================================================================
# Section Name
# Purpose of this block
# ================================================================================

# ------------------------------------------------------------------------------
# Subsection Name
# Brief operational note
# ------------------------------------------------------------------------------
```

- Preserve strict bash style: `set -euo pipefail`
- Keep scripts idempotent where possible
- Explain why a command block exists, not what obvious flags do
