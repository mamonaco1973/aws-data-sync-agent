# ================================================================================
# FILE: agent.tf
#
# Purpose:
#   - Provisions an AWS DataSync agent EC2 instance.
#   - The agent enables DataSync to reach SMB sources inside the VPC that
#     are not accessible from the public DataSync service endpoints.
#
# Scope:
#   - DataSync agent AMI resolution via SSM.
#   - Security group allowing HTTP/80 for activation and outbound SMB/445.
#   - EC2 instance running the DataSync agent software.
#
# Notes:
#   - The agent AMI is maintained by AWS and resolved dynamically via the
#     standard SSM parameter path.
#   - After Terraform apply, activate-agent.sh performs HTTP activation and
#     registers the agent with the DataSync service.
#   - Port 80 must remain open until activation completes; it can be removed
#     from the security group afterwards in production environments.
# ================================================================================

# ================================================================================
# DATA: DataSync Agent AMI
# ================================================================================
# Purpose:
#   - Resolves the current AWS-provided DataSync agent AMI ID.
#
# Notes:
#   - AWS maintains this SSM parameter and updates it when new agent versions
#     are released. Using it ensures the latest supported agent is deployed.
# ================================================================================
data "aws_ssm_parameter" "datasync_ami" {
  name = "/aws/service/datasync/ami"
}

# ================================================================================
# RESOURCE: aws_security_group.datasync_agent_sg
# ================================================================================
# Purpose:
#   - Allows inbound HTTP/80 from anywhere for one-time agent activation.
#   - Allows all outbound traffic so the agent can reach the SMB share on
#     efs-client-gateway (TCP/445) and DataSync service endpoints (HTTPS/443).
#
# Notes:
#   - Ingress is open to 0.0.0.0/0 for lab convenience. Restrict to the
#     activation host CIDR in production.
# ================================================================================
resource "aws_security_group" "datasync_agent_sg" {
  name        = "datasync-agent-sg"
  description = "DataSync agent - HTTP/80 for activation, outbound to SMB and AWS"
  vpc_id      = data.aws_vpc.ad_vpc.id

  # ------------------------------------------------------------------------------
  # INGRESS: HTTP (TCP/80) — DataSync activation endpoint
  # ------------------------------------------------------------------------------
  ingress {
    description = "Allow HTTP for DataSync agent activation (demo only)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ------------------------------------------------------------------------------
  # EGRESS: ALL
  # Allows the agent to reach the SMB share (TCP/445) and AWS endpoints.
  # ------------------------------------------------------------------------------
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "datasync-agent-sg" }
}

# ================================================================================
# RESOURCE: aws_instance.datasync_agent
# ================================================================================
# Purpose:
#   - Runs the AWS DataSync agent software.
#   - Acts as the bridge between the DataSync service and the Samba SMB share
#     running on efs-client-gateway inside the VPC.
#
# Notes:
#   - t3.large is the minimum recommended size for DataSync agents to avoid
#     memory pressure during transfer operations.
#   - A public IP is required so activate-agent.sh can reach port 80 for the
#     one-time activation handshake.
#   - No IAM instance profile is required — the agent authenticates to the
#     DataSync service using the activation key, not instance credentials.
# ================================================================================
resource "aws_instance" "datasync_agent" {
  ami           = data.aws_ssm_parameter.datasync_ami.value
  instance_type = "t3.large"

  subnet_id                   = data.aws_subnet.vm_subnet_1.id
  vpc_security_group_ids      = [aws_security_group.datasync_agent_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "datasync-agent"
  }
}

# ================================================================================
# OUTPUT: agent_public_ip
# ================================================================================
# Purpose:
#   - Exposes the agent's public IP for use in activate-agent.sh.
# ================================================================================
output "agent_public_ip" {
  description = "Public IP of the DataSync agent EC2 instance"
  value       = aws_instance.datasync_agent.public_ip
}

# ================================================================================
# OUTPUT: agent_instance_id
# ================================================================================
# Purpose:
#   - Exposes the instance ID for reference and debugging.
# ================================================================================
output "agent_instance_id" {
  description = "EC2 instance ID of the DataSync agent"
  value       = aws_instance.datasync_agent.id
}
