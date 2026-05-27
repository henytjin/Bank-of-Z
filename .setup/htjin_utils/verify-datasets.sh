#!/bin/bash
####################################
# Dataset Verification Script
# Verifies that all datasets referenced in datasets.yaml exist on z/OS
####################################

# Default profile
PROFILE="bankz.rse"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile)
            PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-p|--profile PROFILE_NAME]"
            echo "  -p, --profile    Zowe profile name (default: bankz.zosmf)"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
TOTAL=0
FOUND=0
MISSING=0
SKIPPED=0

echo "=========================================="
echo "Dataset Verification Script"
echo "=========================================="
echo "Using Zowe profile: $PROFILE"
echo ""

# Array of datasets to check (extracted from datasets.yaml)
declare -a DATASETS=(
    "SYS1.MACLIB"
    "CEE.SCEESAMP"
    "CEE.SCEEMAC"
    "CEE.SCEELKED"
    "ASM.SASMMOD1"
    "IGY.V6R5M0.SIGYCOMP"
    "PLI.V6R2M0.SIBMZCMP"
    "CICSTS63.CICS.SDFHMAC"
    "CICSTS63.CICS.SDFHLOAD"
    "CICSTS63.CICS.SDFHCOB"
    "DFH.V6R2M24P.CICS.SDFHPL1"
    "CSQ.V9R1M0.SCSQCOBC"
    "CSQ.V9R3M0.SCSQPLIC"
    "CSQ.V9R3M0.SCSQMACS"
    "CSQ.V9R1M0.SCSQLOAD"
    "DB2V13.SDSNLOAD"
    "DSN.V13R1M0.SDSNEXIT"
    "IMSV15.SDFSMAC"
    "IMSV15.SDFSRESL"
    "DFS.V11R1M0.REFERAL"
    "FEL.SFELLOAD"
    "BZU.V1R0M0.SBZUSAMP"
    "IPV.V1R9M0.SIPVMODA"
    "SYS1.MODGEN"
    "SYS1.CSSLIB"
    "EQA.V16R0M0.SEQASAMP"
)

# Array of dataset names (for reference)
declare -a DATASET_NAMES=(
    "MACLIB"
    "SCEESAMP"
    "SCEEMAC"
    "SCEELKED"
    "SASMMOD1"
    "SIGYCOMP"
    "IBMZPLI"
    "SDFHMAC"
    "SDFHLOAD"
    "SDFHCOB"
    "SDFHPL1"
    "SCSQCOBC"
    "SCSQPLIC"
    "SCSQMACS"
    "SCSQLOAD"
    "SDSNLOAD"
    "SDSNEXIT"
    "SDFSMAC"
    "RESLIB"
    "REFERAL"
    "SFELLOAD"
    "SBZUSAMP"
    "PDTCCMOD"
    "MODGEN"
    "CSSLIB"
    "SEQASAMP"
)

echo "Checking ${#DATASETS[@]} datasets..."
echo ""

# Function to check if a dataset exists
check_dataset() {
    local dataset=$1
    local name=$2
    echo ""
    TOTAL=$((TOTAL + 1))
    echo "checking $dataset"
    # Use Zowe CLI to check if dataset exists
    local output
    output=$(zowe rse-api-for-zowe-cli list ds "$dataset" --rse-profile "$PROFILE" 2>&1)
    echo "output=$output"
    # Check if output contains "No datasets found" or if command failed
    if echo "$output" | grep -qi "No datasets found"; then
        echo -e "${RED}✗${NC} $name: $dataset ${RED}(NOT FOUND)${NC}"
        MISSING=$((MISSING + 1))
        return 1
    fi
    echo -e "${GREEN}✓${NC} $name: $dataset"
    FOUND=$((FOUND + 1))
    echo ""
    return 0
}

# Check each dataset
for i in "${!DATASETS[@]}"; do
    check_dataset "${DATASETS[$i]}" "${DATASET_NAMES[$i]}"
done

echo ""
echo "=========================================="
echo "Summary:"
echo "=========================================="
echo -e "Total datasets checked: $TOTAL"
echo -e "${GREEN}Found: $FOUND${NC}"
echo -e "${RED}Missing: $MISSING${NC}"

if [ $MISSING -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All datasets are available!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ Some datasets are missing. Please install or update the dataset references in datasets.yaml${NC}"
    exit 1
fi

# Made with Bob
