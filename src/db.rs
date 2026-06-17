use sqlx::PgPool;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use std::time::Duration;
use tokio::time::sleep;
use tracing::{info, warn};

const MAX_CONNECTIONS: u32 = 4;
const CONNECT_TIMEOUT_SECS: u64 = 10;
const PG_DEFAULT_PORT: u16 = 5432;
const CONNECT_RETRIES: u32 = 10;
const RETRY_DELAY_SECS: u64 = 3;

pub struct Reading {
    pub node_id: String,
    pub topic: String,
    pub payload: serde_json::Value,
}

pub async fn connect() -> Result<PgPool, sqlx::Error> {
    let host = std::env::var("PG_HOST").expect("PG_HOST not set");
    let port: u16 = std::env::var("PG_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(PG_DEFAULT_PORT);
    let user = std::env::var("PG_USER").expect("PG_USER not set");
    let password = std::env::var("PG_PASSWORD").expect("PG_PASSWORD not set");
    let db = std::env::var("PG_DB").expect("PG_DB not set");

    let url = format!("postgres://{user}:{password}@{host}:{port}/{db}");
    let conn_opts: PgConnectOptions = url.parse().expect("invalid pg connection url");

    // PG may not be up yet (concurrent boot, restart, etc.) — retry before giving up.
    let mut last_err = None;
    for attempt in 1..=CONNECT_RETRIES {
        let pool = PgPoolOptions::new()
            .max_connections(MAX_CONNECTIONS)
            .acquire_timeout(Duration::from_secs(CONNECT_TIMEOUT_SECS))
            .connect_with(conn_opts.clone());
        match pool.await {
            Ok(pool) => {
                info!(attempt, "postgres connected");
                return Ok(pool);
            }
            Err(e) => {
                warn!(attempt, retries = CONNECT_RETRIES, error = %e, "postgres connect failed, retrying");
                last_err = Some(e);
                sleep(Duration::from_secs(RETRY_DELAY_SECS)).await;
            }
        }
    }
    Err(last_err.expect("at least one attempt made"))
}

pub async fn insert_reading(pool: &PgPool, r: &Reading) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO readings (node_id, topic, payload)
         VALUES ($1, $2, $3)",
    )
    .bind(&r.node_id)
    .bind(&r.topic)
    .bind(&r.payload)
    .execute(pool)
    .await
    .map(|_| ())
}
