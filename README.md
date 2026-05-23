# Multi-Cloud Docker Deployment using Terraform (AWS + Azure)

## Overview

This project provisions infrastructure on both:

* AWS
* Microsoft Azure

Using a single Terraform file.

The infrastructure automatically:

* Creates networking resources
* Creates virtual machines
* Installs Docker
* Pulls a Docker image from Docker Hub
* Runs the container on port `5000`
* Exposes the application publicly

---

# Architecture

## AWS

Terraform provisions:

* VPC
* Public Subnet
* Internet Gateway
* Route Table
* Route Table Association
* Security Group
* EC2 Instance

The EC2 instance:

* Installs Docker
* Logs into Docker Hub
* Pulls Docker image
* Runs container on port `5000`

---

## Azure

Terraform provisions:

* Resource Group
* Virtual Network
* Subnet
* Public IP
* Network Security Group
* Network Interface
* Linux Virtual Machine

The Azure VM:

* Installs Docker
* Logs into Docker Hub
* Pulls Docker image
* Runs container on port `5000`

---

# Technologies Used

* Terraform
* AWS EC2
* AWS VPC
* Azure Virtual Machines
* Docker
* Ubuntu Linux

---

# Project Structure

```text
.
├── terraform.tf
├── terraform.tfvars
├── variables.tf
├── outputs.tf
└── README.md
```

---

# Secure Terraform Configuration

## IMPORTANT

Do NOT hardcode credentials directly inside Terraform files.

Use:

* `terraform.tfvars`
* Environment Variables
* GitHub Secrets
* AWS Secrets Manager
* Azure Key Vault

---

# variables.tf

```hcl
variable "docker_username" {
  type      = string
  sensitive = true
}

variable "docker_password" {
  type      = string
  sensitive = true
}
```

---

# terraform.tfvars

```hcl
docker_username = "YOUR_DOCKER_USERNAME"
docker_password = "YOUR_DOCKER_PASSWORD"
```

---

# Add to .gitignore

```gitignore
terraform.tfvars
*.tfstate
*.tfstate.backup
.terraform/
```

---

# Main Terraform File

## terraform.tf

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# =====================================================
# VARIABLES
# =====================================================

variable "docker_username" {
  type      = string
  sensitive = true
}

variable "docker_password" {
  type      = string
  sensitive = true
}

# =====================================================
# PROVIDERS
# =====================================================

provider "aws" {
  region = "ap-south-1"
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  skip_provider_registration = true
}

# =====================================================
# GET LATEST UBUNTU AMI
# =====================================================

data "aws_ami" "ubuntu" {
  most_recent = true

  owners = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =====================================================
# AWS VPC
# =====================================================

resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "aws-main-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "aws-igw"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "aws-public-subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "aws-public-route-table"
  }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "web_sg" {
  name        = "aws-web-sg"
  description = "Allow SSH and Flask App"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description = "SSH"

    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Flask App"

    from_port = 5000
    to_port   = 5000
    protocol  = "tcp"

    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aws-web-sg"
  }
}

# =====================================================
# AWS EC2
# =====================================================

resource "aws_instance" "docker_server" {

  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true

  user_data_replace_on_change = true

  tags = {
    Name = "aws-docker-server"
  }

  user_data = <<-EOF
#!/bin/bash

apt update -y

apt install docker.io -y

systemctl start docker
systemctl enable docker

echo "${var.docker_password}" | docker login -u ${var.docker_username} --password-stdin

docker pull shivtushal/git-lab:python-app-1.0

docker run -d -p 5000:5000 shivtushal/git-lab:python-app-1.0

EOF
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

  admin_password = "Azure@123456"

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
# OUTPUTS
# =====================================================

output "aws_public_ip" {
  value = aws_instance.docker_server.public_ip
}

output "azure_public_ip" {
  value = azurerm_public_ip.public_ip.ip_address
}
```

---

# Deployment Steps

## AWS CLI Login

```bash
aws configure
```

---

## Azure CLI Login

```bash
az login
```

---

## Initialize Terraform

```bash
terraform init
```

---

## Validate Terraform

```bash
terraform validate
```

---

## Apply Infrastructure

```bash
terraform apply
```

---

## Get Outputs

```bash
terraform output
```

---

# Access Application

## AWS

```text
http://AWS_PUBLIC_IP:5000
```

---

## Azure

```text
http://AZURE_PUBLIC_IP:5000
```

---

# Destroy Infrastructure

```bash
terraform destroy
```

---

# Problems Faced and Fixes

## AWS IAM PassRole Error

### Problem

Terraform could not attach IAM role to EC2.

### Fix

Added:

```json
{
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec2-secrets-role"
}
```

---

## AWS Credential Override Issue

### Problem

`aws configure` inside EC2 overrode IAM role credentials.

### Fix

Removed local AWS credentials and used IAM role credentials.

---

## Azure VM SKU Unavailable

### Problem

Requested VM sizes unavailable in selected regions.

### Fix

Changed Azure region and VM SKU.

---

## Azure Resource Group Destroy Error

### Problem

Terraform refused to destroy resource group because unmanaged SSH key resources existed.

### Fix

Added:

```hcl
prevent_deletion_if_contains_resources = false
```

inside Azure provider features block.

---

# Security Recommendations

## Recommended Improvements

* Use AWS Secrets Manager
* Use Azure Key Vault
* Use Docker Access Tokens instead of passwords
* Use SSH authentication instead of passwords
* Restrict Security Group IP ranges
* Store Terraform state remotely
* Use GitHub Actions Secrets

---

# Author

Shiv Tushal

Multi-Cloud Infrastructure Deployment using Terraform.
