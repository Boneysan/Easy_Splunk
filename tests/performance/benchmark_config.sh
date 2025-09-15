#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# tests/performance/benchmark_config.sh
# Performance benchmarking configuration
# ==============================================================================

# General settings
readonly PERF_TEST_DURATION=3600  # 1 hour
readonly PERF_SAMPLE_INTERVAL=300  # 5 minutes

# Search performance thresholds
readonly SEARCH_PERF_THRESHOLDS=(
    # Format: "search_type:max_duration_ms:max_cpu_percent:max_memory_mb"
    "realtime:1000:50:1024"
    "historical:5000:75:2048"
    "scheduled:3000:60:1536"
)

# Indexing performance thresholds
readonly INDEXING_PERF_THRESHOLDS=(
    # Format: "data_type:min_rate_mbps:max_cpu_percent:max_memory_mb"
    "raw:50:70:1024"
    "compressed:100:80:2048"
    "structured:75:75:1536"
)

# Replication performance thresholds
readonly REPLICATION_PERF_THRESHOLDS=(
    # Format: "type:max_delay_seconds:min_throughput_mbps"
    "configuration:60:10"
    "knowledge_objects:120:5"
    "bucket:300:50"
)

# Load test configurations
readonly LOAD_TEST_CONFIGS=(
    # Format: "scenario:users:ramp_up_time:duration"
    "light:10:60:300"
    "medium:50:120:600"
    "heavy:100:180:900"
)

# Test data specifications
readonly TEST_DATA_CONFIGS=(
    # Format: "type:size_mb:event_count:event_size_bytes"
    "logs:1000:1000000:1024"
    "metrics:500:5000000:128"
    "json:2000:500000:4096"
)

# Monitoring intervals
readonly MONITOR_INTERVALS=(
    # Format: "metric:interval_seconds"
    "cpu:30"
    "memory:30"
    "disk:60"
    "network:30"
)
