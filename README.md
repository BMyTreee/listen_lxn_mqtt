# listen_lxn_mqtt

```bash
PG_HOST=your-db-host MQTT_HOST=your-mqtt-broker bash setup_lxn.sh
```

Bootstraps the `lxn` host: enables password SSH, installs Rust, writes .env (postgres + mqtt endpoints), syncs code, builds, starts tmux.
