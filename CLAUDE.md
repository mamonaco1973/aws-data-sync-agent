# CLAUDE.md — aws-data-sync-agent

## Project Overview

This project extends the **aws-data-sync** lab by replacing the agentless
EFS-to-S3 DataSync pattern with an **agent-based SMB-to-S3** pattern. It
demonstrates when and why a DataSync agent is required — specifically, when the
data source is accessed via SMB rather than a natively mountable AWS storage
service like EFS.

The Samba SMB share on `efs-client-gateway` (backed by EFS) is used as the
DataSync source. A DataSync agent EC2 instance runs inside the VPC, mounts the
SMB share internally, and proxies data to the DataSync service for delivery
to S3.

Key differences from **aws-data-sync**:

| | aws-data-sync | aws-data-sync-agent |
|---|---|---|
| DataSync source | EFS (agentless — ENI in VPC) | Samba SMB share (agent required) |
| Phase 3 | EFS locations + tasks (Terraform) | S3 bucket + IAM + CloudWatch only |
| Phase 4 | n/a | DataSync agent EC2 (Terraform) |
| Task creation | Terraform | `activate-agent.sh` (AWS CLI) |
| Task count | 4 concurrent EFS tasks | 1 SMB task |
| validate.sh | Reads task ARNs from Terraform output | Reads task ARN from SSM |

The Active Directory controller is provisioned via an external reusable
Terraform module: `github.com/mamonaco1973/module-aws-mini-ad`.

## Project Structure

```
aws-data-sync-agent/
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
│   │                          #   Samba + winbind, runs net ads join to
│   │                          #   ensure winbind trust is intact
│   ├── efs.tf                 # EFS file system (encrypted), mount targets
│   ├── linux.tf               # Ubuntu 24.04 EC2 (t3.medium)
│   ├── main.tf                # AWS provider, data sources for VPC/subnets
│   ├── roles.tf               # EC2 IAM role + instance profile:
│   │                          #   SSM + Secrets Manager + SSM Parameter Store
│   ├── security_groups.tf     # SSH (22) + SMB (445) SG for Linux client;
│   │                          #   RDP (3389) SG for Windows client
│   └── variables.tf           # dns_zone, realm, netbios, user_base_dn,
│                              #   vpc_name
├── 03-datasync/               # Phase 3: S3 destination + IAM + CloudWatch
│   ├── cloudwatch.tf          # Log group /datasync/smb-to-s3 + resource
│   │                          #   policy for datasync.amazonaws.com
│   ├── iam.tf                 # IAM role for DataSync S3 access;
│   │                          #   outputs datasync_role_arn for activate-agent.sh
│   ├── main.tf                # AWS + random providers; random_id.suffix
│   └── s3.tf                  # S3 bucket: encrypted, versioned, private;
│                              #   outputs datasync_bucket_name
├── 04-agent/                  # Phase 4: DataSync agent EC2
│   ├── agent.tf               # DataSync agent AMI (SSM), t3.large EC2,
│   │                          #   security group (port 80 inbound for
│   │                          #   activation); outputs agent_public_ip
│   ├── main.tf                # AWS provider, VPC + vm-subnet-1 data sources
│   └── variables.tf           # vpc_name
├── activate-agent.sh          # Registers agent via HTTP activation key,
│                              #   creates SMB location + S3 location + task,
│                              #   stores task ARN in SSM /datasync/smb-task-arn
├── apply.sh                   # Four-phase deploy + activate-agent.sh +
│                              #   validate.sh
├── check_env.sh               # Validates aws, terraform, jq in PATH and
│                              #   AWS CLI authentication
├── destroy.sh                 # Phase 1: CLI cleanup of SMB task/locations/
│                              #   agent; Phase 2-6: terraform destroy in
│                              #   reverse order, secrets deletion
└── validate.sh                # Reads SMB task ARN from SSM, starts task,
                               #   polls to SUCCESS/ERROR, downloads CW logs
```

## Deployment Workflow

### Prerequisites

- `terraform` >= 1.5.0
- `aws` CLI configured with credentials for us-east-1
- `jq`
- `curl`

### Deploy

```bash
./check_env.sh       # Validate tools and AWS credentials
./apply.sh           # Deploy all four phases, activate agent, validate
```

### Destroy

```bash
./destroy.sh         # Full cleanup — see destroy order below
```

## Phase Details

### Phase 1 — Active Directory (`01-directory/`) — us-east-1

Identical to aws-data-sync. See that project's CLAUDE.md for full details.

- VPC `10.0.0.0/24`
- Public subnet `vm-subnet-1` (`10.0.0.64/26`, AZ use1-az6)
- Private subnet `ad-subnet` (`10.0.0.0/26`, AZ use1-az4)
- NAT Gateway in the public subnet
- AD controller: domain `mcloud.mikecloud.com`, realm `MCLOUD.MIKECLOUD.COM`,
  NetBIOS `MCLOUD`
- 4 users (`jsmith`, `edavis`, `rpatel`, `akumar`), 4 groups; passwords in
  Secrets Manager with suffix `_efs`

### Phase 2 — EFS + Clients (`02-servers/`) — us-east-1

Mostly identical to aws-data-sync with two important additions:

- **`ntlm auth = ntlmv2-only`** added to `smb.conf` — required because the
  DataSync agent is not domain-joined and authenticates via NTLMv2. Windows
  clients use Kerberos and are unaffected by this setting.
- **`net ads join`** runs after `realm join` in `userdata.sh` — `realm join
  --membership-software=samba` alone leaves winbind's machine account trust in
  an unreliable state. Without the explicit `net ads join`, `wbinfo -t` fails
  and all NTLMv2 authentication through winbind fails (while Kerberos-based
  Windows connections continue to work, masking the problem).

### Phase 3 — S3 + IAM + CloudWatch (`03-datasync/`) — us-east-1

Significantly stripped down compared to aws-data-sync. There are no DataSync
location or task resources here — those are created by `activate-agent.sh`.

- S3 bucket (`mcloud-datasync-<suffix>`): encrypted, versioned, public access
  blocked, `force_destroy = true`
- IAM role (`datasync-s3-role-<suffix>`): trusted by `datasync.amazonaws.com`,
  inline policy for full S3 read/write on the bucket
- CloudWatch log group `/datasync/smb-to-s3` with resource policy allowing
  `datasync.amazonaws.com` to write log events
- Outputs: `datasync_bucket_name`, `datasync_role_arn`, `datasync_log_group`

### Phase 4 — DataSync Agent (`04-agent/`) — us-east-1

- DataSync agent AMI resolved via SSM parameter `/aws/service/datasync/ami`
- `t3.large` EC2 in `vm-subnet-1` with public IP
- Security group: inbound TCP/80 for activation, all outbound (to reach the
  Samba share on TCP/445 and DataSync service endpoints on HTTPS/443)
- No IAM instance profile — agent authenticates to DataSync via activation key
- Outputs: `agent_public_ip`, `agent_instance_id`

### Agent Activation (`activate-agent.sh`)

Runs after Phase 4 Terraform apply. Idempotent — checks SSM for an existing
task ARN and exits early if already activated.

1. Gets agent public IP from `04-agent` Terraform output
2. Polls `http://<IP>/?gatewayType=SYNC&activationRegion=us-east-1&
   endpointType=PUBLIC&no_redirect` until an activation key is returned
3. `aws datasync create-agent --activation-key <key>`
4. Discovers `efs-client-gateway` private IP via EC2 tag query
5. Reads `rpatel_ad_credentials_efs` from Secrets Manager; strips domain
   prefix from username (`MCLOUD\rpatel` → `rpatel`) — the `--domain` flag
   carries the domain; `--user` must be bare username only
6. `aws datasync create-location-smb --server-hostname <private-ip>
   --subdirectory /efs --user rpatel --domain MCLOUD --agent-arns <arn>`
7. `aws datasync create-location-s3` — reuses the S3 bucket from Phase 3
   with subdirectory `/smb-efs`
8. `aws datasync create-task` — CloudWatch logging to `/datasync/smb-to-s3`,
   options: `TransferMode=CHANGED`, `PreserveDeletedFiles=REMOVE`,
   `VerifyMode=ONLY_FILES_TRANSFERRED`, `LogLevel=TRANSFER`
9. Stores task ARN in SSM `/datasync/smb-task-arn`

## Script Details

### `apply.sh`
Sets `AWS_DEFAULT_REGION=us-east-1`, runs `check_env.sh`, then deploys all
four phases with `terraform init` + `apply -auto-approve`, runs
`activate-agent.sh`, then calls `validate.sh`.

### `destroy.sh`
1. Reads SMB task ARN from SSM `/datasync/smb-task-arn`
2. Cancels any active task execution (DataSync rejects `delete-task` while
   running)
3. Deletes task → SMB source location → S3 destination location → agent
   (CLI — these were created outside Terraform)
4. `terraform destroy` on `04-agent`
5. `terraform destroy` on `03-datasync`
6. Deletes SSM parameter `/datasync/efs-ready`; `terraform destroy` on
   `02-servers`
7. Force-deletes 5 Secrets Manager secrets; `terraform destroy` on
   `01-directory`

### `validate.sh`
Reads the SMB task ARN from SSM `/datasync/smb-task-arn` (errors if not
present — requires `activate-agent.sh` to have run). Starts the task, polls
every 15 seconds until `SUCCESS` or `ERROR`, prints a transfer summary, and
downloads CloudWatch log events to `datasync-smb-efs-<timestamp>.log`.

### `activate-agent.sh`
See Phase 4 Agent Activation above.

## Key IAM Resources

| Resource | Purpose |
|---|---|
| `ec2-secrets-role-*` | EC2 instance role for efs-client-gateway |
| `AmazonSSMManagedInstanceCore` | SSM Session Manager access |
| `secretsmanager:GetSecretValue` | Scoped to `admin_ad_credentials_efs` |
| `ssm:PutParameter` / `ssm:DeleteParameter` | SSM sentinel `/datasync/efs-ready` |
| `datasync-s3-role-*` | DataSync assumes this to write to S3 |

## Domain Users and Groups

| Username | uidNumber | Groups | Domain Admin |
|---|---|---|---|
| `jsmith` | 10001 | mcloud-users, us, linux-admins | Yes |
| `edavis` | 10002 | mcloud-users, us | No |
| `rpatel` | 10003 | mcloud-users, india, linux-admins | Yes |
| `akumar` | 10004 | mcloud-users, india | No |

**`rpatel` is used as the DataSync SMB credential** — it has a `uidNumber` set
in AD, is a member of `mcloud-users` (which owns `/efs`), and is a domain
admin. The `Admin` account has no `uidNumber` and cannot be mapped to a Linux
identity by SSSD/winbind.

| Group | gidNumber |
|---|---|
| `mcloud-users` | 10001 |
| `india` | 10002 |
| `us` | 10003 |
| `linux-admins` | 10004 |

## Important Notes

- **winbind trust must be explicit**: `realm join --membership-software=samba`
  alone is unreliable for winbind. Always follow with `net ads join -U
  Admin%<password>`. Without this, `wbinfo -t` fails and all NTLMv2
  authentication fails silently while Kerberos (Windows) connections work,
  making the problem hard to diagnose.
- **NTLMv2 required for DataSync**: The DataSync agent uses `mount.cifs` with
  NTLMv2. The `smb.conf` must include `ntlm auth = ntlmv2-only`. Windows
  clients are unaffected (they use Kerberos).
- **Use a POSIX user for SMB credentials**: The `Admin` AD account has no
  `uidNumber`. DataSync's agent mounts the share as that user — if winbind
  cannot map it to a Linux UID, access is denied even if authentication
  succeeds. Use `rpatel` or any user with `uidNumber` set.
- **Agent task is CLI-managed, not Terraform**: The DataSync agent, SMB
  location, S3 location, and task are all created by `activate-agent.sh`.
  `destroy.sh` must clean them up via CLI before `terraform destroy 04-agent`.
- **SMB subdirectory is the share name**: In `create-location-smb`, the
  `--subdirectory` is `/efs` — the leading slash plus the Samba share name,
  not a filesystem path.
- **Activation key is one-time**: The HTTP endpoint on port 80 returns the key
  only once and only while the agent is in an unactivated state. `activate-
  agent.sh` is idempotent via the SSM sentinel check.
- **Phase ordering is strict**: Each phase reads from prior phase state via
  data sources or Terraform outputs. All four phases must be applied in order.
- **Local Terraform state only** — no backend configured. Never commit
  `*.tfstate` or `*.tfstate.backup`.
- **Secret naming suffix**: All Secrets Manager secrets use the `_efs` suffix
  to avoid collisions with other lab projects using the same mini-ad module.

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
