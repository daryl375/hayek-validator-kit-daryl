# InfluxDB Integration for Monitoring Hub

## Overview
This module provides InfluxDB v2 installation and configuration as part of the monitoring_hub role.

## Structure
Following the same pattern as Grafana:

```
tasks/influxdb/
├── main.yml        # Orchestrator - includes all other tasks
├── install.yml     # Package installation and repository setup
├── configure.yml   # Configuration files and directories
└── services.yml    # Service management and health checks
```

## Configuration Files
- **No custom configuration**: InfluxDB v2 uses default configuration out of the box
- **Variables**: Minimal variables defined in `vars/main.yml` and `defaults/main.yml`

## Default Configuration
- **Port**: 8086 (HTTP API) - uses InfluxDB default
- **Data Directory**: `/var/lib/influxdb2` - InfluxDB default
- **Config Directory**: `/etc/influxdb2` - InfluxDB default  
- **Service Name**: `influxdb`

## Variables
Key variables in `vars/main.yml`:
```yaml
monitoring_services:
  - grafana-server
  - influxdb
```

Key variables in `defaults/main.yml`:
```yaml
influxdb_port: 8086
```

## Installation Process
1. **Repository Setup**: Adds InfluxData GPG key and repository
2. **Package Installation**: Installs `influxdb2` package
3. **Service Management**: Starts and enables service with default configuration
4. **Health Check**: Verifies service is responding

## Health Check Endpoint
The service checks readiness at: `http://localhost:8086/health`

## Integration
InfluxDB is integrated into the main monitoring_hub role flow:
1. Load sensitive variables
2. Install dependencies
3. Configure directories
4. **Install InfluxDB with default config** (NEW)
5. Install and configure Grafana
6. Start services

## Usage
InfluxDB will be automatically installed when running the `pb_setup_monitoring_hub.yml` playbook.
No additional parameters are required - it follows the same execution pattern as Grafana.