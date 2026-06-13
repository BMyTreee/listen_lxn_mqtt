use rumqttc::{Client, Event, MqttOptions, Packet, QoS};
use std::time::Duration;

// rumqttc 0.24 is MQTT v4 (3.1.1) only. Use the v4 listener on port 1883.
const MQTT_PORT: u16 = 1883;
const KEEP_ALIVE_SECS: u64 = 5;
const QUEUE_CAP: usize = 10;

fn main() {
    dotenvy::dotenv().ok();

    let host = std::env::var("MQTT_HOST").expect("MQTT_HOST not set");
    let topic = std::env::var("MQTT_TOPIC").expect("MQTT_TOPIC not set");

    let mac = mac_address::get_mac_address()
        .ok()
        .flatten()
        .map(|m| m.to_string().replace(':', ""))
        .unwrap_or_else(|| "unknown".to_string());

    let mut options = MqttOptions::new(format!("listen_{mac}"), host, MQTT_PORT);
    options.set_keep_alive(Duration::from_secs(KEEP_ALIVE_SECS));

    let (client, mut connection) = Client::new(options, QUEUE_CAP);
    client.subscribe(&topic, QoS::AtLeastOnce).unwrap();

    println!("listen_{mac} on {topic}");

    for event in connection.iter() {
        if let Ok(Event::Incoming(Packet::Publish(publish))) = event {
            println!("{}", String::from_utf8_lossy(&publish.payload));
        }
    }
}
