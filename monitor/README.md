
# Monitor

This directory contains tools and scripts for monitoring and alerting Solana validators.

## Structure

- **grafana/**
  - `Hayek Hardware Metrics.json` and `Hayek Validators Metrics.json`: Grafana dashboards for visualizing hardware and validator metrics.

- **scripts/**
  - `get_tvc_rank.py`: Flask microservice that queries the TVC Rank of a validator using Playwright and exposes it via a REST API.
  - `hayek-monitor.env`: Environment variables file. Contains the necessary configuration for the scripts.
  - `solana-cluster-alert-formatter.py`: Multi-validator monitoring and alert system. Processes logs, detects critical events, and sends notifications to Discord and Telegram.
  - `validator_metrics.sh`: Bash script to collect validator and block metrics, sending results to InfluxDB.

## Usage

1. **Configure the `hayek-monitor.env` file** with your example or real values (never share sensitive data).
2. **Run the scripts** according to your needs:
   - For continuous monitoring and alerts, use `solana-cluster-alert-formatter.py`.
   - For metrics collection, run `validator_metrics.sh`.
   - To query TVC Rank, start `get_tvc_rank.py` and access the `/tvc-rank` endpoint.
3. **Visualize metrics** in the included Grafana dashboards.

## Requirements

- Python 3, Flask, Playwright (for `get_tvc_rank.py`)
- Bash and standard utilities (`curl`, `jq`, etc.) for shell scripts
- Access to InfluxDB and Grafana for visualizationtors, promoting best practices and security.