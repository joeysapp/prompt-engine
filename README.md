# Prompt Engine

A powerful CLI for interacting with local LLMs via [Ollama](https://ollama.ai). Template-based prompting with support for images, sessions, and multiple execution targets.

## Features

- **Template-based prompting** - Reusable prompt templates for common tasks
- **Image/media support** - Analyze images with vision models (llava, moondream, etc.)
- **Multi-target execution** - Run locally, via HTTP API, or SSH to remote machines
- **Session management** - Multi-turn conversations with context persistence
- **Extensive options** - Full control over generation parameters
- **Pipeline-friendly** - Read from stdin, output JSON, copy to clipboard

## Installation

### Prerequisites

- [Ollama](https://ollama.ai) installed and running
- `zsh` shell
- `jq` for JSON processing
- `curl` for HTTP targets

### Quick Start

```bash
# Clone the repository
git clone https://github.com/joeysapp/prompt-engine.git
cd prompt-engine

# Make executable
chmod +x prompt-engine.sh

# Optional: Add to PATH
ln -s $(pwd)/prompt-engine.sh /usr/local/bin/prompt-engine

# Run your first prompt
./prompt-engine.sh "Explain quantum computing in simple terms"
```

On first run, the script creates `~/.prompt-engine/` with:
- `templates/` - Prompt templates
- `sessions/` - Conversation history
- `runs/` - Output logs

## Usage

### Basic Prompts

```bash
# Simple query
prompt-engine "What is the capital of France?"

# Use a specific model
prompt-engine -m llama3.2:3b "Explain recursion"

# Use a template
prompt-engine -t summarize "Your long text here..."
```

### Image Analysis

Vision models can analyze images. Use `--image` to include image files:

```bash
# Describe an image
prompt-engine -m llava:7b --image photo.jpg "What's in this image?"

# Generate tags for an image
prompt-engine -m llava:7b --image photo.jpg -t image-tags

# Compare multiple images
prompt-engine -m llava:7b --image a.jpg --image b.jpg "Compare these images"

# Extract text from screenshot
prompt-engine -m llava:7b --image screenshot.png -t image-ocr
```

If you don't have a vision model installed, the script will suggest options:

```bash
# Check if your model supports vision
prompt-engine --check-capabilities

# Install a vision model
ollama pull llava:7b
```

### Templates

Templates are reusable prompt structures. List available templates:

```bash
prompt-engine --templates
```

**Included templates:**

| Template | Description |
|----------|-------------|
| `blank` | Pass-through, no formatting |
| `code-review` | Review code for issues and improvements |
| `explain-code` | Explain what code does step by step |
| `debug` | Diagnose and fix bugs |
| `refactor` | Improve code structure |
| `write-tests` | Generate test cases |
| `commit-message` | Generate git commit messages |
| `summarize` | Summarize long text |
| `summarize-brief` | TL;DR in 1-3 sentences |
| `classify` | Categorize content |
| `tags` | Generate keywords/tags |
| `sentiment` | Analyze sentiment |
| `extract` | Extract structured information |
| `image-describe` | Describe image contents |
| `image-tags` | Generate 5 tags for image |
| `image-compare` | Compare multiple images |
| `image-ocr` | Extract text from image |
| `image-alt-text` | Generate accessible alt text |
| `recipe` | Create or modify recipes |
| `recipe-from-image` | Create recipe from food photo |
| `coach` | Life coaching and advice |
| `project-analysis` | Analyze software projects |
| `brainstorm` | Generate ideas |
| `explain` | Explain concepts clearly |
| `rewrite` | Rewrite text for clarity |
| `translate` | Translate between languages |
| `proofread` | Check spelling and grammar |

### Pipeline Usage

```bash
# Pipe content to analyze
cat document.txt | prompt-engine --stdin -t summarize

# Review git changes
git diff | prompt-engine --stdin -t code-review

# Generate commit message
git diff --staged | prompt-engine --stdin -t commit-message

# Process and copy result
cat notes.txt | prompt-engine --stdin -t summarize -c
```

### Sessions (Multi-turn Conversations)

Sessions maintain conversation history:

```bash
# Start a conversation
prompt-engine -s myproject "I'm working on a web scraper in Python"

# Continue the conversation (context preserved)
prompt-engine -s myproject "How should I handle rate limiting?"

# Ask follow-up questions
prompt-engine -s myproject "Show me an example implementation"
```

Session files are stored in `~/.prompt-engine/sessions/`.

### Remote Execution

Run prompts on remote machines:

```bash
# Via HTTP (Ollama API)
prompt-engine -r http://server:11434 "Your prompt"

# Via SSH
prompt-engine -r user@server "Your prompt"
```

### Configuring Targets

For frequently-used targets, create `~/.prompt-engine/targets.conf`:

```bash
# Copy the example
cp targets.conf.example ~/.prompt-engine/targets.conf

# Edit with your hosts
```

Format: `name|type|address`

```
# ~/.prompt-engine/targets.conf
gpu-server|http|http://192.168.1.100:11434
workstation|ssh|user@workstation.local
cloud-gpu|ssh|ubuntu@gpu.example.com
```

Then use by name:

```bash
prompt-engine -r gpu-server "Your prompt"

# Set a default in your shell profile
export PROMPT_ENGINE_TARGET=gpu-server
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PROMPT_ENGINE_ROOT` | Base directory | `~/.prompt-engine` |
| `PROMPT_ENGINE_MODEL` | Default model | `llama3.2:3b` |
| `PROMPT_ENGINE_TARGET` | Default target | `local` |
| `PROMPT_ENGINE_SEED` | Default seed | (none) |

### Custom Templates

Create templates in `~/.prompt-engine/templates/`:

```bash
# ~/.prompt-engine/templates/my-template.txt
# My custom template
You are a helpful assistant specialized in ${PROMPT_TOPIC}.

${PROMPT_INPUT}
```

Available template variables:
- `${PROMPT_INPUT}` - User's input text
- `${PROMPT_HISTORY}` - Session history (if using -s)
- `${PROMPT_DATE}` - Current date (ISO format)
- `${PROMPT_MODEL}` - Model being used
- `${PROMPT_FILES}` - Included file contents
- `${PROMPT_MEDIA_COUNT}` - Number of media files

## Generation Options

Control model behavior with generation options:

```bash
# Adjust creativity
prompt-engine --temperature 0.7 "Write a poem"

# Limit output length
prompt-engine --num-predict 100 "Brief explanation of..."

# Reproducible output
prompt-engine --seed 42 "Your prompt"

# Multiple options
prompt-engine --temperature 0.9 --top-p 0.95 --num-ctx 4096 "..."
```

| Option | Description | Default |
|--------|-------------|---------|
| `--temperature` | Creativity (0.0-2.0) | 0.8 |
| `--top-p` | Nucleus sampling (0.0-1.0) | 0.9 |
| `--top-k` | Top-k sampling | 40 |
| `--num-ctx` | Context window size | model-specific |
| `--num-predict` | Max tokens (-1=infinite) | -1 |
| `--repeat-penalty` | Repetition penalty | 1.1 |
| `--min-p` | Min probability threshold | 0.0 |
| `--seed` | Random seed | (none) |
| `--stop` | Stop sequence (repeatable) | (none) |
| `--opt KEY=VALUE` | Any Ollama option | - |

## Output Options

```bash
# Dry run - see prompt without executing
prompt-engine -n "Your prompt"

# JSON output
prompt-engine -j "Your prompt"

# Copy to clipboard (macOS)
prompt-engine -c "Your prompt"

# Quiet mode (suppress info messages)
prompt-engine -q "Your prompt"
```

## Model Management

```bash
# List available models
prompt-engine --models

# Show model details
prompt-engine --show-model
prompt-engine --show-model -m llava:7b

# Show full model info
prompt-engine --show-model --verbose

# Check vision capabilities
prompt-engine --check-capabilities
prompt-engine --check-capabilities -m llava:7b
```

## Examples

### Code Review Workflow

```bash
# Review staged changes
git diff --staged | prompt-engine --stdin -t code-review

# Generate commit message
git diff --staged | prompt-engine --stdin -t commit-message -c
```

### Image Cataloging

```bash
# Generate tags for all images in a directory
for img in *.jpg; do
  echo "$img: $(prompt-engine -m llava:7b --image "$img" -t image-tags -q)"
done
```

### Document Processing

```bash
# Summarize a document
cat report.pdf.txt | prompt-engine --stdin -t summarize

# Extract action items
cat meeting_notes.txt | prompt-engine --stdin -t extract
```

### Recipe from Food Photo

```bash
prompt-engine -m llava:7b --image dinner.jpg -t recipe-from-image
```

## Troubleshooting

### "Model not found"

```bash
# List available models
ollama list

# Pull a model
ollama pull llama3.2:3b
```

### "Failed to connect"

Ensure Ollama is running:

```bash
# Start Ollama
ollama serve

# Check status
curl http://localhost:11434/api/tags
```

### Vision model not working

```bash
# Check if model supports vision
prompt-engine --check-capabilities -m your-model

# Install a vision model
ollama pull llava:7b
```

## Chain Mode (Multi-step Pipelines)

Prompt Engine includes a powerful chain system for running multi-step LLM pipelines. Chains allow you to:

- Run multiple sequential LLM calls
- Pass outputs between steps as variables
- Use JSON format for reliable structured output
- Process entire directories of files
- Validate outputs between steps

### Quick Start

```bash
# List available chains
./prompt-chain.sh --list

# Run a relevance search on a document
./prompt-chain.sh relevance-search.chain -i document.txt -p QUERY="machine learning"

# Analyze code files in a directory
./prompt-chain.sh code-analyze.chain -d ./src -g "*.js" -p QUESTION="Where is authentication handled?"

# Describe a video frame by frame
./prompt-chain.sh video-describe.chain -i video.mp4

# Create a new chain
./prompt-chain.sh --init my-chain
```

### Available Chains

| Chain | Description |
|-------|-------------|
| `relevance-search` | Analyze documents for relevance to a search query |
| `code-analyze` | Analyze code files and answer questions |
| `code-question` | Synthesize answers from multiple code files |
| `log-analyze` | Find errors and patterns in log files |
| `document-classify` | Classify documents into categories |
| `video-describe` | Generate video descriptions from frames |
| `image-story` | Create stories/poems from images |
| `batch-rate` | Rate and rank multiple files |

### Chain File Format

Chains are YAML-like files with steps:

```yaml
name: my-chain
description: What this chain does

params:
  - name: QUERY
    required: true
    description: The search query

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
    format: '{"type":"object","properties":{"result":{"type":"string"}}}'
    input: |
      Tags: ${TAGS}
      Summary: ${SUMMARY}
      Query: ${QUERY}
      Generate a final assessment.
    output: RESULT
```

### Chain Variables

| Variable | Description |
|----------|-------------|
| `${INPUT}` | Current input file contents |
| `${INPUT_FILE}` | Path to input file |
| `${INPUT_FILENAME}` | Input filename |
| `${PREV}` | Previous step's output |
| `${INDEX}` | Current file index (batch processing) |
| `${STEP_NAME}` | Output from a named step |

### Directory Processing

Process all files in a directory:

```bash
# Analyze all JavaScript files
./prompt-chain.sh code-analyze.chain -d ./src -g "*.js" -p QUESTION="Find security issues"

# Rate all documents for relevance
./prompt-chain.sh batch-rate.chain -d ./docs -g "*.md" -p CRITERIA="technical accuracy"

# Classify all log files
./prompt-chain.sh log-analyze.chain -d ./logs -g "*.log"
```

### JSON Format for Reliability

Use `--format` in steps to ensure parseable JSON output:

```yaml
- name: extract-data
  template: blank
  format: '{"type":"object","properties":{"score":{"type":"number"},"tags":{"type":"array"}}}'
  input: Extract structured data from: ${INPUT}
  output: DATA
```

## License

MIT License - see [LICENSE.md](LICENSE.md)
