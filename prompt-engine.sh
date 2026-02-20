#!/usr/bin/env zsh
set -Eeuo pipefail

############################################
# Prompt Engine - A CLI for Ollama LLM interactions
#
# Features:
#   - Template-based prompting
#   - Multi-target execution (local, HTTP, SSH)
#   - Session/conversation management
#   - Image/video/audio media support
#   - Extensive generation options
############################################

############################################
# Configuration
############################################

# Base directory for prompt engine data
# Override with PROMPT_ENGINE_ROOT environment variable
PROMPT_ROOT="${PROMPT_ENGINE_ROOT:-${HOME}/.prompt-engine}"

# Template configuration
DEFAULT_TEMPLATE="blank.txt"
TEMPLATE_DIR="${PROMPT_ROOT}/templates"

# Default model - override with -m flag or PROMPT_ENGINE_MODEL env var
DEFAULT_MODEL="${PROMPT_ENGINE_MODEL:-qwen3:14b}"

# Target configuration
# Format: name|type|address
# Types: local (direct ollama), http (ollama API), ssh (remote via SSH)
# Additional targets loaded from $PROMPT_ROOT/targets.conf
TARGETS=(
  "local|local|"
)
DEFAULT_TARGET="${PROMPT_ENGINE_TARGET:-local}"

# Load user targets from config file if it exists
TARGETS_FILE="${PROMPT_ROOT}/targets.conf"
if [[ -f "$TARGETS_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    TARGETS+=("$line")
  done < "$TARGETS_FILE"
fi
TARGET="$DEFAULT_TARGET"
TARGET_TYPE=""
TARGET_ADDR=""

# Session and output directories
SESSION_DIR="${PROMPT_ROOT}/sessions"
OUT_DIR="${PROMPT_ROOT}/runs"

# Known vision-capable models (for suggestions)
VISION_MODELS=(
  "llava:7b"
  "llava:13b"
  "llava:34b"
  "llava-llama3:8b"
  "llava-phi3:3.8b"
  "bakllava:7b"
  "moondream:1.8b"
  "minicpm-v:8b"
)

############################################
# Defaults (mutable via flags)
############################################

MODEL="$DEFAULT_MODEL"
TEMPLATE="$DEFAULT_TEMPLATE"
SESSION=""
STREAM=false
COPY=false
JSON=false
DRY_RUN=false
LIST_MODELS=false
LIST_TEMPLATES=false
STDIN_MODE=false
QUIET=false

SEED="${PROMPT_ENGINE_SEED:-}"

# Generation options - stored as associative array
typeset -A OPTIONS
[[ -n "$SEED" ]] && OPTIONS[seed]="$SEED"

# Stop sequences array
STOP_SEQUENCES=()

# Model info flags
SHOW_MODEL=false
VERBOSE_MODEL=false
CHECK_CAPABILITIES=false

# Media files for vision/multimodal models
MEDIA_FILES=()

# File includes
INCLUDE_FILES=()
EXCLUDES=()

# JSON schema format for structured output
# Can be "json" for basic JSON mode, or a JSON schema object
FORMAT_SCHEMA=""

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

usage() {
  cat <<EOF
Prompt Engine - CLI for Ollama LLM interactions

Usage:
  prompt-engine [options] [prompt text]
  prompt-engine --image photo.jpg "Describe this image"
  prompt-engine --image img1.jpg --image img2.jpg "Compare these images"
  echo "text" | prompt-engine --stdin -t summarize

Basic Options:
  -t, --template NAME     Template file (default: $DEFAULT_TEMPLATE)
  -m, --model NAME        Model identifier (default: $DEFAULT_MODEL)
  -s, --session NAME      Conversation/session name for multi-turn chats
  -r, --remote TARGET     Host target (default: $DEFAULT_TARGET)
  -h, --help              Show this help
  -q, --quiet             Suppress informational output

Input Options:
  --stdin                 Read prompt from stdin
  --file PATH             Include file contents in prompt (repeatable)
  --exclude PATTERN       Exclude files matching pattern (repeatable)

Media Options (for vision/multimodal models):
  --image PATH            Include image file (repeatable for multiple images)
  --video PATH            Include video file (repeatable)
  --audio PATH            Include audio file (repeatable)

Output Options:
  -j, --json              Emit structured JSON output (wrapper metadata)
  -c, --copy              Copy result to clipboard (macOS)
  -n, --dry-run           Print prompt without executing
  --format MODE|FILE      Force structured output from model:
                          "json" - basic JSON mode
                          FILE   - JSON schema file path
                          SCHEMA - inline JSON schema

Model Information:
  --models                List available models on target
  --show-model            Show detailed model info
  --verbose               Use with --show-model for full details
  --check-capabilities    Check vision/multimodal capabilities
  --templates             List available templates

Generation Options:
  --seed NUM              Seed for reproducible generation
  --num-ctx NUM           Context window size
  --temperature NUM       Creativity 0.0-2.0 (default: 0.8)
  --top-p NUM             Nucleus sampling 0.0-1.0 (default: 0.9)
  --top-k NUM             Top-k sampling (default: 40)
  --repeat-penalty NUM    Repetition penalty (default: 1.1)
  --num-predict NUM       Max tokens, -1=infinite (default: -1)
  --min-p NUM             Min probability threshold
  --stop SEQUENCE         Stop sequence (repeatable)
  --opt KEY=VALUE         Set any option directly

Environment Variables:
  PROMPT_ENGINE_ROOT      Base directory (default: ~/.prompt-engine)
  PROMPT_ENGINE_MODEL     Default model
  PROMPT_ENGINE_TARGET    Default target
  PROMPT_ENGINE_SEED      Default seed

Examples:
  # Basic usage
  prompt-engine "Explain quantum computing"

  # With template
  prompt-engine -t code-review "Review this function"

  # Image analysis
  prompt-engine -m llava:7b --image photo.jpg "What's in this image?"

  # Multiple images comparison
  prompt-engine -m llava:7b --image a.jpg --image b.jpg "Compare these"

  # Tag generation from image
  prompt-engine -m llava:7b --image photo.jpg -t image-tags

  # Pipe content
  git diff | prompt-engine --stdin -t code-review

  # Multi-turn conversation
  prompt-engine -s myproject "What files should I look at?"
  prompt-engine -s myproject "Now explain the main function"

  # Structured JSON output with schema
  prompt-engine --format '{"type":"object","properties":{"rating":{"type":"number"}}}' \
    "Rate this code quality 1-10"

  # Using a schema file
  prompt-engine --format ~/schemas/rating.json --image photo.jpg -t image-rating
EOF
}

############################################
# Directory Initialization
############################################

# Get the directory where this script lives
SCRIPT_DIR="${0:A:h}"

init_directories() {
  mkdir -p "$TEMPLATE_DIR" "$SESSION_DIR" "$OUT_DIR"

  # Check if templates need to be initialized
  local template_count
  template_count=$(find "$TEMPLATE_DIR" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$template_count" -eq 0 ]]; then
    # Look for templates in the script's directory
    local repo_templates="${SCRIPT_DIR}/templates"

    if [[ -d "$repo_templates" ]] && [[ -n "$(ls -A "$repo_templates"/*.txt 2>/dev/null)" ]]; then
      info "First run: copying templates to $TEMPLATE_DIR"
      cp "$repo_templates"/*.txt "$TEMPLATE_DIR/"
      info "Copied $(ls "$TEMPLATE_DIR"/*.txt 2>/dev/null | wc -l | tr -d ' ') templates"
    else
      # No repo templates found, create minimal blank template
      info "Creating default template in $TEMPLATE_DIR"
      echo '${PROMPT_INPUT}' > "$TEMPLATE_DIR/blank.txt"
    fi
  fi

  # Copy example targets config if user doesn't have one
  local targets_example="${SCRIPT_DIR}/targets.conf.example"
  if [[ ! -f "$TARGETS_FILE" ]] && [[ -f "$targets_example" ]]; then
    info "Tip: Copy $targets_example to $TARGETS_FILE to configure remote targets"
  fi
}

############################################
# Template Management
############################################

list_templates() {
  if [[ ! -d "$TEMPLATE_DIR" ]]; then
    die "Template directory not found: $TEMPLATE_DIR"
  fi
  echo "Available templates in $TEMPLATE_DIR:"
  echo
  find "$TEMPLATE_DIR" -name '*.txt' -type f | while read -r f; do
    local name
    name=$(basename "$f" .txt)
    local desc
    desc=$(head -1 "$f" | grep -oP '(?<=^# ).*' 2>/dev/null || echo "")
    if [[ -n "$desc" ]]; then
      printf "  %-20s %s\n" "$name" "$desc"
    else
      printf "  %s\n" "$name"
    fi
  done
}

############################################
# Model Management
############################################

list_models() {
  IFS='|' read -r TARGET_TYPE TARGET_ADDR <<< "$(resolve_target "$TARGET")"

  echo "Models on target '$TARGET':"
  echo

  if [[ "$TARGET_TYPE" == "local" ]]; then
    ollama list 2>/dev/null || die "Failed to list models. Is Ollama running?"
  elif [[ "$TARGET_TYPE" == "http" ]]; then
    local response
    response=$(curl -sS -H "Content-Type: application/json" "$TARGET_ADDR/api/tags" 2>/dev/null) || \
      die "Failed to connect to $TARGET_ADDR"
    echo "$response" | jq -r '.models[] | "\(.name)\t\(.size | . / 1073741824 | floor)GB\t\(.details.family // "unknown")"' 2>/dev/null | \
      column -t -s $'\t'
  elif [[ "$TARGET_TYPE" == "ssh" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET_ADDR" "ollama list" 2>/dev/null || \
      die "Failed to connect via SSH to $TARGET_ADDR"
  fi
}

show_model() {
  local model_name="${1:-$MODEL}"
  local verbose_flag="${2:-false}"
  IFS='|' read -r TARGET_TYPE TARGET_ADDR <<< "$(resolve_target "$TARGET")"

  if [[ "$TARGET_TYPE" == "local" ]]; then
    if [[ "$verbose_flag" == "true" ]]; then
      ollama show "$model_name" --modelfile 2>/dev/null || die "Model not found: $model_name"
    else
      ollama show "$model_name" 2>/dev/null || die "Model not found: $model_name"
    fi
  elif [[ "$TARGET_TYPE" == "http" ]]; then
    local payload
    payload=$(jq -n --arg model "$model_name" --argjson verbose "$verbose_flag" \
      '{model:$model, verbose:$verbose}')
    curl -sS -H "Content-Type: application/json" \
      -d "$payload" \
      "$TARGET_ADDR/api/show" 2>/dev/null | jq . || die "Failed to get model info"
  elif [[ "$TARGET_TYPE" == "ssh" ]]; then
    local cmd="ollama show '$model_name'"
    [[ "$verbose_flag" == "true" ]] && cmd+=" --modelfile"
    ssh -o BatchMode=yes "$TARGET_ADDR" "$cmd" 2>/dev/null || die "Failed to get model info"
  fi
}

# Check if a model has vision/multimodal capabilities
check_model_capabilities() {
  local model_name="${1:-$MODEL}"
  IFS='|' read -r TARGET_TYPE TARGET_ADDR <<< "$(resolve_target "$TARGET")"

  local model_info=""
  local has_vision=false
  local capabilities=()

  if [[ "$TARGET_TYPE" == "local" ]]; then
    model_info=$(ollama show "$model_name" 2>/dev/null || echo "")
  elif [[ "$TARGET_TYPE" == "http" ]]; then
    local payload
    payload=$(jq -n --arg model "$model_name" '{model:$model, verbose:true}')
    model_info=$(curl -sS -H "Content-Type: application/json" \
      -d "$payload" \
      "$TARGET_ADDR/api/show" 2>/dev/null || echo "")
  elif [[ "$TARGET_TYPE" == "ssh" ]]; then
    model_info=$(ssh -o BatchMode=yes "$TARGET_ADDR" "ollama show '$model_name'" 2>/dev/null || echo "")
  fi

  # Check for vision capability indicators
  if echo "$model_info" | grep -qiE "(vision|image|visual|clip|llava|bakllava|moondream|minicpm-v)" 2>/dev/null; then
    has_vision=true
    capabilities+=("vision")
  fi

  # Check model name patterns for known vision models
  case "$model_name" in
    llava*|bakllava*|moondream*|minicpm-v*|cogvlm*)
      has_vision=true
      [[ ! " ${capabilities[*]} " =~ " vision " ]] && capabilities+=("vision")
      ;;
  esac

  echo "Model: $model_name"
  echo "Vision capable: $has_vision"
  if [[ ${#capabilities[@]} -gt 0 ]]; then
    echo "Capabilities: ${capabilities[*]}"
  fi

  echo "$has_vision"
}

# Check if target has any vision-capable models
check_vision_availability() {
  IFS='|' read -r TARGET_TYPE TARGET_ADDR <<< "$(resolve_target "$TARGET")"

  local models_output=""
  local has_vision_model=false

  if [[ "$TARGET_TYPE" == "local" ]]; then
    models_output=$(ollama list 2>/dev/null || echo "")
  elif [[ "$TARGET_TYPE" == "http" ]]; then
    models_output=$(curl -sS "$TARGET_ADDR/api/tags" 2>/dev/null | jq -r '.models[].name' || echo "")
  elif [[ "$TARGET_TYPE" == "ssh" ]]; then
    models_output=$(ssh -o BatchMode=yes "$TARGET_ADDR" "ollama list" 2>/dev/null || echo "")
  fi

  # Check for known vision models
  for vm in "${VISION_MODELS[@]}"; do
    local base_name="${vm%%:*}"
    if echo "$models_output" | grep -qi "$base_name" 2>/dev/null; then
      has_vision_model=true
      break
    fi
  done

  echo "$has_vision_model"
}

# Suggest vision models for download
suggest_vision_models() {
  echo "No vision-capable models detected on this target."
  echo
  echo "Recommended vision models to install:"
  echo
  for vm in "${VISION_MODELS[@]}"; do
    printf "  ollama pull %s\n" "$vm"
  done
  echo
  echo "Popular choices:"
  echo "  - llava:7b         Good balance of speed and quality"
  echo "  - moondream:1.8b   Lightweight, fast"
  echo "  - llava:13b        Higher quality, more VRAM required"
}

############################################
# Target Resolution
############################################

resolve_target() {
  local name="$1"
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r t_name t_type t_addr <<< "$t"
    [[ "$t_name" == "$name" ]] && {
      echo "$t_type|$t_addr"
      return
    }
  done

  # If not found in TARGETS, check if it looks like a URL or SSH target
  if [[ "$name" =~ ^https?:// ]]; then
    echo "http|$name"
    return
  elif [[ "$name" =~ @ ]]; then
    echo "ssh|$name"
    return
  fi

  die "Unknown target: $name. Use a defined target name, HTTP URL, or user@host for SSH."
}

############################################
# Options Building
############################################

build_options_json() {
  local opts_json="{"
  local first=true

  for key in "${(k)OPTIONS[@]}"; do
    local val="${OPTIONS[$key]}"
    if [[ -n "$val" ]]; then
      if [[ "$first" == "true" ]]; then
        first=false
      else
        opts_json+=","
      fi
      # Check if value is numeric
      if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        opts_json+="\"$key\":$val"
      else
        opts_json+="\"$key\":\"$val\""
      fi
    fi
  done

  # Add stop sequences if any
  if [[ ${#STOP_SEQUENCES[@]} -gt 0 ]]; then
    if [[ "$first" == "false" ]]; then
      opts_json+=","
    fi
    opts_json+="\"stop\":["
    local stop_first=true
    for seq in "${STOP_SEQUENCES[@]}"; do
      if [[ "$stop_first" == "true" ]]; then
        stop_first=false
      else
        opts_json+=","
      fi
      # Escape special characters in stop sequence
      local escaped_seq
      escaped_seq=$(printf '%s' "$seq" | jq -Rs '.')
      opts_json+="$escaped_seq"
    done
    opts_json+="]"
  fi

  opts_json+="}"
  echo "$opts_json"
}

############################################
# Media Handling
############################################

# Encode file to base64
encode_media_base64() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    die "Media file not found: $file"
  fi
  base64 -i "$file" 2>/dev/null || base64 "$file" 2>/dev/null || die "Failed to encode: $file"
}

# Build images array for API request
build_images_json() {
  if [[ ${#MEDIA_FILES[@]} -eq 0 ]]; then
    echo "[]"
    return
  fi

  local images_json="["
  local first=true

  for media_file in "${MEDIA_FILES[@]}"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      images_json+=","
    fi
    local encoded
    encoded=$(encode_media_base64 "$media_file")
    images_json+="\"$encoded\""
  done

  images_json+="]"
  echo "$images_json"
}

# Validate media files exist and are supported
validate_media_files() {
  for media_file in "${MEDIA_FILES[@]}"; do
    if [[ ! -f "$media_file" ]]; then
      die "Media file not found: $media_file"
    fi

    # Check file extension for supported types
    local ext="${media_file##*.}"
    ext="${ext:l}"  # lowercase
    case "$ext" in
      jpg|jpeg|png|gif|webp|bmp)
        # Supported image formats
        ;;
      mp4|avi|mov|webm|mkv)
        warn "Video support depends on model capabilities: $media_file"
        ;;
      mp3|wav|ogg|flac|m4a)
        warn "Audio support depends on model capabilities: $media_file"
        ;;
      *)
        warn "Unknown media format, attempting anyway: $media_file"
        ;;
    esac
  done
}

############################################
# File Include Handling
############################################

build_file_context() {
  local context=""

  for file in "${INCLUDE_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
      warn "Include file not found: $file"
      continue
    fi

    context+="### File: $file"$'\n'
    context+=$(sed 's/^/| /' "$file")
    context+=$'\n\n'
  done

  echo "$context"
}

############################################
# Execution Backends
############################################

run_local() {
  local opts=""
  [[ -n "${OPTIONS[num_ctx]:-}" ]] && opts+=" --num-ctx ${OPTIONS[num_ctx]}"
  [[ -n "${OPTIONS[num_predict]:-}" ]] && opts+=" --num-predict ${OPTIONS[num_predict]}"

  if [[ ${#MEDIA_FILES[@]} -gt 0 ]]; then
    # Use ollama run with image files directly
    # Ollama supports: ollama run model "prompt" image1.jpg image2.jpg
    local media_args=""
    for mf in "${MEDIA_FILES[@]}"; do
      media_args+=" \"$mf\""
    done
    # shellcheck disable=SC2086
    eval ollama run $opts "\"$MODEL\"" "\"$FINAL_PROMPT\"" $media_args
  else
    # shellcheck disable=SC2086
    ollama run $opts "$MODEL" <<< "$FINAL_PROMPT"
  fi
}

run_http() {
  local base="$1"
  local opts_json
  opts_json=$(build_options_json)

  local images_json="[]"
  if [[ ${#MEDIA_FILES[@]} -gt 0 ]]; then
    images_json=$(build_images_json)
  fi

  local payload
  if [[ -n "$FORMAT_SCHEMA" ]]; then
    # Include format parameter for structured output
    if [[ "$FORMAT_SCHEMA" == "json" ]]; then
      # Basic JSON mode - pass as string
      payload=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$FINAL_PROMPT" \
        --argjson stream "$STREAM" \
        --argjson options "$opts_json" \
        --argjson images "$images_json" \
        --arg format "json" \
        '{model:$model, prompt:$prompt, options:$options, stream:$stream, images:$images, format:$format}')
    else
      # JSON schema - pass as object
      payload=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$FINAL_PROMPT" \
        --argjson stream "$STREAM" \
        --argjson options "$opts_json" \
        --argjson images "$images_json" \
        --argjson format "$FORMAT_SCHEMA" \
        '{model:$model, prompt:$prompt, options:$options, stream:$stream, images:$images, format:$format}')
    fi
  else
    payload=$(jq -n \
      --arg model "$MODEL" \
      --arg prompt "$FINAL_PROMPT" \
      --argjson stream "$STREAM" \
      --argjson options "$opts_json" \
      --argjson images "$images_json" \
      '{model:$model, prompt:$prompt, options:$options, stream:$stream, images:$images}')
  fi

  local response
  response=$(curl -sS -H 'Content-Type: application/json' \
    -d "$payload" \
    "$base/api/generate" 2>/dev/null) || die "Failed to connect to $base"

  # Sanitize control characters (keep tab, newline, carriage return)
  local sanitized
  sanitized=$(printf '%s' "$response" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')

  # Check for API errors
  local error_msg
  error_msg=$(printf '%s' "$sanitized" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n "$error_msg" ]]; then
    echo "error: $error_msg" >&2
    if [[ "$error_msg" == *"not found"* ]]; then
      echo >&2
      echo "Available models on $TARGET:" >&2
      curl -sS "$base/api/tags" 2>/dev/null | jq -r '.models[].name' >&2 || true
      echo >&2
      echo "Use -m MODEL to specify a model, or set PROMPT_ENGINE_MODEL" >&2
    fi
    return 1
  fi

  if [[ $STREAM == "true" ]]; then
    printf '%s' "$sanitized" | jq -r '.response' | tr -d '\n'
  else
    printf '%s' "$sanitized" | jq -r '.response'
  fi
}

run_ssh() {
  local host="$1"

  if [[ ${#MEDIA_FILES[@]} -gt 0 ]]; then
    # For SSH with images, we need to transfer the files first
    local remote_tmp="/tmp/prompt-engine-$$"
    ssh -o BatchMode=yes "$host" "mkdir -p $remote_tmp" || die "Failed to create remote temp directory"

    local remote_files=()
    for mf in "${MEDIA_FILES[@]}"; do
      local basename
      basename=$(basename "$mf")
      scp -q "$mf" "$host:$remote_tmp/$basename" || die "Failed to transfer: $mf"
      remote_files+=("$remote_tmp/$basename")
    done

    # Build the command with image files
    local media_args=""
    for rf in "${remote_files[@]}"; do
      media_args+=" '$rf'"
    done

    # Run and cleanup
    local result
    result=$(ssh -o BatchMode=yes "$host" "ollama run '$MODEL' '$FINAL_PROMPT' $media_args; rm -rf $remote_tmp")
    echo "$result"
  else
    ssh -o BatchMode=yes "$host" "ollama run '$MODEL'" <<< "$FINAL_PROMPT"
  fi
}

############################################
# Template Loading and Rendering
############################################

render_template() {
  local template="$1"

  # Build file context if any files included
  local file_context=""
  if [[ ${#INCLUDE_FILES[@]} -gt 0 ]]; then
    file_context=$(build_file_context)
  fi

  (
    export PROMPT_INPUT="$USER_INPUT"
    export PROMPT_HISTORY="$HISTORY"
    export PROMPT_DATE="$(date -I)"
    export PROMPT_MODEL="$MODEL"
    export PROMPT_FILES="$file_context"
    export PROMPT_MEDIA_COUNT="${#MEDIA_FILES[@]}"

    # Whitelisted substitution for security
    envsubst '$PROMPT_INPUT $PROMPT_HISTORY $PROMPT_DATE $PROMPT_MODEL $PROMPT_FILES $PROMPT_MEDIA_COUNT' \
      < "$template"
  )
}

############################################
# Argument Parsing
############################################

ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--template) TEMPLATE="$2"; shift 2 ;;
    -m|--model) MODEL="$2"; shift 2 ;;
    -s|--session) SESSION="$2"; shift 2 ;;
    -r|--remote|--host|--target) TARGET="$2"; shift 2 ;;
    --seed) OPTIONS[seed]="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -q|--quiet) QUIET=true; shift ;;
    --templates|--list-templates) LIST_TEMPLATES=true; shift ;;
    --models|--list-models) LIST_MODELS=true; shift ;;
    --show-model) SHOW_MODEL=true; shift ;;
    --verbose) VERBOSE_MODEL=true; shift ;;
    --check-capabilities) CHECK_CAPABILITIES=true; shift ;;
    --stdin) STDIN_MODE=true; shift ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
    --file) INCLUDE_FILES+=("$2"); shift 2 ;;
    --image|--video|--audio) MEDIA_FILES+=("$2"); shift 2 ;;
    --num-ctx) OPTIONS[num_ctx]="$2"; shift 2 ;;
    --temperature|--temp) OPTIONS[temperature]="$2"; shift 2 ;;
    --top-p) OPTIONS[top_p]="$2"; shift 2 ;;
    --top-k) OPTIONS[top_k]="$2"; shift 2 ;;
    --repeat-penalty) OPTIONS[repeat_penalty]="$2"; shift 2 ;;
    --num-predict) OPTIONS[num_predict]="$2"; shift 2 ;;
    --min-p) OPTIONS[min_p]="$2"; shift 2 ;;
    --stop) STOP_SEQUENCES+=("$2"); shift 2 ;;
    --stream) STREAM=true; shift ;;
    --opt)
      if [[ "$2" =~ ^([^=]+)=(.*)$ ]]; then
        OPTIONS["${match[1]}"]="${match[2]}"
      else
        die "Invalid --opt format. Use --opt key=value"
      fi
      shift 2
      ;;
    -j|--json) JSON=true; shift ;;
    -c|--copy) COPY=true; shift ;;
    --format)
      # Accept "json" for basic mode, a file path, or inline JSON schema
      if [[ "$2" == "json" ]]; then
        FORMAT_SCHEMA="json"
      elif [[ -f "$2" ]]; then
        # Read schema from file
        FORMAT_SCHEMA=$(cat "$2") || die "Failed to read format schema: $2"
      else
        # Assume inline JSON
        FORMAT_SCHEMA="$2"
      fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

############################################
# Initialize
############################################

init_directories

############################################
# Handle Information Queries
############################################

if $LIST_MODELS; then
  list_models
  exit 0
fi

if $LIST_TEMPLATES; then
  list_templates
  exit 0
fi

if $SHOW_MODEL; then
  show_model "$MODEL" "$VERBOSE_MODEL"
  exit 0
fi

if $CHECK_CAPABILITIES; then
  result=$(check_model_capabilities "$MODEL")
  has_vision=$(echo "$result" | tail -1)
  echo "$result" | sed '$d'

  if [[ "$has_vision" != "true" ]]; then
    echo
    has_any=$(check_vision_availability)
    if [[ "$has_any" != "true" ]]; then
      suggest_vision_models
    else
      echo "Other vision models are available on this target. Use --models to list."
    fi
  fi
  exit 0
fi

############################################
# Input Handling
############################################

if $STDIN_MODE; then
  USER_INPUT="$(cat)"
else
  USER_INPUT="${ARGS[*]:-}"
fi

# Allow empty prompt if media files are provided (for templates that work with just images)
if [[ -z "$USER_INPUT" && ${#MEDIA_FILES[@]} -eq 0 ]]; then
  die "No prompt provided. Use -h for help."
fi

############################################
# Media Validation
############################################

if [[ ${#MEDIA_FILES[@]} -gt 0 ]]; then
  validate_media_files

  # Check if model likely supports vision
  has_vision=$(check_model_capabilities "$MODEL" 2>/dev/null | tail -1)
  if [[ "$has_vision" != "true" ]]; then
    warn "Model '$MODEL' may not support vision. Consider using a vision model like llava:7b"
    has_any=$(check_vision_availability 2>/dev/null)
    if [[ "$has_any" != "true" ]]; then
      echo >&2
      suggest_vision_models >&2
    fi
  fi

  info "Processing ${#MEDIA_FILES[@]} media file(s)..."
fi

############################################
# Session Handling
############################################

SESSION_FILE=""
HISTORY=""

if [[ -n "$SESSION" ]]; then
  SESSION_FILE="${SESSION_DIR}/${SESSION}.txt"
  [[ -f "$SESSION_FILE" ]] && HISTORY="$(cat "$SESSION_FILE")"
fi

############################################
# Template Loading
############################################

# Handle template with or without .txt extension
if [[ "$TEMPLATE" != *.txt ]]; then
  TEMPLATE="${TEMPLATE}.txt"
fi

TEMPLATE_PATH="${TEMPLATE_DIR}/${TEMPLATE}"
[[ -f "$TEMPLATE_PATH" ]] || die "Template not found: $TEMPLATE_PATH"

FINAL_PROMPT="$(render_template "$TEMPLATE_PATH")"

############################################
# Dry Run
############################################

if $DRY_RUN; then
  echo "═══════════════════════════════════════════"
  echo "DRY RUN - Prompt Preview"
  echo "═══════════════════════════════════════════"
  echo "Model:    $MODEL"
  echo "Template: $TEMPLATE"
  echo "Target:   $TARGET"
  [[ -n "$SESSION" ]] && echo "Session:  $SESSION"
  [[ ${#MEDIA_FILES[@]} -gt 0 ]] && echo "Media:    ${MEDIA_FILES[*]}"
  echo "═══════════════════════════════════════════"
  echo
  echo "$FINAL_PROMPT"
  exit 0
fi

############################################
# Execution
############################################

RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
OUT_FILE="${OUT_DIR}/${RUN_ID}.txt"

IFS='|' read -r TARGET_TYPE TARGET_ADDR <<< "$(resolve_target "$TARGET")"

info "Running on $TARGET ($TARGET_TYPE)..."

case "$TARGET_TYPE" in
  local) RESULT="$(run_local)" || exit 1 ;;
  http)  RESULT="$(run_http "$TARGET_ADDR")" || exit 1 ;;
  ssh)   RESULT="$(run_ssh "$TARGET_ADDR")" || exit 1 ;;
  *) die "Unsupported target type: $TARGET_TYPE" ;;
esac

############################################
# Session Persistence
############################################

if [[ -n "$SESSION" ]]; then
  {
    echo "### USER"
    echo "$USER_INPUT"
    [[ ${#MEDIA_FILES[@]} -gt 0 ]] && echo "[Media: ${MEDIA_FILES[*]}]"
    echo
    echo "### ASSISTANT"
    echo "$RESULT"
    echo
  } >> "$SESSION_FILE"
fi

############################################
# Output
############################################

if $COPY; then
  command -v pbcopy >/dev/null && printf '%s' "$RESULT" | pbcopy && info "Copied to clipboard"
fi

if $JSON; then
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg model "$MODEL" \
    --arg template "$TEMPLATE" \
    --arg session "${SESSION:-}" \
    --arg output_file "$OUT_FILE" \
    --arg result "$RESULT" \
    --argjson media_count "${#MEDIA_FILES[@]}" \
    '{
      run_id: $run_id,
      model: $model,
      template: $template,
      session: (if $session == "" then null else $session end),
      media_files: $media_count,
      output_file: $output_file,
      result: $result
    }' | tee "$OUT_FILE"
else
  echo "$RESULT" | tee "$OUT_FILE"
fi

info "Output saved to: $OUT_FILE"
