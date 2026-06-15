mod db;
mod mqtt;

use db::insert_reading;
use mqtt::listener_mac;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();

    let host = std::env::var("MQTT_HOST").expect("MQTT_HOST not set");
    let topic = std::env::var("MQTT_TOPIC").expect("MQTT_TOPIC not set");
    let listener_id = listener_mac();

    let pool = db::connect().await?;
    println!("postgres connected");

    let mut handle = mqtt::run(host, topic, listener_id);

    while let Some(reading) = handle.rx.recv().await {
        match insert_reading(&pool, &reading).await {
            Ok(_) => println!("stored: {}:{}", reading.node_id, reading.topic),
            Err(e) => eprintln!("insert failed for {}: {e}", reading.topic),
        }
    }

    println!("mqtt stream closed");
    Ok(())
}
