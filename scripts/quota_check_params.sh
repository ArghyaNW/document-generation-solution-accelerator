#!/bin/bash
# Azure OpenAI Quota Checker
# Auto-detects quota for gpt-4.1 and embeddings (no hardcoding)

REGIONS=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --regions)
      REGIONS="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "Verbose: $VERBOSE"

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo "$1"
  fi
}

# 🔄 Auto-detect available models & quotas
echo "🔄 Detecting available models & max quota..."
MODEL_INFO=$(az cognitiveservices account list-models \
  --name AROpenAIAccount \
  --resource-group ArAIDocGen \
  --query "[?isDefaultVersion==\`true\` && lifecycleStatus=='GenerallyAvailable'].{Name:name, MaxCapacity:maxCapacity}" \
  --output tsv)

GPT41_CAP=$(echo "$MODEL_INFO" | awk '$1=="gpt-4.1"{print $2; exit}')
EMB_CAP=$(echo "$MODEL_INFO" | awk '$1=="text-embedding-ada-002"{print $2; exit}')

# fallback to text-embedding-3-small if ada not found
if [ -z "$EMB_CAP" ]; then
  EMB_CAP=$(echo "$MODEL_INFO" | awk '$1=="text-embedding-3-small"{print $2; exit}')
  EMB_MODEL="text-embedding-3-small"
else
  EMB_MODEL="text-embedding-ada-002"
fi

if [ -z "$GPT41_CAP" ]; then
  echo "❌ ERROR: gpt-4.1 not available in this subscription."
  exit 1
fi

MODEL_CAPACITY_PAIRS=("gpt-4.1:${GPT41_CAP}" "${EMB_MODEL}:${EMB_CAP}")
echo "✅ Using detected capacities: ${MODEL_CAPACITY_PAIRS[*]}"

# 🔄 Subscription selection
echo "Fetching subscriptions..."
SUBSCRIPTIONS=$(az account list --query "[?state=='Enabled'].{Name:name, ID:id}" --output tsv)
SUB_COUNT=$(echo "$SUBSCRIPTIONS" | wc -l)

if [ "$SUB_COUNT" -eq 0 ]; then
    echo "❌ ERROR: No active subscriptions. Run 'az login'."
    exit 1
elif [ "$SUB_COUNT" -eq 1 ]; then
    AZURE_SUBSCRIPTION_ID=$(echo "$SUBSCRIPTIONS" | awk '{print $2}')
    echo "✅ Using subscription: $AZURE_SUBSCRIPTION_ID"
else
    echo "Multiple subscriptions found:"
    echo "$SUBSCRIPTIONS" | awk '{print NR")", $1, "-", $2}'
    while true; do
        echo "Enter the number of the subscription to use:"
        read SUB_INDEX
        if [[ "$SUB_INDEX" =~ ^[0-9]+$ ]] && [ "$SUB_INDEX" -ge 1 ] && [ "$SUB_INDEX" -le "$SUB_COUNT" ]; then
            AZURE_SUBSCRIPTION_ID=$(echo "$SUBSCRIPTIONS" | awk -v idx="$SUB_INDEX" 'NR==idx {print $2}')
            echo "✅ Selected Subscription: $AZURE_SUBSCRIPTION_ID"
            break
        else
            echo "❌ Invalid selection."
        fi
    done
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
echo "🎯 Active Subscription: $(az account show --query '[name, id]' --output tsv)"

# 🔄 Regions
DEFAULT_REGIONS="francecentral,australiaeast,uksouth,eastus2,northcentralus,swedencentral,westus,westus2,southcentralus,canadacentral"
if [ -n "$REGIONS" ]; then
    IFS=',' read -r -a REGIONS <<< "$REGIONS"
else
    IFS=',' read -r -a REGIONS <<< "$DEFAULT_REGIONS"
fi

echo "Checking quotas in regions: ${REGIONS[*]}"
echo "----------------------------------------"

# Prepare model arrays
declare -a FINAL_MODEL_NAMES
declare -a FINAL_CAPACITIES
for PAIR in "${MODEL_CAPACITY_PAIRS[@]}"; do
    FINAL_MODEL_NAMES+=("$(echo "$PAIR" | cut -d':' -f1)")
    FINAL_CAPACITIES+=("$(echo "$PAIR" | cut -d':' -f2)")
done

declare -a TABLE_ROWS
INDEX=1

for REGION in "${REGIONS[@]}"; do
    log_verbose "🔍 Checking region: $REGION"
    QUOTA_INFO=$(az cognitiveservices usage list --location "$REGION" --output json | tr '[:upper:]' '[:lower:]')
    if [ -z "$QUOTA_INFO" ]; then
        log_verbose "⚠️ Failed to retrieve quota for $REGION"
        continue
    fi

    TEMP_TABLE_ROWS=()
    AT_LEAST_ONE=false

    for i in "${!FINAL_MODEL_NAMES[@]}"; do
        MODEL_NAME="${FINAL_MODEL_NAMES[$i]}"
        REQUIRED_CAPACITY="${FINAL_CAPACITIES[$i]}"
        MODEL_TYPES=("openai.standard.$MODEL_NAME" "openai.globalstandard.$MODEL_NAME")

        for MODEL_TYPE in "${MODEL_TYPES[@]}"; do
            MODEL_INFO=$(echo "$QUOTA_INFO" | awk -v model="\"value\": \"$MODEL_TYPE\"" 'BEGIN { RS="},"; FS="," } $0 ~ model { print $0 }')
            if [ -n "$MODEL_INFO" ]; then
                CURRENT=$(echo "$MODEL_INFO" | awk -F': ' '/"currentvalue"/ {print $2}' | tr -d ',' | tr -d ' ')
                LIMIT=$(echo "$MODEL_INFO" | awk -F': ' '/"limit"/ {print $2}' | tr -d ',' | tr -d ' ')
                CURRENT=${CURRENT:-0}; LIMIT=${LIMIT:-0}
                AVAILABLE=$((LIMIT - CURRENT))
                if [ "$AVAILABLE" -ge "$REQUIRED_CAPACITY" ]; then
                    AT_LEAST_ONE=true
                    TEMP_TABLE_ROWS+=("$(printf "| %-4s | %-20s | %-43s | %-10s | %-10s | %-10s |" "$INDEX" "$REGION" "$MODEL_TYPE" "$LIMIT" "$CURRENT" "$AVAILABLE")")
                fi
            fi
        done
    done

    if [ "$AT_LEAST_ONE" = true ]; then
        TABLE_ROWS+=("${TEMP_TABLE_ROWS[@]}")
        INDEX=$((INDEX + 1))
    else
        echo "🚫 $REGION has insufficient quota."
    fi
done

if [ ${#TABLE_ROWS[@]} -eq 0 ]; then
    echo "❌ No regions with enough quota. Request increase: https://aka.ms/oai/stuquotarequest"
else
    echo "---------------------------------------------------------------------------------------------------------------------"
    printf "| %-4s | %-20s | %-43s | %-10s | %-10s | %-10s |\n" "No." "Region" "Model Name" "Limit" "Used" "Available"
    echo "---------------------------------------------------------------------------------------------------------------------"
    for ROW in "${TABLE_ROWS[@]}"; do
        echo "$ROW"
    done
    echo "---------------------------------------------------------------------------------------------------------------------"
    echo "➡️  To request more quota: https://aka.ms/oai/stuquotarequest"
fi

echo "✅ Done."
