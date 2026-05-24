terraform {
  required_providers {

    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# =====================================================
# VARIABLES
# =====================================================

variable "docker_username" {
  type        = string
  description = "Docker Hub Username"
  sensitive   = true
}

variable "docker_password" {
  type        = string
  description = "Docker Hub Password"
  sensitive   = true
}

# =====================================================
# AWS PROVIDER
# =====================================================

provider "aws" {
  region = "ap-south-1"
}

# =====================================================
# AZURE PROVIDER
# =====================================================

provider "azurerm" {

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# =====================================================
# VPC
# =====================================================

resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }
}

# =====================================================
# INTERNET GATEWAY
# =====================================================

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "main-igw"
  }
}

# =====================================================
# PUBLIC SUBNET
# =====================================================

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

# =====================================================
# ROUTE TABLE
# =====================================================

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# =====================================================
# SECURITY GROUP
# =====================================================

resource "aws_security_group" "web_sg" {
  name        = "web-sg"
  description = "Allow SSH and Flask"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Flask App"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-sg"
  }
}

# =====================================================
# UBUNTU AMI
# =====================================================

data "aws_ami" "ubuntu" {
  most_recent = true

  owners = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =====================================================
# IAM ROLE
# =====================================================

resource "aws_iam_role" "ec2_secrets_role" {
  name = "ec2-secrets-role-v2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

# =====================================================
# IAM POLICY
# =====================================================

resource "aws_iam_role_policy" "secrets_policy" {
  name = "secrets-policy"
  role = aws_iam_role.ec2_secrets_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "secretsmanager:GetSecretValue"
        ]

        Resource = "arn:aws:secretsmanager:ap-south-1:*:secret:docker*"
      }
    ]
  })
}

# =====================================================
# INSTANCE PROFILE
# =====================================================

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-secrets-profile-v2"
  role = aws_iam_role.ec2_secrets_role.name
}

# =====================================================
# EC2 INSTANCE
# =====================================================

resource "aws_instance" "docker_server" {

  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
              #!/bin/bash

              apt update -y

              apt install -y \
                awscli \
                docker.io \
                jq \
                python3-pip

              systemctl start docker
              systemctl enable docker

              SECRET=$(aws secretsmanager get-secret-value \
                --secret-id docker \
                --region ap-south-1 \
                --query SecretString \
                --output text)

              echo "$SECRET" > /home/ubuntu/docker-secret.json

              DOCKER_USERNAME=$(echo $SECRET | jq -r '.user_name')
              DOCKER_PASSWORD=$(echo $SECRET | jq -r '.user_pass')
              DOCKER_IMAGE="shivtushal/git-lab:python-app-1.0"

              echo $DOCKER_PASSWORD | docker login -u $DOCKER_USERNAME --password-stdin

              docker pull $DOCKER_IMAGE

              docker run -d -p 5000:5000 $DOCKER_IMAGE

              EOF

  tags = {
    Name = "docker-server"
  }
}

# =====================================================
# AWS OUTPUTS
# =====================================================

output "aws_public_ip" {
  value = aws_instance.docker_server.public_ip
}

output "aws_instance_id" {
  value = aws_instance.docker_server.id
}

# =====================================================
# AZURE RESOURCE GROUP
# =====================================================

resource "azurerm_resource_group" "rg" {
  name     = "azure-devops-rg-eastasia"
  location = "East Asia"
}

# =====================================================
# AZURE VNET
# =====================================================

resource "azurerm_virtual_network" "vnet" {
  name                = "azure-vnet"
  address_space       = ["10.1.0.0/16"]

  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# =====================================================
# AZURE SUBNET
# =====================================================

resource "azurerm_subnet" "subnet" {
  name                 = "azure-subnet"

  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name

  address_prefixes = ["10.1.1.0/24"]
}

# =====================================================
# AZURE PUBLIC IP
# =====================================================

resource "azurerm_public_ip" "public_ip" {
  name                = "azure-public-ip"

  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  allocation_method = "Static"

  sku = "Standard"
}

# =====================================================
# AZURE NSG
# =====================================================

resource "azurerm_network_security_group" "nsg" {
  name                = "azure-nsg"

  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name = "SSH"

    priority  = 100
    direction = "Inbound"
    access    = "Allow"
    protocol  = "Tcp"

    source_port_range      = "*"
    destination_port_range = "22"

    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name = "FlaskApp"

    priority  = 101
    direction = "Inbound"
    access    = "Allow"
    protocol  = "Tcp"

    source_port_range      = "*"
    destination_port_range = "5000"

    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# =====================================================
# AZURE NIC
# =====================================================

resource "azurerm_network_interface" "nic" {
  name                = "azure-nic"

  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name = "internal"

    subnet_id = azurerm_subnet.subnet.id

    private_ip_address_allocation = "Dynamic"

    public_ip_address_id = azurerm_public_ip.public_ip.id
  }
}

# =====================================================
# NSG ASSOCIATION
# =====================================================

resource "azurerm_network_interface_security_group_association" "nsg_association" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# =====================================================
# AZURE VM
# =====================================================

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "azure-docker-vm"

  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  size = "Standard_D2ls_v5"

  admin_username = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  disable_password_authentication = false

  admin_password = "CHANGE_ME"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
#!/bin/bash

apt update -y

apt install docker.io -y

systemctl start docker
systemctl enable docker

echo "${var.docker_password}" | docker login -u ${var.docker_username} --password-stdin

docker pull shivtushal/git-lab:python-app-1.0

docker run -d -p 5000:5000 shivtushal/git-lab:python-app-1.0

EOF
)
}

# =====================================================
# AZURE OUTPUTS
# =====================================================

output "azure_public_ip" {
  value = azurerm_public_ip.public_ip.ip_address
}
