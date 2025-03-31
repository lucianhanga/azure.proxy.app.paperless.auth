#!/bin/bash

set -euo pipefail

# Colors
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Load config
CONFIG_FILE="../config.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}[ERROR] Configuration file $CONFIG_FILE not found!${NC}"
  exit 1
fi

# Parse JSON config
subfix=$(jq -r '.subfix' "$CONFIG_FILE")
projectname=$(jq -r '.projectname' "$CONFIG_FILE")
region=$(jq -r '.region' "$CONFIG_FILE")

# Define variables
resource_group="${projectname}-rg"
sp_name="${projectname}-sp"
storage_account_name="terraformstate${subfix}"
container_name="tfstate"
tfvars_path="../terraform/terraform.tfvars"

# Flags
dry_run=false
provision=false
destroy=false
yes=false

# Functions
log_info() {
  echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
  echo -e "${RED}[ERROR] $1${NC}"
}

show_usage() {
  echo ""
  echo "Usage: $0 [--provision | --destroy | --dry-run | --yes | --help | --usage]"
  echo "  --provision   Creates resources (if not already existing)"
  echo "  --destroy     Destroys created resources in reverse order"
  echo "  --dry-run     Shows the actions without executing them"
  echo "  --yes         Skip confirmation prompt (for automation)"
  echo "  --help        Displays detailed help information"
  echo "  --usage       Displays brief usage info"
  echo ""
}

show_help() {
  echo ""
  echo "This script provisions or destroys Azure infrastructure for a Terraform project."
  echo ""
  show_usage
  echo "Examples:"
  echo "  $0 --provision           Create infrastructure with checks"
  echo "  $0 --provision --yes     Provision without prompting"
  echo "  $0 --dry-run             Simulate provisioning steps"
  echo "  $0 --destroy             Tear down all created resources"
  echo ""
}

run_or_log() {
  if $dry_run; then
    echo -e "${YELLOW}[DRY-RUN] $1${NC}"
  else
    eval "$1"
  fi
}

# Parse CLI arguments
if [ $# -eq 0 ]; then
  show_usage
  exit 0
fi

for arg in "$@"; do
  case $arg in
    --dry-run)
      dry_run=true
      ;;
    --provision)
      provision=true
      ;;
    --destroy)
      destroy=true
      ;;
    --yes)
      yes=true
      ;;
    --help)
      show_help
      exit 0
      ;;
    --usage)
      show_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $arg"
      show_usage
      exit 1
      ;;
  esac
done

# Default to provision when dry-run is used alone
if $dry_run && ! $provision && ! $destroy; then
  log_info "Dry-run mode enabled. Defaulting to provision simulation."
  provision=true
fi

# Safety prompt
if ! $dry_run && ! $yes; then
  echo -e "${YELLOW}"
  echo "⚠️  You are about to perform real changes to your Azure environment."
  echo "💡 It is highly recommended to run this script first with '--dry-run'."
  echo -e "${NC}"
  read -p "❓ Are you sure you want to continue? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 1
  fi
fi

# Destroy mode
if $destroy; then
  log_info "Destroying resources..."

  log_info "Deleting blob container $container_name..."
  if az storage container show --name "$container_name" --account-name "$storage_account_name" --account-key "$(az storage account keys list --resource-group $resource_group --account-name $storage_account_name --query '[0].value' -o tsv)" &>/dev/null; then
    run_or_log "az storage container delete --name $container_name --account-name $storage_account_name --account-key \$(az storage account keys list --resource-group $resource_group --account-name $storage_account_name --query '[0].value' -o tsv)"
  else
    log_warn "Blob container $container_name not found or already deleted."
  fi

  log_info "Deleting storage account $storage_account_name..."
  if az storage account show --name "$storage_account_name" --resource-group "$resource_group" &>/dev/null; then
    run_or_log "az storage account delete --name $storage_account_name --resource-group $resource_group --yes"
  else
    log_warn "Storage account $storage_account_name not found or already deleted."
  fi

  sp_object_id=$(az ad sp list --display-name "$sp_name" --query "[0].id" -o tsv 2>/dev/null || true)
  if [ -n "$sp_object_id" ]; then
    log_info "Deleting service principal $sp_name..."
    run_or_log "az ad sp delete --id \"$sp_object_id\""
  else
    log_warn "Service principal $sp_name not found or already deleted."
  fi

  log_info "Deleting resource group $resource_group..."
  if az group show --name "$resource_group" &>/dev/null; then
    run_or_log "az group delete --name $resource_group --yes --no-wait"
  else
    log_warn "Resource group $resource_group not found or already deleted."
  fi

  # Delete tfvars file
  if [ -f "$tfvars_path" ]; then
    if $dry_run; then
      echo -e "${YELLOW}[DRY-RUN] Would remove $tfvars_path${NC}"
    else
      log_info "Removing $tfvars_path..."
      rm -f "$tfvars_path"
    fi
  else
    log_info "No tfvars file found to delete."
  fi

  log_info "Destroy complete."
  exit 0
fi

# Provision mode
if $provision; then
  log_info "Provisioning resources..."

  if az group show --name "$resource_group" &>/dev/null; then
    log_info "Resource group $resource_group already exists."
  else
    log_info "Creating resource group $resource_group in $region..."
    run_or_log "az group create --name \"$resource_group\" --location \"$region\""
  fi

  if az ad sp list --display-name "$sp_name" --query "[].appId" -o tsv | grep -q .; then
    log_info "Service principal $sp_name already exists."
    client_id=$(az ad sp list --display-name "$sp_name" --query "[0].appId" -o tsv)
    tenant_id=$(az account show --query tenantId -o tsv)

    if [ ! -f "$tfvars_path" ]; then
      if $dry_run; then
        echo -e "${YELLOW}[DRY-RUN] Would reset credentials for existing service principal $sp_name${NC}"
        client_secret="<NEW-DRY-RUN-SECRET>"
      else
        log_info "Generating new client secret for $sp_name..."
        secret_output=$(az ad sp credential reset --name "$client_id")
        client_secret=$(echo "$secret_output" | jq -r '.password')
      fi
    else
      client_secret="<REDACTED>"
    fi
  else
    log_info "Creating service principal $sp_name..."
    if $dry_run; then
      echo -e "${YELLOW}[DRY-RUN] Would create service principal $sp_name${NC}"
      client_id="<DRY-RUN>"
      client_secret="<DRY-RUN>"
      tenant_id="<DRY-RUN>"
    else
      sp_output=$(az ad sp create-for-rbac --name "$sp_name" --role Contributor --scopes "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group" --sdk-auth)
      client_id=$(echo "$sp_output" | jq -r '.clientId')
      client_secret=$(echo "$sp_output" | jq -r '.clientSecret')
      tenant_id=$(echo "$sp_output" | jq -r '.tenantId')
    fi
  fi

  subscription_id=$(az account show --query id -o tsv)

  if az storage account show --name "$storage_account_name" &>/dev/null; then
    log_info "Storage account $storage_account_name already exists."
  else
    log_info "Creating storage account $storage_account_name..."
    run_or_log "az storage account create --name \"$storage_account_name\" --resource-group \"$resource_group\" --location \"$region\" --sku Standard_LRS --encryption-services blob"
  fi

  storage_key=$(az storage account keys list --resource-group "$resource_group" --account-name "$storage_account_name" --query "[0].value" -o tsv)
  if az storage container show --name "$container_name" --account-name "$storage_account_name" --account-key "$storage_key" &>/dev/null; then
    log_info "Blob container $container_name already exists."
  else
    log_info "Creating blob container $container_name..."
    run_or_log "az storage container create --name \"$container_name\" --account-name \"$storage_account_name\" --account-key \"$storage_key\""
  fi

  log_info "Writing terraform.tfvars to $tfvars_path..."
  mkdir -p "$(dirname "$tfvars_path")"
  if $dry_run; then
    echo -e "${YELLOW}[DRY-RUN] Would write terraform.tfvars with:"
    echo "  resource_group_name = $resource_group"
    echo "  subfix = $subfix"
    echo "  storage_container_name = $container_name"
    echo "  client_id = $client_id"
    echo "  subscription_id = $subscription_id${NC}"
  else
    cat > "$tfvars_path" <<EOF
resource_group_name      = "${resource_group}"
resource_group_location  = "${region}"
project_name             = "${projectname}"
subfix                   = "${subfix}"
storage_container_name   = "${container_name}"

client_id       = "${client_id}"
client_secret   = "${client_secret}"
tenant_id       = "${tenant_id}"
subscription_id = "${subscription_id}"
EOF
    log_info "terraform.tfvars created successfully."
  fi

  log_info "Provision complete."
fi
