#!/usr/bin/env zsh
set -Eeuo pipefail

############################################
# Prompt Chain - Multi-step LLM pipeline runner
#
# Features:
#   - Chain multiple prompt-engine calls
#   - Variable capture and substitution between steps
#   - JSON format enforcement for reliable parsing
#   - Failsafe validation between steps
#   - Directory/batch processing
#   - Video frame extraction integration
############################################

VERSION="1.0.0"

############################################
# Configuration
############################################

SCRIPT_DIR="${0:A:h}"
PROMPT_ENGINE="${SCRIPT_DIR}/prompt-engine.sh"
PROMPT_ROOT="${PROMPT_ENGINE_ROOT:-${HOME}/.prompt-engine}"
CHAIN_DIR="${PROMPT_ROOT}/chains"
CHAIN_RUNS_DIR="${PROMPT_ROOT}/chain-runs"

# Default settings
DEFAULT_MODEL="${PROMPT_ENGINE_MODEL:-qwen3:14b}"
DEFAULT_TARGET="${PROMPT_ENGINE_TARGET:-local}"

# Runtime state
QUIET=false
VERBOSE=false
DRY_RUN=false
CONTINUE_ON_ERROR=false
PARALLEL=false
MAX_PARALLEL=4

# Chain execution state - stored in temp directory per run
RUN_ID=""
RUN_DIR=""
STEP_RESULTS=()

############################################
# Utilities
############################################

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

info() {
  $QUIET || echo "$*" >&2
}

debug() {
  $VERBOSE && echo "debug: $*" >&2 || true
}

# Check if command exists
has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Prompt Chain - Multi-step LLM pipeline runner

Usage:
  prompt-chain <chain-file> [options] [-- chain-args...]
  prompt-chain --list
  prompt-chain --init <name>

Chain Execution:
  prompt-chain search-relevance.chain --input document.txt --param QUERY="machine learning"
  prompt-chain video-describe.chain --input video.mp4
  prompt-chain code-analyze.chain --dir ./src --glob "*.js"

Options:
  -i, --input PATH        Input file(s) for the chain (repeatable)
  -d, --dir PATH          Process all files in directory
  -g, --glob PATTERN      Filter directory files (default: *)
  -p, --param KEY=VALUE   Set chain parameter (repeatable)
  -o, --output PATH       Output file (default: stdout)
  -m, --model MODEL       Override default model for all steps
  -r, --target TARGET     Override default target for all steps
  --continue-on-error     Continue chain if a step fails
  --parallel              Run independent steps in parallel
  --max-parallel N        Max parallel executions (default: 4)
  -n, --dry-run           Show what would be executed
  -v, --verbose           Verbose output
  -q, --quiet             Suppress informational output
  -j, --json              Output final result as JSON
  -h, --help              Show this help

Chain Management:
  --list                  List available chains
  --init NAME             Create a new chain template
  --validate FILE         Validate chain file syntax

Environment Variables:
  PROMPT_ENGINE_ROOT      Base directory (default: ~/.prompt-engine)
  PROMPT_ENGINE_MODEL     Default model
  PROMPT_ENGINE_TARGET    Default target

Chain File Format:
  Chains are YAML files defining a sequence of steps. See examples in:
  ${CHAIN_DIR}/

Examples:
  # Run a search relevance chain
  prompt-chain relevance.chain -i document.txt -p QUERY="AI safety"

  # Analyze all JS files in a directory
  prompt-chain code-analyze.chain -d ./src -g "*.js" -p QUESTION="Where is auth handled?"

  # Describe a video frame by frame
  prompt-chain video-describe.chain -i video.mp4 --verbose
EOF
}

############################################
# Directory Initialization
############################################

init_directories() {
  mkdir -p "$CHAIN_DIR" "$CHAIN_RUNS_DIR"

  # Copy chains from repo if user directory is empty
  local chain_count
  chain_count=$(find "$CHAIN_DIR" -name '*.chain' 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$chain_count" -eq 0 ]]; then
    # Look for chains in the script's directory
    local repo_chains="${SCRIPT_DIR}/chains"

    if [[ -d "$repo_chains" ]] && [[ -n "$(ls -A "$repo_chains"/*.chain 2>/dev/null)" ]]; then
      info "First run: copying chains to $CHAIN_DIR"
      cp "$repo_chains"/*.chain "$CHAIN_DIR/"
      info "Copied $(ls "$CHAIN_DIR"/*.chain 2>/dev/null | wc -l | tr -d ' ') chains"
    fi
  fi
}

############################################
# Chain Parsing
############################################

# Parse YAML-like chain file into shell variables
# Format:
# name: chain-name
# description: What this chain does
# params:
#   - name: PARAM_NAME
#     required: true
#     default: "value"
# steps:
#   - name: step-name
#     template: template-name
#     model: model-name (optional)
#     format: json-schema (optional)
#     input: ${PREV} or ${INPUT} or literal
#     output: VAR_NAME
#     validate: jq-expression (optional)
#   - name: next-step
#     ...

parse_chain_file() {
  local chain_file="$1"

  [[ -f "$chain_file" ]] || die "Chain file not found: $chain_file"

  # Use a simple line-by-line parser for the YAML subset we support
  # This avoids requiring yq/python for basic chains

  local current_section=""
  local current_step=""
  local step_index=0
  local param_index=0

  # Initialize arrays
  typeset -gA CHAIN_META
  typeset -ga CHAIN_PARAMS
  typeset -ga CHAIN_STEPS

  CHAIN_META=()
  CHAIN_PARAMS=()
  CHAIN_STEPS=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Detect section changes
    if [[ "$line" =~ ^params:[[:space:]]*$ ]]; then
      current_section="params"
      continue
    elif [[ "$line" =~ ^steps:[[:space:]]*$ ]]; then
      current_section="steps"
      continue
    elif [[ "$line" =~ ^[a-z_]+:[[:space:]]*.+ ]]; then
      # Top-level key: value
      local key="${line%%:*}"
      local value="${line#*: }"
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      CHAIN_META[$key]="$value"
      continue
    fi

    # Parse based on current section
    case "$current_section" in
      params)
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+)$ ]]; then
          current_step="param_$param_index"
          CHAIN_PARAMS+=("name=${match[1]}")
          param_index=$((param_index + 1))
        elif [[ "$line" =~ ^[[:space:]]+(required|default|description):[[:space:]]*(.+)$ ]]; then
          local key="${match[1]}"
          local val="${match[2]}"
          val="${val#\"}"
          val="${val%\"}"
          CHAIN_PARAMS[-1]+=" $key=$val"
        fi
        ;;
      steps)
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+)$ ]]; then
          current_step="step_$step_index"
          CHAIN_STEPS+=("name=${match[1]}")
          step_index=$((step_index + 1))
        elif [[ "$line" =~ ^[[:space:]]+(template|model|format|input|output|validate|image|condition|foreach|target|accumulate|final):[[:space:]]*(.*)$ ]]; then
          local key="${match[1]}"
          local val="${match[2]}"
          # Strip quotes
          val="${val#\"}"
          val="${val%\"}"
          val="${val#\'}"
          val="${val%\'}"
          # Append to current step
          CHAIN_STEPS[-1]+="|$key=$val"
        fi
        ;;
    esac
  done < "$chain_file"

  debug "Parsed chain: ${CHAIN_META[name]:-unnamed}"
  debug "Steps: ${#CHAIN_STEPS[@]}"
}

# Extract field from step definition string
get_step_field() {
  local step_def="$1"
  local field="$2"

  # Step format: "name=foo|template=bar|input=baz|..."
  local result=""
  local IFS='|'
  for part in ${=step_def}; do
    if [[ "$part" == "$field="* ]]; then
      result="${part#*=}"
      break
    fi
  done
  echo "$result"
}

############################################
# Variable Substitution
############################################

# Substitute variables in a string
# Supports: ${VARNAME}, ${step.output}, ${INPUT}, ${PREV}, ${INDEX}
substitute_vars() {
  local text="$1"
  local result="$text"

  # Substitute built-in variables
  result="${result//\$\{INPUT\}/${CHAIN_INPUT:-}}"
  result="${result//\$\{INPUT_FILE\}/${CHAIN_INPUT_FILE:-}}"
  result="${result//\$\{INPUT_FILENAME\}/${CHAIN_INPUT_FILENAME:-}}"
  result="${result//\$\{INDEX\}/${CHAIN_INDEX:-0}}"
  result="${result//\$\{PREV\}/${CHAIN_PREV:-}}"
  result="${result//\$\{RUN_DIR\}/${RUN_DIR:-}}"

  # Substitute user-defined parameters
  for key val in "${(@kv)CHAIN_VARS}"; do
    result="${result//\$\{$key\}/$val}"
  done

  # Substitute step outputs (format: ${step_name.field} or ${step_name})
  for key val in "${(@kv)STEP_OUTPUTS}"; do
    result="${result//\$\{$key\}/$val}"
  done

  echo "$result"
}

# Store step output for later use
store_output() {
  local step_name="$1"
  local output_var="$2"
  local value="$3"

  STEP_OUTPUTS[$output_var]="$value"
  STEP_OUTPUTS["${step_name}"]="$value"

  # Also write to run directory for persistence
  if [[ -n "$RUN_DIR" ]]; then
    echo "$value" > "${RUN_DIR}/${output_var}.txt"
  fi

  debug "Stored output: $output_var (${#value} chars)"
}

# Accumulate output across multiple files (for batch processing)
accumulate_output() {
  local output_var="$1"
  local value="$2"
  local filename="${3:-unknown}"

  # Append to accumulator file
  if [[ -n "$RUN_DIR" ]]; then
    local accum_file="${RUN_DIR}/${output_var}_accumulated.jsonl"
    # Write as JSON line with metadata
    if has_cmd jq; then
      jq -n --arg file "$filename" --arg index "$CHAIN_INDEX" --arg value "$value" \
        '{file: $file, index: ($index | tonumber), value: $value}' >> "$accum_file"
    else
      echo "{\"file\":\"$filename\",\"index\":$CHAIN_INDEX,\"value\":$(printf '%s' "$value" | jq -Rs .)}" >> "$accum_file"
    fi

    # Also maintain the combined values in STEP_OUTPUTS
    local existing="${STEP_OUTPUTS[${output_var}_all]:-}"
    if [[ -n "$existing" ]]; then
      STEP_OUTPUTS[${output_var}_all]="${existing}
---
[$filename]
$value"
    else
      STEP_OUTPUTS[${output_var}_all]="[$filename]
$value"
    fi
  fi

  debug "Accumulated output: $output_var for $filename"
}

############################################
# Step Execution
############################################

# Execute a single step
execute_step() {
  local step_index="$1"
  local step_def="$2"

  local step_name=$(get_step_field "$step_def" "name")
  local template=$(get_step_field "$step_def" "template")
  local model=$(get_step_field "$step_def" "model")
  local format=$(get_step_field "$step_def" "format")
  local input=$(get_step_field "$step_def" "input")
  local output=$(get_step_field "$step_def" "output")
  local validate=$(get_step_field "$step_def" "validate")
  local image=$(get_step_field "$step_def" "image")
  local condition=$(get_step_field "$step_def" "condition")
  local target=$(get_step_field "$step_def" "target")
  local accumulate=$(get_step_field "$step_def" "accumulate")

  info "Step $((step_index + 1)): $step_name"

  # Check condition if specified
  if [[ -n "$condition" ]]; then
    local cond_result
    cond_result=$(substitute_vars "$condition")
    # Evaluate condition (simple check for non-empty or specific values)
    if [[ -z "$cond_result" || "$cond_result" == "false" || "$cond_result" == "0" ]]; then
      info "  Skipped (condition not met)"
      return 0
    fi
  fi

  # Substitute variables in input
  local resolved_input=""
  if [[ -n "$input" ]]; then
    resolved_input=$(substitute_vars "$input")
  fi

  # Substitute variables in image path if specified
  local resolved_image=""
  if [[ -n "$image" ]]; then
    resolved_image=$(substitute_vars "$image")
  fi

  # Build prompt-engine command
  local cmd=("$PROMPT_ENGINE" "-q")

  # Add template
  if [[ -n "$template" ]]; then
    cmd+=("-t" "$template")
  fi

  # Add model (step override > chain override > default)
  local use_model="${model:-${CHAIN_MODEL:-$DEFAULT_MODEL}}"
  cmd+=("-m" "$use_model")

  # Add target
  local use_target="${target:-${CHAIN_TARGET:-$DEFAULT_TARGET}}"
  cmd+=("-r" "$use_target")

  # Add format schema if specified
  if [[ -n "$format" ]]; then
    # Check if format is a file path or inline JSON
    local resolved_format=$(substitute_vars "$format")
    if [[ -f "$resolved_format" ]]; then
      cmd+=("--format" "$resolved_format")
    else
      cmd+=("--format" "$resolved_format")
    fi
  fi

  # Add image if specified
  if [[ -n "$resolved_image" && -f "$resolved_image" ]]; then
    cmd+=("--image" "$resolved_image")
  fi

  # Add the input as the prompt
  if [[ -n "$resolved_input" ]]; then
    cmd+=("$resolved_input")
  fi

  debug "Command: ${cmd[*]}"

  # Execute
  local result=""
  local exit_code=0

  if $DRY_RUN; then
    echo "  [DRY RUN] Would execute: ${cmd[*]}"
    result="<dry-run-output>"
  else
    result=$("${cmd[@]}" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
      warn "Step '$step_name' failed with exit code $exit_code"
      warn "Output: $result"
      if ! $CONTINUE_ON_ERROR; then
        die "Chain aborted"
      fi
      return $exit_code
    fi
  fi

  # Validate output if validation expression provided
  if [[ -n "$validate" && -n "$result" ]]; then
    if has_cmd jq; then
      local valid
      valid=$(echo "$result" | jq -e "$validate" 2>/dev/null) || {
        warn "Step '$step_name' output failed validation: $validate"
        if ! $CONTINUE_ON_ERROR; then
          die "Validation failed"
        fi
        return 1
      }
      debug "Validation passed: $validate"
    fi
  fi

  # Store output
  local output_var="${output:-${step_name}_output}"
  store_output "$step_name" "$output_var" "$result"

  # Also accumulate if flag is set (for batch/directory processing)
  if [[ "$accumulate" == "true" ]]; then
    accumulate_output "$output_var" "$result" "${CHAIN_INPUT_FILENAME:-unknown}"
  fi

  # Update PREV for next step
  CHAIN_PREV="$result"

  # Log step result
  if [[ -n "$RUN_DIR" ]]; then
    {
      echo "=== Step: $step_name ==="
      echo "Template: $template"
      echo "Model: $use_model"
      echo "Input: $resolved_input"
      echo "Output:"
      echo "$result"
      echo
    } >> "${RUN_DIR}/chain.log"
  fi

  $VERBOSE && echo "  Output: ${result:0:100}..."

  return 0
}

############################################
# Chain Execution
############################################

# Execute a chain with given inputs
run_chain() {
  local chain_file="$1"
  shift

  # Parse the chain file
  parse_chain_file "$chain_file"

  local chain_name="${CHAIN_META[name]:-$(basename "$chain_file" .chain)}"

  info "Running chain: $chain_name"
  info "Description: ${CHAIN_META[description]:-No description}"

  # Initialize run directory
  RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
  RUN_DIR="${CHAIN_RUNS_DIR}/${chain_name}_${RUN_ID}"
  mkdir -p "$RUN_DIR"

  debug "Run directory: $RUN_DIR"

  # Initialize variables
  typeset -gA CHAIN_VARS
  typeset -gA STEP_OUTPUTS
  CHAIN_VARS=()
  STEP_OUTPUTS=()
  CHAIN_PREV=""

  # Set user-provided parameters
  for param in "${CHAIN_USER_PARAMS[@]}"; do
    local key="${param%%=*}"
    local val="${param#*=}"
    CHAIN_VARS[$key]="$val"
    debug "Set param: $key=$val"
  done

  # Check required parameters
  for param_def in "${CHAIN_PARAMS[@]}"; do
    local param_name=""
    local required="false"
    local default=""

    # Parse param definition
    for part in ${(s: :)param_def}; do
      case "$part" in
        name=*) param_name="${part#name=}" ;;
        required=*) required="${part#required=}" ;;
        default=*) default="${part#default=}" ;;
      esac
    done

    # Check if parameter is set
    if [[ -z "${CHAIN_VARS[$param_name]:-}" ]]; then
      if [[ -n "$default" ]]; then
        CHAIN_VARS[$param_name]="$default"
        debug "Using default for $param_name: $default"
      elif [[ "$required" == "true" ]]; then
        die "Required parameter not set: $param_name"
      fi
    fi
  done

  # Process inputs
  if [[ ${#CHAIN_INPUTS[@]} -eq 0 && -z "$CHAIN_DIR_INPUT" ]]; then
    # No explicit inputs - run chain once with empty input
    CHAIN_INPUT=""
    CHAIN_INPUT_FILE=""
    CHAIN_INPUT_FILENAME=""
    CHAIN_INDEX=0
    run_chain_steps
  elif [[ -n "$CHAIN_DIR_INPUT" ]]; then
    # Directory input - process each matching file
    local index=0
    local files=()

    # Find files matching glob pattern
    local glob_pattern="${CHAIN_GLOB:-*}"
    while IFS= read -r -d '' file; do
      files+=("$file")
    done < <(find "$CHAIN_DIR_INPUT" -maxdepth 1 -type f -name "$glob_pattern" -print0 2>/dev/null | sort -z)

    info "Processing ${#files[@]} files from $CHAIN_DIR_INPUT"

    for file in "${files[@]}"; do
      CHAIN_INPUT_FILE="$file"
      CHAIN_INPUT_FILENAME="$(basename "$file")"
      CHAIN_INPUT="$(cat "$file" 2>/dev/null || echo "")"
      CHAIN_INDEX=$index

      info "--- File $((index + 1))/${#files[@]}: $CHAIN_INPUT_FILENAME ---"

      # Reset step outputs for each file (but keep accumulated vars if needed)
      STEP_OUTPUTS=()
      CHAIN_PREV=""

      run_chain_steps

      index=$((index + 1))
    done
  else
    # Explicit input files
    local index=0
    for input_file in "${CHAIN_INPUTS[@]}"; do
      CHAIN_INPUT_FILE="$input_file"
      CHAIN_INPUT_FILENAME="$(basename "$input_file")"

      if [[ -f "$input_file" ]]; then
        CHAIN_INPUT="$(cat "$input_file")"
      else
        CHAIN_INPUT="$input_file"  # Treat as literal text
      fi
      CHAIN_INDEX=$index

      info "--- Input $((index + 1))/${#CHAIN_INPUTS[@]}: $CHAIN_INPUT_FILENAME ---"

      # Reset step outputs for each input
      STEP_OUTPUTS=()
      CHAIN_PREV=""

      run_chain_steps

      index=$((index + 1))
    done
  fi

  # Run final synthesis step if there were multiple inputs and we have accumulated data
  if [[ ${#files[@]:-0} -gt 1 || ${#CHAIN_INPUTS[@]} -gt 1 ]]; then
    run_final_synthesis
  fi

  info "Chain completed. Run ID: $RUN_ID"
  info "Outputs saved to: $RUN_DIR"

  # Return final result
  echo "${CHAIN_PREV}"
}

# Run synthesis after all files have been processed
run_final_synthesis() {
  # Check if we have any accumulated data
  local accum_files=("${RUN_DIR}"/*_accumulated.jsonl(N))
  [[ ${#accum_files[@]} -eq 0 ]] && return 0

  info "=== Running final synthesis ==="

  # Load all accumulated data into STEP_OUTPUTS
  for accum_file in "${accum_files[@]}"; do
    local var_name="${accum_file:t:r}"  # basename without extension
    var_name="${var_name%_accumulated}"
    STEP_OUTPUTS[${var_name}_all]="$(cat "$accum_file")"
  done

  # Check if chain has final steps (steps with final: true)
  local has_final=false
  for step_def in "${CHAIN_STEPS[@]}"; do
    local is_final=$(get_step_field "$step_def" "final")
    if [[ "$is_final" == "true" ]]; then
      has_final=true
      break
    fi
  done

  if $has_final; then
    # Run only final steps
    local step_index=0
    for step_def in "${CHAIN_STEPS[@]}"; do
      local is_final=$(get_step_field "$step_def" "final")
      if [[ "$is_final" == "true" ]]; then
        # Set INPUT to all accumulated data
        CHAIN_INPUT="${STEP_OUTPUTS[FILE_REPORT_all]:-}"
        execute_step $step_index "$step_def" || true
      fi
      step_index=$((step_index + 1))
    done
  fi
}

run_chain_steps() {
  local step_index=0

  for step_def in "${CHAIN_STEPS[@]}"; do
    execute_step $step_index "$step_def" || {
      if ! $CONTINUE_ON_ERROR; then
        return 1
      fi
    }
    step_index=$((step_index + 1))
  done
}

############################################
# Chain Management
############################################

list_chains() {
  echo "Available chains:"
  echo

  local found=false

  # List chains from user directory
  if [[ -d "$CHAIN_DIR" ]]; then
    for chain_file in "$CHAIN_DIR"/*.chain(N); do
      [[ -f "$chain_file" ]] || continue
      found=true

      local name=$(basename "$chain_file" .chain)
      local desc=""

      # Extract description from file
      desc=$(grep -m1 '^description:' "$chain_file" 2>/dev/null | sed 's/^description:[[:space:]]*//' || echo "")

      if [[ -n "$desc" ]]; then
        printf "  %-24s %s\n" "$name" "$desc"
      else
        printf "  %s\n" "$name"
      fi
    done
  fi

  # Also check script directory for chains not yet copied
  local repo_chains="${SCRIPT_DIR}/chains"
  if [[ -d "$repo_chains" ]]; then
    for chain_file in "$repo_chains"/*.chain(N); do
      [[ -f "$chain_file" ]] || continue
      local name=$(basename "$chain_file" .chain)

      # Skip if already listed from user directory
      [[ -f "${CHAIN_DIR}/${name}.chain" ]] && continue
      found=true

      local desc=""
      desc=$(grep -m1 '^description:' "$chain_file" 2>/dev/null | sed 's/^description:[[:space:]]*//' || echo "")

      if [[ -n "$desc" ]]; then
        printf "  %-24s %s (repo)\n" "$name" "$desc"
      else
        printf "  %s (repo)\n" "$name"
      fi
    done
  fi

  if ! $found; then
    echo "  No chains found."
    echo
    echo "Create one with: prompt-chain --init my-chain"
  fi
}

validate_chain() {
  local chain_file="$1"

  echo "Validating: $chain_file"

  parse_chain_file "$chain_file"

  echo "Name: ${CHAIN_META[name]:-<not set>}"
  echo "Description: ${CHAIN_META[description]:-<not set>}"
  echo "Parameters: ${#CHAIN_PARAMS[@]}"
  echo "Steps: ${#CHAIN_STEPS[@]}"

  local step_num=1
  for step_def in "${CHAIN_STEPS[@]}"; do
    local step_name=$(get_step_field "$step_def" "name")
    local template=$(get_step_field "$step_def" "template")
    local output=$(get_step_field "$step_def" "output")

    echo "  Step $step_num: $step_name"
    echo "    Template: $template"
    echo "    Output var: ${output:-<auto>}"

    # Check if template exists
    local template_path="${PROMPT_ROOT}/templates/${template}.txt"
    if [[ -n "$template" && ! -f "$template_path" ]]; then
      warn "    Template not found: $template"
    fi

    step_num=$((step_num + 1))
  done

  echo
  echo "Validation complete"
}

init_chain() {
  local name="$1"
  local chain_file="${CHAIN_DIR}/${name}.chain"

  if [[ -f "$chain_file" ]]; then
    die "Chain already exists: $chain_file"
  fi

  cat > "$chain_file" << 'EOF'
# Chain definition file
name: my-chain
description: Describe what this chain does

# Parameters that can be passed to the chain
params:
  - name: QUERY
    required: true
    description: The search query or question

# Steps to execute in sequence
steps:
  - name: analyze
    template: tags
    input: ${INPUT}
    output: TAGS

  - name: summarize
    template: summarize
    input: ${INPUT}
    output: SUMMARY

  - name: combine
    template: blank
    input: |
      Tags: ${TAGS}
      Summary: ${SUMMARY}
      Query: ${QUERY}

      Based on the above analysis, provide a final assessment.
    output: RESULT
EOF

  info "Created chain template: $chain_file"
  info "Edit this file to define your chain steps."
}

############################################
# Video Frame Extraction
############################################

# Extract frames from video at intervals
extract_video_frames() {
  local video_path="$1"
  local output_dir="$2"
  local interval="${3:-10}"  # seconds between frames

  if ! has_cmd ffmpeg; then
    die "ffmpeg required for video processing"
  fi

  mkdir -p "$output_dir"

  # Get video duration
  local duration
  duration=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$video_path" 2>/dev/null) || duration=0

  duration=${duration%.*}  # truncate to integer

  info "Video duration: ${duration}s, extracting frames every ${interval}s"

  local frame_num=0
  local timestamp=0

  while [[ $timestamp -lt $duration ]]; do
    local frame_file="${output_dir}/frame_$(printf '%04d' $frame_num)_${timestamp}s.jpg"

    ffmpeg -y -ss "$timestamp" -i "$video_path" -vframes 1 -q:v 2 "$frame_file" 2>/dev/null || {
      warn "Failed to extract frame at ${timestamp}s"
    }

    if [[ -f "$frame_file" ]]; then
      debug "Extracted frame $frame_num at ${timestamp}s"
    fi

    frame_num=$((frame_num + 1))
    timestamp=$((timestamp + interval))
  done

  info "Extracted $frame_num frames to $output_dir"
}

############################################
# Argument Parsing
############################################

CHAIN_FILE=""
CHAIN_INPUTS=()
CHAIN_DIR_INPUT=""
CHAIN_GLOB="*"
CHAIN_USER_PARAMS=()
CHAIN_OUTPUT=""
CHAIN_MODEL=""
CHAIN_TARGET=""
OUTPUT_JSON=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) CHAIN_INPUTS+=("$2"); shift 2 ;;
    -d|--dir) CHAIN_DIR_INPUT="$2"; shift 2 ;;
    -g|--glob) CHAIN_GLOB="$2"; shift 2 ;;
    -p|--param) CHAIN_USER_PARAMS+=("$2"); shift 2 ;;
    -o|--output) CHAIN_OUTPUT="$2"; shift 2 ;;
    -m|--model) CHAIN_MODEL="$2"; shift 2 ;;
    -r|--target) CHAIN_TARGET="$2"; shift 2 ;;
    --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
    --parallel) PARALLEL=true; shift ;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -q|--quiet) QUIET=true; shift ;;
    -j|--json) OUTPUT_JSON=true; shift ;;
    --list) init_directories; list_chains; exit 0 ;;
    --init)
      [[ -n "$2" ]] || die "Usage: prompt-chain --init <name>"
      init_directories
      init_chain "$2"
      exit 0
      ;;
    --validate)
      [[ -n "$2" ]] || die "Usage: prompt-chain --validate <file>"
      init_directories
      validate_chain "$2"
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "prompt-chain $VERSION"; exit 0 ;;
    --)
      shift
      # Remaining args are chain args
      while [[ $# -gt 0 ]]; do
        CHAIN_USER_PARAMS+=("$1")
        shift
      done
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$CHAIN_FILE" ]]; then
        CHAIN_FILE="$1"
      else
        # Additional positional args become inputs
        CHAIN_INPUTS+=("$1")
      fi
      shift
      ;;
  esac
done

############################################
# Main
############################################

init_directories

# Handle stdin as input if available and no other inputs specified
if [[ ${#CHAIN_INPUTS[@]} -eq 0 && -z "$CHAIN_DIR_INPUT" && ! -t 0 ]]; then
  # Read stdin to temp file
  local stdin_file="${CHAIN_RUNS_DIR}/stdin_$(date +%s).txt"
  cat > "$stdin_file"
  CHAIN_INPUTS+=("$stdin_file")
fi

# Require a chain file
if [[ -z "$CHAIN_FILE" ]]; then
  usage
  exit 1
fi

# Resolve chain file path
if [[ ! -f "$CHAIN_FILE" ]]; then
  # Try looking in chains directory
  if [[ -f "${CHAIN_DIR}/${CHAIN_FILE}" ]]; then
    CHAIN_FILE="${CHAIN_DIR}/${CHAIN_FILE}"
  elif [[ -f "${CHAIN_DIR}/${CHAIN_FILE}.chain" ]]; then
    CHAIN_FILE="${CHAIN_DIR}/${CHAIN_FILE}.chain"
  else
    die "Chain file not found: $CHAIN_FILE"
  fi
fi

# Run the chain
result=$(run_chain "$CHAIN_FILE")

# Output result
if [[ -n "$CHAIN_OUTPUT" ]]; then
  echo "$result" > "$CHAIN_OUTPUT"
  info "Output written to: $CHAIN_OUTPUT"
else
  if $OUTPUT_JSON; then
    jq -n --arg result "$result" --arg run_id "$RUN_ID" \
      '{run_id: $run_id, result: $result}'
  else
    echo "$result"
  fi
fi
