#!/bin/bash

# Enable debug mode
# set -x

export LC_ALL=C
green=$(tput setaf 2)
normal="\033[0m"

log_green() {
  printf "${green}$@${normal}\n"
}

log_separetor() {
  echo "----------------------------------------"
  echo
}

usage() {
  echo "USAGE: deploy-aws.sh [OPTIONS]"
  echo "  Options: "
  echo "    -h Print this help message"
  echo "    -k AWS Key Pair Name (default: mykey)"
  echo "    -s Security Group Name (default: my-sg)"
}

get_vpc_id() {
  echo "Getting VPC ID..."
  VPC_ID="$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)"
  echo -n "VPC ID: "
  log_green $VPC_ID
  log_separetor
}

get_ami_id() {
  echo "Getting AMI ID..."
  AMI_ID="$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-2.0.????????.?-x86_64-gp2" "Name=state,Values=available" \
    --query "reverse(sort_by(Images, &CreationDate))[:1].ImageId" \
    --output text)"
  echo -n "AMI ID: "
  log_green $AMI_ID
  log_separetor
}

get_subnet_id() {
  echo "Getting Subnet ID..."
  SUBNET_ID="$(aws ec2 describe-subnets --query "Subnets[0].SubnetId" --output text)"
  echo -n "Subnet ID: "
  log_green $SUBNET_ID
  log_separetor
}

get_instance_dns() {
  echo "Getting Instance DNS..."
  INSTANCES_DNS="$(aws ec2 describe-instances \
    --filters Name="instance-state-name",Values="running" \
    --query "Reservations[].Instances[].PublicDnsName" \
    --output text)"
  echo -n "Instances DNS: "
  log_green $INSTANCES_DNS
  log_separetor
}

create_keypair() {
  echo "Creating Key Pair..."
  local key_name="${KEY_NAME:-mykey}"
  aws ec2 create-key-pair \
    --key-name "$key_name" \
    --query 'KeyMaterial' \
    --output text >"$key_name".pem
  chmod 400 "$key_name".pem
  echo -n "Key Pair created: "
  log_green "$key_name.pem"
  log_separetor
}

create_configure_security_group() {
  echo "Creating Security Group..."
  SG="$(
    aws ec2 create-security-group \
      --group-name "${SECURITY_GROUP:-"my-sg"}" \
      --description 'My security group' --vpc-id ${VPC_ID} \
      --query 'GroupId' \
      --output text
  )"
  printf "Security Group created: "
  log_green $SG
  log_separetor
  echo "Configuring Security Group..."
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG" \
    --protocol tcp \
    --port 3000 \
    --cidr 0.0.0.0/0 >/dev/null
  log_green "Security Group configured"
  log_separetor
}

create_instances() {
  echo "Creating Instances..."
  INSTANCE_IDS="$(aws ec2 run-instances --image-id "$AMI_ID" \
    --count 3 \
    --instance-type t2.micro \
    --key-name "${KEY_NAME:-mykey}" \
    --security-group-ids "$SG" \
    --subnet-id "$SUBNET_ID" \
    --query 'Instances[].InstanceId' \
    --output text)"
  echo "Waiting for instance to be running..."
  instances=()
  for instance in $INSTANCE_IDS; do
    instances+=("$instance")
  done
  aws ec2 wait instance-status-ok --instance-ids "${instances[@]}"
  echo -n "Instances running: "
  log_green $INSTANCE_IDS
  log_separetor
}

update_instances() {
  echo "Updating Instances..."
  for instance in $INSTANCES_DNS; do
    ssh -i "${KEY_NAME:-mykey}".pem ec2-user@"$instance" 'sudo yum update -y && \
      sudo yum install -y gcc-c++ make && \
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash && \
      . ~/.nvm/nvm.sh && \
      nvm install 16 && \
      nvm use 16 && \
      npm install -g serve'
    log_green "Updated instance $instance"
  done
  log_green "Instances updated"
  log_separetor
}

build_website() {
  echo "Building Website..."
  pushd simple-app-react/
  npm run build
  tar -czf ../build.tar.gz build
  popd
  log_green "Website built"
  log_separetor
}

upload_website() {
  echo "Uploading website..."
  for instance in $INSTANCES_DNS; do
    scp -i "${KEY_NAME:-mykey}".pem build.tar.gz ec2-user@"$instance":~/ >/dev/null
    ssh -i "${KEY_NAME:-mykey}".pem ec2-user@"$instance" 'tar -xzf build.tar.gz && \
      rm build.tar.gz' >/dev/null
    log_green "Uploaded build.tar.gz to instance $instance"
  done
  log_green "Website uploaded to instances"
  log_separetor
}

run_website() {
  echo "Running website..."
  urls=()
  for instance in $INSTANCES_DNS; do
    ssh -i "${KEY_NAME:-mykey}".pem ec2-user@"$instance" 'serve -s build -l 3000 </dev/null >/dev/null 2>&1 &'
    urls+="Running website on instance http://$instance:3000\n"
  done
  log_green $urls
  log_separetor
}

main() {
  get_vpc_id
  get_subnet_id
  get_ami_id
  create_keypair
  create_configure_security_group
  create_instances
  get_instance_dns
  update_instances
  build_website
  upload_website
  run_website
}

while getopts "hk:s:d:" opt; do
  case $opt in
  h)
    usage
    exit
    ;;
  k)
    KEY_NAME="$OPTARG"
    ;;
  s)
    SECURITY_GROUP="$OPTARG"
    ;;
  d)
    DRY_RUN="$OPTARG"
    ;;
  \?)
    echo "Invalid option -$OPTARG" >&2
    usage
    exit 1
    ;;
  esac
done

log_separetor
main
