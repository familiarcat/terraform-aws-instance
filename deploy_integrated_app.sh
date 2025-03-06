#!/usr/bin/env bash
set -euo pipefail

########################################
# 1. Select Base Folder (Workspace)
########################################
zenity --info --title="Deployment Workspace Setup" \
  --text="Select a base folder that will serve as your deployment workspace.
         This folder must contain your .env file and your Terraform templates.
         The script will generate the Next.js app in a subfolder named 'my-amplify-app'
         within this folder. Any previously generated content in that subfolder will be overwritten." || true

BASE_FOLDER=$(zenity --file-selection --directory --title="Select Base Folder (Workspace)" --filename="$(pwd)/")
if [ -z "${BASE_FOLDER:-}" ]; then
  echo "Folder selection canceled. Using current directory as default."
  BASE_FOLDER="$(pwd)"
fi
echo "Base folder selected: $BASE_FOLDER"
cd "$BASE_FOLDER" || exit 1

########################################
# 2. Load AWS Credentials & Global Variables
########################################
if [ -f .env ]; then
  echo "Loading AWS credentials from .env..."
  set -a; source .env; set +a
else
  echo "ERROR: .env file not found in ${BASE_FOLDER}."
  exit 1
fi

if [ -z "${AWS_DEFAULT_REGION:-}" ]; then
  AWS_DEFAULT_REGION=$(zenity --entry --title="AWS Region" --text="Enter AWS Region (e.g., us-east-2):")
  if [ -z "$AWS_DEFAULT_REGION" ]; then
    echo "AWS region is required. Exiting."
    exit 1
  fi
fi

ERROR_LOG="${BASE_FOLDER}/deployment_error.log"
: > "$ERROR_LOG"
export AWS_DEFAULT_REGION
export NODE_OPTIONS="--max_old_space_size=3000"
export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT="json"
export NONINTERACTIVE=1

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "ERROR: AWS credentials not set in .env file."
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS CLI could not validate your credentials. Check your .env file."
  exit 1
fi
echo "AWS credentials loaded and valid."

# Derive CERT_DOMAIN and HOSTED_ZONE_ID if not provided.
# For EC2 deployments, we use ec2.pbradygeorgen.com.
if [ -z "${CERT_DOMAIN+x}" ]; then
  base_zone=$(aws route53 list-hosted-zones --query "HostedZones[?ends_with(Name, 'pbradygeorgen.com.')].Name" --output text | head -n1)
  if [ -z "$base_zone" ]; then
    echo "ERROR: No hosted zone found for pbradygeorgen.com."
    exit 1
  fi
  base_domain="${base_zone%\.}"
  CERT_DOMAIN="ec2.${base_domain}"
  echo "Derived CERT_DOMAIN: $CERT_DOMAIN"
fi

if [ -z "${HOSTED_ZONE_ID:-}" ]; then
  base_domain="${CERT_DOMAIN#ec2.}"
  domain_lookup="${base_domain}."
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${domain_lookup}'].Id" --output text | sed 's|/hostedzone/||')
  if [ -z "$HOSTED_ZONE_ID" ]; then
    echo "ERROR: Unable to derive HOSTED_ZONE_ID for base domain ${base_domain}."
    exit 1
  fi
  echo "Derived HOSTED_ZONE_ID: $HOSTED_ZONE_ID"
fi

export DNS_TTL=${DNS_TTL:-300}
export USE_HTTPS=${USE_HTTPS:-true}

########################################
# 3. Set Project Folder for Next.js/Amplify App
########################################
AMPLIFY_DIR="${BASE_FOLDER}/my-amplify-app"
echo "Amplify project folder will be: $AMPLIFY_DIR"

########################################
# 4. Utility & Logging Functions
########################################
print_note() { echo -e "   \033[38;2;0;255;255mℹ\033[0m  $1"; }
print_step() { echo -e "   \033[38;2;100;170;255m▸\033[0m  $1"; }
print_success() { echo -e "   \033[38;2;100;255;150m✔\033[0m  $1"; }
print_error() { 
  echo -e "   \033[38;2;255;60;60m✘\033[0m  $1" 
  echo -e "$1" >> "$ERROR_LOG"
  exit 1
}
open_browser() {
  local url="$1"
  sleep 3
  if [[ "$OSTYPE" == "darwin"* ]]; then
    open "$url"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}
spinner() {
  local pid=$1; local delay=0.1; local spinstr="|/-\\"
  while kill -0 "$pid" 2>/dev/null; do
    printf " [%c]  " "${spinstr:0:1}"
    spinstr="${spinstr:1}${spinstr:0:1}"
    sleep "$delay"
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}
run_with_spinner() {
  local cmd="$1"
  eval "$cmd" &
  local pid=$!
  spinner "$pid"
  wait "$pid"
  return $?
}

########################################
# 5. Setup Next.js Project (or Overwrite)
########################################
setup_project() {
  local project_dir="$1"
  print_step "Setting up Next.js project in: $project_dir"
  if [ -d "$project_dir" ]; then
    print_note "Removing existing project directory: $project_dir"
    rm -rf "$project_dir" || print_error "Failed to remove $project_dir"
  fi
  NODE_NO_WARNINGS=1 npx create-next-app@latest "$project_dir" --typescript --tailwind --eslint --src-dir --import-alias "@/*" --use-yarn || print_error "Failed to create Next.js project"
  if [ -f .env ]; then
    print_step "Copying .env file into project directory."
    cp .env "$project_dir/.env"
  fi
  cd "$project_dir" || print_error "Failed to enter project directory."
  print_step "Updating package.json with deployment scripts..."
  jq '.scripts += {
    "dev": "next dev",
    "build": "next build",
    "start": "next start -p 3000 -H 0.0.0.0",
    "docker:build": "docker build -t my-amplify-app:latest .",
    "docker:run": "docker run -p 3000:3000 my-amplify-app:latest",
    "deploy": "cd terraform && terraform apply -auto-approve",
    "deploy:destroy": "cd terraform && terraform destroy -auto-approve"
  }' package.json > package.json.tmp && mv package.json.tmp package.json || print_error "Failed to update package.json"
  print_success "Project setup complete."
  cd "$BASE_FOLDER" || print_error "Failed to return to base folder"
}

########################################
# 6. Generate Multi-stage Dockerfile
########################################
generate_dockerfile() {
  print_step "Generating multi-stage Dockerfile in project directory..."
  cd "$AMPLIFY_DIR" || print_error "Failed to enter project directory"
  cat > Dockerfile << 'EOF'
# Build Stage
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

# Production Stage
FROM node:18-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
# Copy built artifacts and required folders
COPY --from=builder /app/package.json ./
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules
EXPOSE 3000
CMD ["npm", "start"]
EOF
  print_success "Dockerfile generated."
  cd "$BASE_FOLDER" || print_error "Failed to return to base folder"
}

########################################
# 7. Generate GitHub Actions CI/CD Workflow
########################################
generate_github_workflow() {
  print_step "Generating GitHub Actions CI/CD workflow..."
  mkdir -p "$AMPLIFY_DIR/.github/workflows"
  cat > "$AMPLIFY_DIR/.github/workflows/ci-cd.yml" << 'EOF'
name: CI/CD Pipeline

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'
      - name: Install dependencies
        run: npm ci
      - name: Run linting
        run: npm run lint || true
      - name: Run tests
        run: npm test || true
      - name: Build application
        run: npm run build

  deploy:
    needs: build-and-test
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1
      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v1
      - name: Build, tag, and push image to Amazon ECR
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: my-amplify-app
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v1
        with:
          terraform_version: 1.5.7
      - name: Terraform Init and Apply
        working-directory: terraform
        run: |
          terraform init
          terraform apply -auto-approve -var="docker_image=${{ steps.login-ecr.outputs.registry }}/my-amplify-app:${{ github.sha }}"
EOF
  print_success "CI/CD workflow generated."
}

########################################
# 8. Build Next.js Project & Docker Image, then Push to ECR
########################################
build_and_publish_docker() {
  print_step "Building Next.js project..."
  cd "$AMPLIFY_DIR" || print_error "Failed to enter project directory"
  yarn build || print_error "Next.js build failed"
  print_success "Next.js build successful."
  cd "$BASE_FOLDER" || print_error "Failed to return to base folder"

  ensure_docker_running() {
    if ! docker info >/dev/null 2>&1; then
      echo "Docker daemon is not running. Attempting to start Docker..."
      if [[ "$OSTYPE" == "darwin"* ]]; then
        open -a Docker
      elif command -v systemctl >/dev/null 2>&1; then
        sudo systemctl start docker
      fi
      local timeout=60 elapsed=0
      while ! docker info >/dev/null 2>&1; do
        sleep 2
        elapsed=$((elapsed+2))
        echo "Waiting for Docker daemon to start... ($elapsed seconds elapsed)"
        if [ $elapsed -ge $timeout ]; then
          print_error "Docker daemon did not start within $timeout seconds."
        fi
      done
      echo "Docker daemon is now running."
    else
      echo "Docker daemon is already running."
    fi
  }
  ensure_docker_running

  generate_dockerfile

  LOCAL_DOCKER_TAG="my-amplify-app:latest"
  print_step "Building Docker image with tag: $LOCAL_DOCKER_TAG"
  docker build -t "$LOCAL_DOCKER_TAG" "$AMPLIFY_DIR" || print_error "Docker build failed"
  print_success "Docker image built successfully."

  print_step "Publishing Docker image to ECR..."
  if ! aws ecr describe-repositories --repository-name "my-amplify-app" --region "$AWS_DEFAULT_REGION" >/dev/null 2>&1; then
    aws ecr create-repository --repository-name "my-amplify-app" --region "$AWS_DEFAULT_REGION" >/dev/null || print_error "Failed to create ECR repository"
  fi
  local REPO_URI
  REPO_URI=$(aws ecr describe-repositories --repository-name "my-amplify-app" --region "$AWS_DEFAULT_REGION" --query "repositories[0].repositoryUri" --output text)
  aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | docker login --username AWS --password-stdin "$REPO_URI" || print_error "Docker login to ECR failed"
  docker tag "$LOCAL_DOCKER_TAG" "$REPO_URI:latest" || print_error "Docker tag failed"
  docker push "$REPO_URI:latest" || print_error "Docker push failed"
  DOCKER_TAG="$REPO_URI:latest"
  echo "Docker image published: $DOCKER_TAG"
}

########################################
# 9. Generate Terraform Configuration
########################################
generate_terraform_config() {
  rm -f "$BASE_FOLDER/terraform"/*.tf
  mkdir -p "$BASE_FOLDER/terraform"
  if [ "$DEPLOYMENT_TYPE" = "Fargate Deployment" ]; then
    CERT_DOMAIN="fargate.${CERT_DOMAIN#*.}"
    cat > "$BASE_FOLDER/terraform/main.tf" <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "my-amplify-app-terraform-state"
    key    = "terraform.tfstate"
    region = "${AWS_DEFAULT_REGION}"
  }
}

provider "aws" {
  region = "${AWS_DEFAULT_REGION}"
}

resource "aws_ecr_repository" "app_repo" {
  name                 = "my-amplify-app"
  image_tag_mutability = "MUTABLE"
}

resource "aws_acm_certificate" "cert" {
  domain_name               = "${CERT_DOMAIN}"
  subject_alternative_names = ["*.${substr(CERT_DOMAIN, index(CERT_DOMAIN, ".") + 1, length(CERT_DOMAIN))}"]
  validation_method         = "DNS"
}

resource "aws_route53_record" "cert_validation" {
  name    = aws_acm_certificate.cert.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.cert.domain_validation_options[0].resource_record_type
  zone_id = "${HOSTED_ZONE_ID}"
  records = [aws_acm_certificate.cert.domain_validation_options[0].resource_record_value]
  ttl     = var.dns_ttl
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "alb" {
  name               = "my-amplify-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "tg" {
  name        = "my-amplify-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/api/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.cert_validation.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_ecs_cluster" "cluster" {
  name = "my-amplify-cluster"
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name = "ecsTaskExecutionRole-my-amplify"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Effect    = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRolePolicy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "task" {
  family                   = "my-amplify-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn
  container_definitions    = jsonencode([{
    name         = "my-amplify-container",
    image        = "${DOCKER_TAG}",
    essential    = true,
    portMappings = [{
      containerPort = 3000,
      protocol      = "tcp"
    }],
    environment = [{
      name  = "PORT",
      value = "3000"
    }]
  }])
}

resource "aws_ecs_service" "service" {
  name            = "my-amplify-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "my-amplify-container"
    container_port   = 3000
  }
}

output "endpoint" {
  description = "ALB DNS for Fargate deployment (access via HTTPS)"
  value       = aws_lb.alb.dns_name
}

variable "dns_ttl" {
  type    = number
  default = 300
}
EOF
  else
    # EC2 Deployment Terraform configuration
    cat > "$BASE_FOLDER/terraform/main.tf" <<EOF
provider "aws" {
  region = var.region
}

variable "ami_id" {
  type = string
}
variable "region" {
  type = string
}
variable "docker_image" {
  type = string
}
variable "public_key" {
  type = string
}
variable "create_keypair" {
  type    = bool
  default = false
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_key_pair" "default" {
  count      = var.create_keypair ? 1 : 0
  key_name   = "my-ssh-key"
  public_key = var.public_key
}

resource "aws_security_group" "instance_sg" {
  name        = "instance-sg"
  description = "Allow HTTP, HTTPS and SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "my_instance" {
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  associate_public_ip_address = true
  key_name                    = var.create_keypair ? aws_key_pair.default[0].key_name : "my-ssh-key"
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]
  tags = {
    Name = "my-amplify-instance"
  }
  user_data = <<EOD
#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -x
yum update -y
amazon-linux-extras install docker -y
service docker start
usermod -a -G docker ec2-user
sleep 10
aws ecr get-login-password --region \${var.region} | docker login --username AWS --password-stdin \$(echo \${var.docker_image} | cut -d/ -f1)
docker run --restart always -d -p 80:3000 \${var.docker_image} || echo "Failed to run container" >> /tmp/docker-error.log
EOD
}

resource "aws_route53_record" "ec2_record" {
  zone_id = "${HOSTED_ZONE_ID}"
  name    = "ec2.${CERT_DOMAIN#ec2.}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.my_instance.public_ip]
}

output "endpoint" {
  description = "Public URL of the EC2 instance (access via HTTP)"
  value       = aws_route53_record.ec2_record.fqdn
}
EOF
  fi
}

# Function to allow AMI selection for EC2 deployment.
select_ami() {
  print_step "Retrieving list of AMIs from AWS..."
  # Query for Amazon Linux 2 AMIs; sort by VolumeSize (ascending: smallest first)
  AMI_LIST=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" \
    --query 'Images[*].[ImageId,Name,BlockDeviceMappings[0].Ebs.VolumeSize]' \
    --output text | sort -k3,3n)
  if [ -z "$AMI_LIST" ]; then
    print_error "No AMIs found in region ${AWS_DEFAULT_REGION}."
  fi
  # Format each line with AMI ID and a human-readable description.
  AMI_OPTIONS=$(echo "$AMI_LIST" | awk '{printf "%s\t%s (Volume: %s GiB)\n", $1, $2, $3}')
  AMI_SELECTION=$(echo "$AMI_OPTIONS" | zenity --list \
    --title="Select an AMI for EC2 Deployment" \
    --column="AMI ID" --column="Description" \
    --height=400 --width=800)
  if [ -z "$AMI_SELECTION" ]; then
    print_error "No AMI selected. Exiting."
  fi
  AMI_ID=$(echo "$AMI_SELECTION" | awk '{print $1}')
  print_success "Selected AMI ID: $AMI_ID"
}

########################################
# 10. Update Route 53 DNS Record if Health Check Fails
########################################
update_dns_record() {
  print_step "Updating Route 53 DNS record for EC2 deployment..."
  INSTANCE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=my-amplify-instance" --query "Reservations[].Instances[].PublicIpAddress" --output text)
  if [ -z "$INSTANCE_IP" ]; then
    print_error "Could not determine instance public IP for DNS update."
  fi
  cat > change_batch.json <<EOF
{
  "Comment": "Update A record for my-amplify-instance",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "ec2.pbradygeorgen.com",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [
          {"Value": "$INSTANCE_IP"}
        ]
      }
    }
  ]
}
EOF
  aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file://change_batch.json
  print_success "Route 53 DNS record updated to $INSTANCE_IP"
}

########################################
# 11. Deploy via Terraform
########################################
deploy_via_terraform() {
  if [ "$DEPLOYMENT_TYPE" != "Fargate Deployment" ]; then
    if aws ec2 describe-key-pairs --key-names "my-ssh-key" >/dev/null 2>&1; then
      CREATE_KEYPAIR=false
    else
      CREATE_KEYPAIR=true
    fi
    select_ami
  fi
  generate_terraform_config
  cd "$BASE_FOLDER/terraform" || print_error "Failed to enter Terraform directory"
  terraform init || print_error "Terraform init failed."
  if [ "$DEPLOYMENT_TYPE" = "Fargate Deployment" ]; then
    print_step "Deploying to Fargate with Docker image: $DOCKER_TAG"
    terraform apply -var "region=${AWS_DEFAULT_REGION}" -var "docker_image=${DOCKER_TAG}" -var "cert_domain=${CERT_DOMAIN}" -var "hosted_zone_id=${HOSTED_ZONE_ID}" -auto-approve || print_error "Terraform apply failed"
  else
    print_step "Deploying to EC2 with Docker image: $DOCKER_TAG"
    PUBLIC_KEY=$(tr -d '\n' < "${HOME}/.ssh/id_ed25519.pub")
    terraform apply \
      -var "region=${AWS_DEFAULT_REGION}" \
      -var "ami_id=${AMI_ID}" \
      -var "docker_image=${DOCKER_TAG}" \
      -var "public_key=${PUBLIC_KEY}" \
      -var "create_keypair=${CREATE_KEYPAIR}" \
      -auto-approve || print_error "Terraform apply failed"
  fi
  cd "$BASE_FOLDER" || print_error "Failed to return to base folder"
}

########################################
# 12. Check Application Health & Update DNS if Needed
########################################
check_app_health() {
  local url="http://$1"
  local max_attempts=20
  local attempt=1
  print_step "Checking application health at $url..."
  while [ $attempt -le $max_attempts ]; do
    if curl -s -f "$url" >/dev/null; then
      print_success "Application is healthy at $url"
      return 0
    else
      print_note "Attempt $attempt: Application not reachable, retrying in 15 seconds..."
      sleep 15
      attempt=$((attempt+1))
    fi
  done
  return 1
}

########################################
# 13. Main Execution Flow
########################################
main() {
  print_step "Starting deployment process..."
  setup_project "$AMPLIFY_DIR"
  generate_github_workflow
  build_and_publish_docker
  
  DEPLOYMENT_TYPE=$(zenity --list --title="Select Deployment Platform" --text="Choose a deployment platform:" --column="Platform" "EC2 Instance" "Fargate Deployment" --height=200 --width=400)
  if [ -z "${DEPLOYMENT_TYPE:-}" ]; then
    zenity --info --title="Canceled" --text="Deployment platform selection canceled."
    exit 1
  fi
  print_step "Selected Deployment Platform: $DEPLOYMENT_TYPE"
  
  if [ "$DEPLOYMENT_TYPE" = "Fargate Deployment" ]; then
    CERT_DOMAIN="fargate.${CERT_DOMAIN#*.}"
  else
    CERT_DOMAIN="ec2.${CERT_DOMAIN#*.}"
  fi
  
  deploy_via_terraform
  
  sleep 10
  if [ "$DEPLOYMENT_TYPE" = "EC2 Instance" ]; then
    INSTANCE_ENDPOINT=$(terraform -chdir="$BASE_FOLDER/terraform" output -raw endpoint)
    if [ -z "${INSTANCE_ENDPOINT}" ]; then
      print_error "Terraform output 'endpoint' is empty. Check your Terraform configuration."
    fi
    print_step "EC2 instance deployed with URL: $INSTANCE_ENDPOINT"
    if ! check_app_health "$INSTANCE_ENDPOINT"; then
      print_note "Health check failed. Updating DNS record..."
      update_dns_record
      sleep 10
      if ! check_app_health "$INSTANCE_ENDPOINT"; then
        print_error "Application still not healthy after DNS update."
      fi
    fi
    open_browser "http://${INSTANCE_ENDPOINT}"
  elif [ "$DEPLOYMENT_TYPE" = "Fargate Deployment" ]; then
    FINAL_ENDPOINT=$(terraform -chdir="$BASE_FOLDER/terraform" output -raw endpoint)
    if [ -z "${FINAL_ENDPOINT}" ]; then
      print_error "Terraform output 'endpoint' is empty for Fargate. Check your Terraform configuration."
    fi
    print_step "Fargate endpoint detected: $FINAL_ENDPOINT"
    open_browser "https://${FINAL_ENDPOINT}"
  fi
  
  print_success "Deployment complete."
}

main
