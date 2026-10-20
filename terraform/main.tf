# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

# Create a security group that allows SSH
resource "aws_security_group" "journal_sg" {
  name        = "journal-sg"
  description = "Security group for Journal API EC2 instance"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # En producción restringir a tu IP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "journal-api-sg"
  }
}

# Launch an EC2 instance
resource "aws_instance" "journal_api" {
  ami           = "ami-0856027a77429315a"  # Amazon Linux 2023
  instance_type = "t3.micro"
  security_groups = [aws_security_group.journal_sg.name]

  tags = {
    Name = "journal-api-instance"
  }
}

# Output the public IP
output "public_ip" {
  value = aws_instance.journal_api.public_ip
}
