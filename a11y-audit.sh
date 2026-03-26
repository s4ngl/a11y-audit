#!/usr/bin/env bash
# =============================================================================
# a11y-audit.sh — Accessibility Audit Runner
# Tools: Pa11y-CI (axe-core + HTMLCS) | Google Lighthouse | WAVE WebAIM API
#
# Usage:
#   ./a11y-audit.sh                          # uses SITES array below
#   ./a11y-audit.sh -f urls.txt              # one URL per line
#   ./a11y-audit.sh -u https://example.com   # single URL
#   ./a11y-audit.sh --skip-pa11y             # skip Pa11y-CI
#   ./a11y-audit.sh --skip-lighthouse        # skip Lighthouse
#   ./a11y-audit.sh --skip-wave              # skip WAVE WebAIM API
#   ./a11y-audit.sh --install-deps           # auto-install missing npm tools
#
# WAVE requires an API key — set WAVE_API_KEY in your environment or .env file.
# Get a key at: https://wave.webaim.org/api/
# =============================================================================

set -euo pipefail

# Load WAVE_API_KEY (and any other vars) from .env if it exists.
[[ -f ".env" ]] && set -a && source ".env" && set +a

# ─── CONFIG ──────────────────────────────────────────────────────────────────

SITES=(
  "https://example.com"
  "https://example.org"
)

WCAG_STANDARD="WCAG2AA"                                    # WCAG2A | WCAG2AA | WCAG2AAA
REPORT_DIR="./a11y-reports/$(date +%Y-%m-%d_%H-%M-%S)"
PA11Y_TIMEOUT=60000                                        # ms
LIGHTHOUSE_TIMEOUT=60                                      # seconds
MAX_PARALLEL=3                                             # concurrent Lighthouse jobs
WAVE_API_KEY="${WAVE_API_KEY:-}"                           # set in .env or environment
WAVE_API_URL="https://wave.webaim.org/api/request"

# ─── FLAGS ───────────────────────────────────────────────────────────────────

RUN_PA11Y=true
RUN_LIGHTHOUSE=true
RUN_WAVE=true
INSTALL_DEPS=false
URL_FILE=""
SINGLE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)         URL_FILE="$2";    shift 2 ;;
    -u|--url)          SINGLE_URL="$2";  shift 2 ;;
    --skip-pa11y)      RUN_PA11Y=false;  shift ;;
    --skip-lighthouse) RUN_LIGHTHOUSE=false; shift ;;
    --skip-wave)       RUN_WAVE=false;   shift ;;
    --install-deps)    INSTALL_DEPS=true; shift ;;
    -h|--help)         grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'; exit 0 ;;
    *)                 echo "Unknown flag: $1 (try -h)"; exit 1 ;;
  esac
done

# ─── LOGGING ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[PASS]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[FAIL]${RESET}  $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ─── DEPENDENCIES ────────────────────────────────────────────────────────────

require() {
  local cmd="$1" pkg="$2"
  if command -v "$cmd" &>/dev/null; then
    success "$cmd found ($(command -v "$cmd"))"
  elif [[ "$INSTALL_DEPS" == true ]]; then
    warn "$cmd not found — installing $pkg ..."
    npm install -g "$pkg"
  else
    error "$cmd not found. Run with --install-deps, or: npm install -g $pkg"
    return 1
  fi
}

header "Checking Dependencies"
DEPS_OK=true
[[ "$RUN_PA11Y"      == true ]] && { require "pa11y-ci"  "pa11y-ci"  || DEPS_OK=false; }
[[ "$RUN_LIGHTHOUSE" == true ]] && { require "lighthouse" "lighthouse" || DEPS_OK=false; }
[[ "$RUN_WAVE"       == true ]] && { require "curl" "curl (system package)" || DEPS_OK=false; }
require "jq" "jq" || { warn "jq not found — detailed issue counts will be unavailable"; }

# WAVE requires an API key — skip gracefully if missing rather than hard-failing.
if [[ "$RUN_WAVE" == true ]] && [[ -z "$WAVE_API_KEY" ]]; then
  warn "WAVE_API_KEY is not set — skipping WAVE. Add it to .env or export it."
  RUN_WAVE=false
fi

[[ "$DEPS_OK" == false ]] && { error "Missing dependencies. Re-run with --install-deps."; exit 1; }

# Resolve a portable timeout command once (GNU coreutils or macOS gtimeout).
TIMEOUT_CMD=""
for t in gtimeout timeout; do command -v "$t" &>/dev/null && TIMEOUT_CMD="$t" && break; done

# ─── LOAD URLS ───────────────────────────────────────────────────────────────

if [[ -n "$SINGLE_URL" ]]; then
  SITES=("$SINGLE_URL")
elif [[ -n "$URL_FILE" ]]; then
  [[ -f "$URL_FILE" ]] || { error "File not found: $URL_FILE"; exit 1; }
  SITES=()
  while IFS= read -r line; do SITES+=("$line"); done \
    < <(grep -v '^\s*#' "$URL_FILE" | grep -v '^\s*$')
fi

[[ ${#SITES[@]} -eq 0 ]] && { error "No URLs to scan."; exit 1; }

header "Targets (${#SITES[@]} URL(s))"
for url in "${SITES[@]}"; do log "$url"; done

# ─── HELPERS ─────────────────────────────────────────────────────────────────

mkdir -p "$REPORT_DIR/pa11y" "$REPORT_DIR/lighthouse" "$REPORT_DIR/wave"

# Turn a URL into a readable filename: strip protocol, convert dots to dashes,
# append path segments. e.g. https://ci.iu.edu/ci/v2/ → ci-iu-edu-ci-v2
slug() {
  local url="$1"
  local host path
  host=$(echo "$url" | sed 's|^https://||; s|^http://||; s|/.*||; s|^www\.||; s|\.|-|g')
  path=$(echo "$url" | sed 's|^https://[^/]*||; s|^http://[^/]*||; s|^/||; s|/*$||; s|/|-|g; s|[^a-zA-Z0-9_-]||g')
  if [[ -n "$path" ]]; then echo "${host}-${path}"; else echo "$host"; fi
}

# Build a zero-padded indexed slug for every input URL, e.g. 03_ci-iu-edu-ci-v2.
# Using indices keeps pa11y and lighthouse filenames in sync regardless of redirects.
SLUGS=()
for i in "${!SITES[@]}"; do
  SLUGS+=("$(printf '%02d' $((i + 1)))_$(slug "${SITES[$i]}")")
done

# Arrays to accumulate results for the final summary.
PA11Y_LINES=()
LIGHTHOUSE_LINES=()
WAVE_LINES=()

# ─── PA11Y-CI ────────────────────────────────────────────────────────────────

run_pa11y() {
  header "Running Pa11y-CI"

  local config="$REPORT_DIR/pa11y/pa11y-config.json"
  local urls_json; urls_json=$(printf '%s\n' "${SITES[@]}" | jq -R . | jq -s .)

  # Write pa11y-ci config file.
  jq -n \
    --argjson urls "$urls_json" \
    --arg std "$WCAG_STANDARD" \
    --argjson timeout "$PA11Y_TIMEOUT" \
    '{
      urls: $urls,
      defaults: {
        standard: $std,
        timeout: $timeout,
        wait: 2000,
        runners: ["axe", "htmlcs"],
        reporters: ["cli"],
        chromeLaunchConfig: { args: ["--no-sandbox", "--disable-setuid-sandbox"] }
      }
    }' > "$config"

  log "Config → $config"

  pa11y-ci --config "$config" --json \
    > "$REPORT_DIR/pa11y/results.json" \
    2> "$REPORT_DIR/pa11y/stderr.log" \
    && warn "Pa11y-CI: no issues found" \
    || warn "Pa11y-CI found issues — see $REPORT_DIR/pa11y/results.json"

  # Split results into per-URL files using input-based indexed slugs.
  # Pa11y follows redirects so result keys may differ from input URLs.
  # Match each input URL to its result key by hostname, then write using SLUGS[i].
  if command -v jq &>/dev/null && [[ -f "$REPORT_DIR/pa11y/results.json" ]]; then
    local result_keys=()
    while IFS= read -r k; do result_keys+=("$k"); done \
      < <(jq -r '.results | keys[]' "$REPORT_DIR/pa11y/results.json" 2>/dev/null)

    for i in "${!SITES[@]}"; do
      local input_url="${SITES[$i]}" result_url="${SITES[$i]}"
      local host; host=$(echo "$input_url" | sed 's|^https://||; s|^http://||; s|/.*||')

      # Find the redirect-resolved key that matches this input URL's host.
      for k in "${result_keys[@]}"; do
        [[ "$k" == *"$host"* ]] && result_url="$k" && break
      done

      jq --arg u "$result_url" '.results[$u] // {}' \
        "$REPORT_DIR/pa11y/results.json" \
        > "$REPORT_DIR/pa11y/${SLUGS[$i]}.json" 2>/dev/null || true

      local axe htmlcs total
      axe=$(jq   --arg u "$result_url" '[.results[$u][]? | select(.runner=="axe")]    | length' "$REPORT_DIR/pa11y/results.json" 2>/dev/null || echo "?")
      htmlcs=$(jq --arg u "$result_url" '[.results[$u][]? | select(.runner=="htmlcs")] | length' "$REPORT_DIR/pa11y/results.json" 2>/dev/null || echo "?")
      total=$(jq  --arg u "$result_url" '(.results[$u] // []) | length'                          "$REPORT_DIR/pa11y/results.json" 2>/dev/null || echo "?")

      PA11Y_LINES+=("  Pa11y-CI : ${total} issues (axe: ${axe}, htmlcs: ${htmlcs})  — $input_url")
    done
  fi
}

# ─── LIGHTHOUSE ──────────────────────────────────────────────────────────────

run_lighthouse_single() {
  local idx="$1" url="$2"
  local slug="${SLUGS[$idx]}"
  local tmp="$REPORT_DIR/lighthouse/.tmp_${slug}"   # Lighthouse appends .report.{json,html}
  local out="$REPORT_DIR/lighthouse/${slug}"

  log "Lighthouse → $url"

  local lh_cmd=(lighthouse "$url"
    --only-categories=accessibility
    --output=json,html
    --output-path="$tmp"
    --chrome-flags="--headless --no-sandbox --disable-gpu"
    --no-enable-error-reporting
    --quiet
  )

  local exit_code=0
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$LIGHTHOUSE_TIMEOUT" "${lh_cmd[@]}" \
      < /dev/null 2>>"$REPORT_DIR/lighthouse/stderr.log" || exit_code=$?
  else
    "${lh_cmd[@]}" < /dev/null 2>>"$REPORT_DIR/lighthouse/stderr.log" || exit_code=$?
  fi

  # Rename Lighthouse's default .report.{json,html} suffixes to clean extensions.
  [[ -f "${tmp}.report.json" ]] && mv "${tmp}.report.json" "${out}.json"
  [[ -f "${tmp}.report.html" ]] && mv "${tmp}.report.html" "${out}.html"

  # Write result to a temp file — this runs in a subshell (&) so we can't
  # append directly to LIGHTHOUSE_LINES. Collect after wait() instead.
  if [[ "$exit_code" -eq 0 ]] && [[ -f "${out}.json" ]]; then
    local score
    score=$(jq -r '.categories.accessibility.score * 100 | floor | tostring + "%"' \
      "${out}.json" 2>/dev/null || echo "N/A")
    success "Lighthouse done: $url → $score"
    echo "  Lighthouse : $score  — $url" > "$REPORT_DIR/lighthouse/.result_${idx}.txt"
  else
    warn "Lighthouse failed for $url (exit $exit_code)"
    echo "  Lighthouse : ERROR  — $url" > "$REPORT_DIR/lighthouse/.result_${idx}.txt"
  fi
}

run_lighthouse() {
  header "Running Lighthouse"
  local pids=()
  for i in "${!SITES[@]}"; do
    run_lighthouse_single "$i" "${SITES[$i]}" &
    pids+=($!)
    if [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; then
      wait "${pids[0]}"; pids=("${pids[@]:1}")
    fi
  done
  wait

  # Collect per-URL result lines in input order, then clean up temp files.
  for i in "${!SITES[@]}"; do
    local f="$REPORT_DIR/lighthouse/.result_${i}.txt"
    [[ -f "$f" ]] && LIGHTHOUSE_LINES+=("$(cat "$f")") && rm "$f"
  done
}

# ─── WAVE WebAIM API ─────────────────────────────────────────────────────────

run_wave() {
  header "Running WAVE WebAIM API"

  for i in "${!SITES[@]}"; do
    local url="${SITES[$i]}"
    local out="$REPORT_DIR/wave/${SLUGS[$i]}.json"

    log "WAVE → $url"

    local http_code
    http_code=$(curl -s -o "$out" -w "%{http_code}" \
      "${WAVE_API_URL}?key=${WAVE_API_KEY}&url=${url}&reporttype=2")

    if [[ "$http_code" != "200" ]]; then
      warn "WAVE failed for $url (HTTP $http_code)"
      WAVE_LINES+=("  WAVE       : ERROR (HTTP $http_code)  — $url")
      continue
    fi

    # Surface the two numbers users care about most: hard errors and contrast errors.
    local errors contrast credits
    errors=$(jq  '.categories.error.count'    "$out" 2>/dev/null || echo "?")
    contrast=$(jq '.categories.contrast.count' "$out" 2>/dev/null || echo "?")
    credits=$(jq  '.statistics.creditsremaining' "$out" 2>/dev/null || echo "?")

    success "WAVE done: $url → ${errors} errors, ${contrast} contrast errors (${credits} credits left)"
    WAVE_LINES+=("  WAVE       : ${errors} errors, ${contrast} contrast  — $url")
  done
}



START=$SECONDS

[[ "$RUN_PA11Y"      == true ]] && run_pa11y
[[ "$RUN_LIGHTHOUSE" == true ]] && run_lighthouse
[[ "$RUN_WAVE"       == true ]] && run_wave

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

ELAPSED=$(( SECONDS - START ))

TOOLS_USED=()
[[ "$RUN_PA11Y"      == true ]] && TOOLS_USED+=("Pa11y-CI (axe + htmlcs)")
[[ "$RUN_LIGHTHOUSE" == true ]] && TOOLS_USED+=("Lighthouse")
[[ "$RUN_WAVE"       == true ]] && TOOLS_USED+=("WAVE WebAIM API")
TOOLS_STR=$(IFS=", "; echo "${TOOLS_USED[*]}")

SUMMARY="$REPORT_DIR/summary.txt"

cat > "$SUMMARY" <<EOF
================================================================================
  ACCESSIBILITY AUDIT SUMMARY
  Date     : $(date)
  Standard : $WCAG_STANDARD
  URLs     : ${#SITES[@]}
  Tools    : $TOOLS_STR
================================================================================

PA11Y-CI:
$(printf '%s\n' "${PA11Y_LINES[@]:-  (skipped)}")

LIGHTHOUSE:
$(printf '%s\n' "${LIGHTHOUSE_LINES[@]:-  (skipped)}")

WAVE WebAIM:
$(printf '%s\n' "${WAVE_LINES[@]:-  (skipped)}")

================================================================================
  Completed in ${ELAPSED}s
  Reports saved to: $REPORT_DIR/

  Directory structure:
    $REPORT_DIR/
    ├── summary.txt
    ├── pa11y/
    │   ├── results.json              ← full pa11y output (both runners)
    │   └── NN_<slug>.json            ← per-URL breakdown, indexed + sorted
    ├── lighthouse/
    │   ├── NN_<slug>.json            ← full Lighthouse JSON
    │   └── NN_<slug>.html            ← viewable HTML report
    └── wave/
        └── NN_<slug>.json            ← full WAVE API response
================================================================================
EOF

header "Audit Complete"
log "Duration : ${ELAPSED}s"
log "Reports  : $REPORT_DIR/"
echo ""
cat "$SUMMARY"

tar -czf "$(dirname "$REPORT_DIR")/latest-report.tar.gz" "$REPORT_DIR/"
