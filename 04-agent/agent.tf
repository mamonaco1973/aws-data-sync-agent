# ================================================================================
# FILE: agent.tf
#
# Purpose:
#   - Provisions two AWS DataSync agent EC2 instances.
#   - Each agent handles two of the four EFS project directories, distributing
#     transfer load across independent agents running in parallel.
#
# Scope:
#   - DataSync agent AMI resolution via SSM.
#   - Shared security group allowing HTTP/80 for activation and outbound SMB/445.
#   - Two EC2 instances running the DataSync agent software.
#
# Agent assignment (configured in activate-agent.sh):
#   - Agent 1: aws-efs, aws-mgn-example
#   - Agent 2: aws-workspaces, aws-mysql
#
# Notes:
#   - The agent AMI is maintained by AWS and resolved dynamically via the
#     standard SSM parameter path.
#   - After Terraform apply, activate-agent.sh performs HTTP activation for
#     each agent and registers them with the DataSync service.
#   - Port 80 must remain open until activation completes.
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
#   - Shared security group attached to both agent instances.
#   - Allows inbound HTTP/80 from anywhere for one-time agent activation.
#   - Allows all outbound traffic so agents can reach the SMB share on
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
  # Allows agents to reach the SMB share (TCP/445) and AWS endpoints.
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
# RESOURCE: aws_instance.datasync_agent_1
# ================================================================================
# Purpose:
#   - First DataSync agent. Handles aws-efs and aws-mgn-example transfers.
# ================================================================================
resource "aws_instance" "datasync_agent_1" {
  ami           = data.aws_ssm_parameter.datasync_ami.value
  instance_type = "t3.large"

  subnet_id                   = data.aws_subnet.vm_subnet_1.id
  vpc_security_group_ids      = [aws_security_group.datasync_agent_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "datasync-agent-1"
  }
}

# ================================================================================
# RESOURCE: aws_instance.datasync_agent_2
# ================================================================================
# Purpose:
#   - Second DataSync agent. Handles aws-workspaces and aws-mysql transfers.
# ================================================================================
resource "aws_instance" "datasync_agent_2" {
  ami           = data.aws_ssm_parameter.datasync_ami.value
  instance_type = "t3.large"

  subnet_id                   = data.aws_subnet.vm_subnet_1.id
  vpc_security_group_ids      = [aws_security_group.datasync_agent_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "datasync-agent-2"
  }
}

# ================================================================================
# OUTPUTS: Agent public IPs
# ================================================================================
output "agent_1_public_ip" {
  description = "Public IP of DataSync agent 1 (aws-efs, aws-mgn-example)"
  value       = aws_instance.datasync_agent_1.public_ip
}

output "agent_2_public_ip" {
  description = "Public IP of DataSync agent 2 (aws-workspaces, aws-mysql)"
  value       = aws_instance.datasync_agent_2.public_ip
}

output "agent_1_instance_id" {
  description = "Instance ID of DataSync agent 1"
  value       = aws_instance.datasync_agent_1.id
}

output "agent_2_instance_id" {
  description = "Instance ID of DataSync agent 2"
  value       = aws_instance.datasync_agent_2.id
}
