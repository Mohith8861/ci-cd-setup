terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.15.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region to create resources in"
  type        = string
  default     = "us-east-1"
}

resource "tls_private_key" "ci-cd-key-pair" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "local_file" "private_key" {
  content  = tls_private_key.ci-cd-key-pair.private_key_pem
  filename = "${path.module}/my-key.pem" #
}

resource "aws_key_pair" "ci-cd-key-pair" {
  key_name   = "ci-cd-key-pair"
  public_key = tls_private_key.ci-cd-key-pair.public_key_openssh
}

resource "tls_private_key" "cluster-key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "local_file" "cluster_private_key" {
  content  = tls_private_key.cluster-key.private_key_pem
  filename = "${path.module}/cluster-key.pem"
}

resource "aws_key_pair" "cluster-key" {
  key_name   = "cluster-key"
  public_key = tls_private_key.cluster-key.public_key_openssh
}

resource "aws_security_group" "ci-cd-sg" {
  name = "ci-cd-sg"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 25
    to_port     = 25
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 465
    to_port     = 465
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 10000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ci_cd_role" {
  name = "ci-cd-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Custom inline EKS policy
resource "aws_iam_policy" "eks_req" {
  name = "ci-cd-eks-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid      = "EKSFullAccess",
      Effect   = "Allow",
      Action   = "eks:*",
      Resource = "*"
    }]
  })
}

# Attach AWS managed policies to the role
resource "aws_iam_role_policy_attachment" "ec2_full_access" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cloudformation_full_access" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCloudFormationFullAccess"
}

resource "aws_iam_role_policy_attachment" "iam_full_access" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

# Attach custom EKS policy
resource "aws_iam_role_policy_attachment" "eks_req_attach" {
  role       = aws_iam_role.ci_cd_role.name
  policy_arn = aws_iam_policy.eks_req.arn
}

# Create an instance profile for EC2
resource "aws_iam_instance_profile" "ci_cd_profile" {
  name = "ci-cd-instance-profile"
  role = aws_iam_role.ci_cd_role.name
}

resource "aws_instance" "ci_cd_instance" {
  ami                  = "ami-0360c520857e3138f"
  instance_type        = "t2.large"
  key_name             = aws_key_pair.ci-cd-key-pair.key_name
  security_groups      = [aws_security_group.ci-cd-sg.name]
  iam_instance_profile = aws_iam_instance_profile.ci_cd_profile.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "ci-cd-instance"
  }

  provisioner "file" {
    source      = "${path.module}/k8"
    destination = "/home/ubuntu/k8"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.ci-cd-key-pair.private_key_pem
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {

    script = "${path.module}/script.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.ci-cd-key-pair.private_key_pem
      host        = self.public_ip
    }
  }
}
