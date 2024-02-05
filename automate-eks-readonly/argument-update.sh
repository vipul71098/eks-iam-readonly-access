#!/bin/bash

# Check for required number of arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <EKS_CLUSTER_NAME> <IAM_USER_NAME> <AWS_REGION>"
    exit 1
fi

# Assign command line arguments to variables
EKS_CLUSTER_NAME="$1"
IAM_USER_NAME="$2"
AWS_REGION="$3"

# Define remaining variables
KUBECONFIG_DIR="/home/$IAM_USER_NAME/.kube/"
IAM_POLICY_NAME="$IAM_USER_NAME-Eksreadonly"
POLICY_FILE="policy.json"
PASSWORD="decimal@123"

# Function to create or get IAM user
create_or_get_iam_user() {
    if ! aws iam get-user --user-name "$IAM_USER_NAME" &> /dev/null; then
        sudo adduser --disabled-password --gecos "" "$IAM_USER_NAME"
        echo "$IAM_USER_NAME:$PASSWORD" | sudo chpasswd
        IAM_USER_ARN=$(aws iam create-user --user-name "$IAM_USER_NAME" --query "User.Arn" --output text) || {
            echo "Error creating IAM User '$IAM_USER_NAME'. Exiting."
            exit 1
        }
        echo "IAM User '$IAM_USER_NAME' created successfully."
    fi
}

# Function to create or update IAM access keys
create_or_update_access_keys() {
    CURRENT_ACCESS_KEYS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" --query 'AccessKeyMetadata[*].AccessKeyId' --output text)

    [ -n "$CURRENT_ACCESS_KEYS" ] && aws iam update-access-key --user-name "$IAM_USER_NAME" --access-key-id "$CURRENT_ACCESS_KEYS" --status Inactive

    IAM_ACCESS_KEY_JSON=$(aws iam create-access-key --user-name "$IAM_USER_NAME" --query "AccessKey" --output json) || {
        echo "Error creating IAM Access Key. Exiting."
        exit 1
    }

    IAM_ACCESS_KEY=$(jq -r '.AccessKeyId' <<< "$IAM_ACCESS_KEY_JSON")
    IAM_SECRET_KEY=$(jq -r '.SecretAccessKey' <<< "$IAM_ACCESS_KEY_JSON")
}

# Install jq if not installed
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq || {
        echo "Error installing jq. Exiting."
        exit 1
    }
fi

# Step 1: Create IAM Policy
AWS_POLICY_ARN=$(aws iam create-policy --policy-name "$IAM_POLICY_NAME" --policy-document "$(jq -c '.' "$POLICY_FILE")" --query "Policy.Arn" --output text) || {
    echo "Error creating IAM Policy. Exiting."
    exit 1
}

# Step 2: Create or get IAM User
create_or_get_iam_user

# Step 3: Attach Policy to IAM User
aws iam attach-user-policy --user-name "$IAM_USER_NAME" --policy-arn "$AWS_POLICY_ARN" || {
    echo "Error attaching IAM Policy to User. Exiting."
    cleanup
    exit 1
}
echo "Policy successfully attached to IAM User."

# Step 4: Generate IAM Access Key and Secret Key
create_or_update_access_keys

# Step 5: Update EKS aws-auth configmap
eksctl create iamidentitymapping --region "$AWS_REGION" --cluster "$EKS_CLUSTER_NAME" --arn "$IAM_USER_ARN" --group readonly-role --username "$IAM_USER_NAME" || {
    echo "Error updating EKS aws-auth configmap. Exiting."
    cleanup
    exit 1
}

# Step 6: Create EKS Cluster Role Binding (ignore if already exists)
kubectl apply -f clusterRole-readonly.yml 

# Step 7: Update ClusterRoleBinding YAML
sed -i "/subjects:/,/name:/ s/name: .*/name: $IAM_USER_NAME/" clusterRoleBinding.yml
kubectl apply -f clusterRoleBinding-readonly.yml

# Step 8: Switch to IAM User and Configure AWS CLI
sudo -su "$IAM_USER_NAME" bash <<EOF
mkdir -p "/home/$IAM_USER_NAME"
chown "$IAM_USER_NAME:$IAM_USER_NAME" "/home/$IAM_USER_NAME"
mkdir -p "$KUBECONFIG_DIR"
echo "$PASSWORD" | sudo -S bash -c "echo '$IAM_USER_NAME ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$IAM_USER_NAME"
echo "$PASSWORD" | sudo -S chmod 0440 /etc/sudoers.d/$IAM_USER_NAME
echo "Defaults    !requiretty" | sudo -S tee -a /etc/sudoers.d/$IAM_USER_NAME
aws configure set aws_access_key_id "$IAM_ACCESS_KEY" --profile "$IAM_USER_NAME"
aws configure set aws_secret_access_key "$IAM_SECRET_KEY" --profile "$IAM_USER_NAME"
aws configure set default.region "$AWS_REGION" --profile "$IAM_USER_NAME"
EOF

# Step 9: Configure Kubectl
sudo -u "$IAM_USER_NAME" bash <<EOF
pip3 install --upgrade awscli
aws eks --region "$AWS_REGION" update-kubeconfig --name "$EKS_CLUSTER_NAME" --kubeconfig "${KUBECONFIG_DIR}config" --profile "$IAM_USER_NAME"
EOF

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Cleaning up resources..."
        aws iam detach-user-policy --user-name "$IAM_USER_NAME" --policy-arn "$AWS_POLICY_ARN" || true
        aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$IAM_ACCESS_KEY" || true
        aws iam delete-user --user-name "$IAM_USER_NAME" || true
        aws iam delete-policy --policy-arn "$AWS_POLICY_ARN" || true
    fi
    exit $exit_code
}


# Call cleanup function on script exit
trap cleanup EXIT
