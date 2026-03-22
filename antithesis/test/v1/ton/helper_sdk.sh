#!/usr/bin/env bash
# Helper: Antithesis SDK assertion functions for bash workloads.
# Sourced by test commands — not executed directly by Test Composer
# (prefixed with helper_).

# Resolve the SDK output file path
_SDK_OUTPUT="/tmp/antithesis_sdk.jsonl"
if [[ -n "${ANTITHESIS_OUTPUT_DIR:-}" ]]; then
  _SDK_OUTPUT="${ANTITHESIS_OUTPUT_DIR}/sdk.jsonl"
elif [[ -n "${ANTITHESIS_SDK_LOCAL_OUTPUT:-}" ]]; then
  _SDK_OUTPUT="${ANTITHESIS_SDK_LOCAL_OUTPUT}"
fi
mkdir -p "$(dirname "$_SDK_OUTPUT")"

# Track which assertions have already seen true/false to avoid redundant writes.
# Key: "${id}:true" or "${id}:false"
declare -A _SDK_SEEN 2>/dev/null || true

# _sdk_emit_assert <hit> <must_hit> <assert_type> <display_type> <message> <condition> [details_json]
_sdk_emit_assert() {
  local hit="$1" must_hit="$2" assert_type="$3" display_type="$4"
  local message="$5" condition="$6" details="${7:-null}"

  local json
  json=$(jq -cn \
    --argjson hit "$hit" \
    --argjson must_hit "$must_hit" \
    --arg assert_type "$assert_type" \
    --arg display_type "$display_type" \
    --arg message "$message" \
    --argjson condition "$condition" \
    --argjson details "$details" \
    '{antithesis_assert: {
        hit: $hit,
        must_hit: $must_hit,
        assert_type: $assert_type,
        display_type: $display_type,
        message: $message,
        condition: $condition,
        id: $message,
        location: {class: "", function: "", file: "workload", begin_line: 0, begin_column: 0},
        details: $details
     }}')
  echo "$json" >> "$_SDK_OUTPUT"
}

# Catalog (declare) an Always assertion at startup
sdk_catalog_always() {
  local message="$1"
  _sdk_emit_assert false true "always" "Always" "$message" false
}

# Evaluate an Always assertion at runtime.
# Usage: sdk_always <condition_bool> <message> [details_json]
#   condition_bool: "true" or "false"
sdk_always() {
  local condition="$1" message="$2" details="${3:-null}"
  local key="${message}:${condition}"
  if [[ -n "${_SDK_SEEN[$key]:-}" ]]; then
    return 0
  fi
  _SDK_SEEN["$key"]=1
  _sdk_emit_assert true true "always" "Always" "$message" "$condition" "$details"
}

# Catalog (declare) a Sometimes assertion at startup
sdk_catalog_sometimes() {
  local message="$1"
  _sdk_emit_assert false true "sometimes" "Sometimes" "$message" false
}

# Evaluate a Sometimes assertion at runtime.
# Usage: sdk_sometimes <condition_bool> <message> [details_json]
#   condition_bool: "true" or "false"
sdk_sometimes() {
  local condition="$1" message="$2" details="${3:-null}"
  local key="${message}:${condition}"
  if [[ -n "${_SDK_SEEN[$key]:-}" ]]; then
    return 0
  fi
  _SDK_SEEN["$key"]=1
  _sdk_emit_assert true true "sometimes" "Sometimes" "$message" "$condition" "$details"
}
