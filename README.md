# pg - PostgreSQL Database Diagnostic Tool

A comprehensive command-line tool for PostgreSQL database monitoring, diagnostics, and performance analysis.

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-9.6%20--%2018-336791.svg)](https://www.postgresql.org/)

## Features

- **Quick Diagnostics** - Process list, active queries, blocking analysis
- **Slow Query Analysis** - Identify and analyze performance bottlenecks
- **Table & Index Management** - Size analysis, bloat detection, unused indexes
- **Vacuum & Maintenance** - Monitor vacuum operations and dead tuples
- **Connection Management** - Session stats, idle transactions, connection limits
- **Performance Monitoring** - Cache hit ratios, I/O stats, wait events
- **Replication Status** - Monitor replication lag and slots
- **WAL & Checkpoint** - WAL position, checkpoint statistics
- **Security Audit** - Privilege audit, security checks, user access patterns
- **Enterprise Monitoring** - SLA tracking, alert engine, compliance checks

## Requirements

- PostgreSQL 9.6 - 18
- `psql` client
- Bash 4.0+

## Installation

```bash
# Clone the repository
git clone https://github.com/Kevin-wenyu/pg-tool.git
cd pg-tool

# Make executable
chmod +x pg

# Optional: Add to PATH
sudo ln -s $(pwd)/pg /usr/local/bin/pg
```

## Quick Start

```bash
# Show help
./pg --help

# Connect using environment variables
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=postgres
./pg ps

# Or specify connection parameters
./pg -h localhost -p 5432 -u postgres -d mydb ps
```

## Authentication

The tool supports multiple authentication methods:

1. **Environment variable**: `export PGPASSWORD=your_password`
2. **Password file**: `./pg -P /path/to/.pgpass ps`
3. **pgpass file**: `~/.pgpass` or `./.pgpass`

## Commands

### Quick Diagnostics

| Command | Description |
|---------|-------------|
| `ps` | Process list (all sessions) |
| `running [N]` | Active queries |
| `blocking` | Enhanced blocking analysis with root cause |
| `locks` | Lock overview |
| `kill <pid>` | Terminate session |
| `cancel <pid>` | Cancel query |
| `sql <pid>` | Show full SQL text |

### Slow Query Analysis

| Command | Description |
|---------|-------------|
| `slow [pid] [seconds]` | Enhanced slow query analysis (default: 5s) |
| `top_time [N]` | Top queries by total time |
| `top_calls [N]` | Top queries by call count |
| `top_io [N]` | Top queries by I/O |
| `query_history [N]` | Recent query statistics |

### Table & Index

| Command | Description |
|---------|-------------|
| `table_size [pattern]` | Table sizes (optional: schema.table%) |
| `index_size [pattern]` | Index sizes |
| `bloat` | Table bloat analysis |
| `unused_indexes` | Unused indexes (safe to drop) |
| `duplicate_indexes` | Redundant indexes |
| `missing_indexes` | Suggested indexes |

### Vacuum & Maintenance

| Command | Description |
|---------|-------------|
| `vacuum_status` | Last vacuum/analyze times |
| `dead_tuples` | Tables with dead tuples |
| `vacuum_progress` | Running vacuum operations |

### Connections

| Command | Description |
|---------|-------------|
| `conn` | Connection summary |
| `conn_limit` | Connection limits per user/db |
| `idle_tx` | Idle in transaction sessions |
| `sessions` | Session stats by user/app |

### Performance

| Command | Description |
|---------|-------------|
| `cache_hit` | Cache hit ratios |
| `io_stats` | I/O statistics |
| `wait_events` | Wait event summary |
| `temp_files` | Temporary file usage |

### Replication

| Command | Description |
|---------|-------------|
| `repl` | Replication status |
| `repl_lag` | Replication lag details |
| `slot` | Replication slots |
| `slot_usage` | Replication slot usage warning |

### WAL & Checkpoint

| Command | Description |
|---------|-------------|
| `wal` | WAL position info |
| `wal_rate [sec]` | WAL generation rate |
| `checkpoint` | Checkpoint statistics |

### Storage

| Command | Description |
|---------|-------------|
| `db_size` | Database sizes |
| `ts_size` | Tablespace sizes |
| `schema_size` | Schema sizes |
| `toast_tables` | TOAST table sizes |

### Configuration

| Command | Description |
|---------|-------------|
| `config [pattern]` | Show settings (optional filter) |
| `config_diff` | Non-default settings |
| `reload` | Reload configuration |

### Schema Info

| Command | Description |
|---------|-------------|
| `tables [pattern]` | List tables |
| `indexes [pattern]` | List indexes |
| `views [pattern]` | List views |
| `functions [pattern]` | List functions |
| `triggers [pattern]` | List triggers |
| `fks` | Foreign keys |
| `pks` | Primary keys |
| `constraints` | All constraints |

### Security

| Command | Description |
|---------|-------------|
| `users` | List users |
| `roles` | List roles |
| `permissions` | Object permissions |
| `privilege_audit` | Privilege audit |
| `security_checks` | Security configuration checks |
| `user_access_pattern` | User access patterns |

### Health Check

| Command | Description |
|---------|-------------|
| `health` | Quick health check |
| `overview` | System overview |
| `uptime` | Server uptime |

### Advanced Diagnostics

| Command | Description |
|---------|-------------|
| `diagnose <scenario>` | Combined diagnosis for common DBA scenarios |
| `lock_tree` | Lock wait tree |
| `lock_chain` | Lock wait chains |
| `activity` | Active sessions |
| `bgwriter` | Background writer stats |

### Query Optimization

| Command | Description |
|---------|-------------|
| `explain "<sql>"` | Explain query plan |
| `explain_json "<sql>"` | Explain as JSON |
| `plan_analysis [N]` | Query plan analysis |
| `execution_profile [N]` | Execution profile |
| `histogram_stats <tbl>` | Histogram statistics |
| `parallel_efficiency` | Parallel efficiency metrics |

### Utility

| Command | Description |
|---------|-------------|
| `version` | PostgreSQL version |
| `ext` | Installed extensions |
| `set_config <name> <val>` | Change setting (session) |
| `watch <sec> <cmd>` | Repeat command every N seconds |

### Enterprise

| Command | Description |
|---------|-------------|
| `enterprise_monitor` | Enterprise monitoring dashboard |
| `sla_tracker` | SLA tracking |
| `alert_engine` | Alert engine |
| `security_scan` | Security scan |
| `compliance_check` | Compliance checking |

## Diagnose Scenarios

The `diagnose` command provides combined analysis for common DBA scenarios:

```bash
./pg diagnose health        # Overall health check
./pg diagnose performance   # Performance analysis
./pg diagnose connection    # Connection issues
./pg diagnose blocking      # Blocking analysis
./pg diagnose storage       # Storage analysis
./pg diagnose replication   # Replication health
./pg diagnose security      # Security audit
```

## Examples

```bash
# Show all database sessions
./pg ps

# Find slow queries (over 10 seconds)
./pg slow 10

# Check table sizes
./pg table_size public.%

# Top 20 queries by total time
./pg top_time 20

# Watch running queries every 5 seconds
./pg watch 5 running

# Check replication lag
./pg repl_lag

# Diagnose performance issues
./pg diagnose performance

# Security audit
./pg security_scan
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PGHOST` | localhost | Database host |
| `PGPORT` | 5432 | Database port |
| `PGUSER` | postgres | Database user |
| `PGDATABASE` | postgres | Database name |
| `PGPASSWORD` | - | Database password |
| `DEBUG_QUERIES` | 0 | Set to 1 for query debugging |

## Required Extensions

Some commands require the `pg_stat_statements` extension:

```sql
CREATE EXTENSION pg_stat_statements;
```

## Version Compatibility

| PostgreSQL Version | Support |
|-------------------|---------|
| 9.6 - 12 | Full support |
| 13 - 16 | Full support |
| 17 - 18 | Full support (including new system views) |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Author

Kevin

## Changelog

See [Version History](#version-history) in the source code for detailed changes.

### Current Version: 4.1.3 (2026-03-26)