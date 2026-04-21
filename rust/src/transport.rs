//! mDNS + TCP transport for peer discovery and message delivery.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use serde::{Deserialize, Serialize};

const SERVICE_TYPE: &str = "_ferry._tcp.local.";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageEnvelope {
    pub from: String,
    pub data: Vec<u8>,
    pub timestamp: u64,
}

pub struct MdnsTransport {
    pub user_name: String,
    pub tcp_port: u16,
    pub peers: Arc<Mutex<HashMap<String, SocketAddr>>>,
    pub incoming: Arc<Mutex<VecDeque<MessageEnvelope>>>,
    _mdns: ServiceDaemon,
}

impl MdnsTransport {
    pub fn new(user_name: &str) -> Result<Self, String> {
        let incoming: Arc<Mutex<VecDeque<MessageEnvelope>>> =
            Arc::new(Mutex::new(VecDeque::new()));
        let peers: Arc<Mutex<HashMap<String, SocketAddr>>> = Arc::new(Mutex::new(HashMap::new()));

        // Bind TCP listener on a random port
        let listener = TcpListener::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();

        // Background thread: accept incoming TCP connections
        {
            let incoming = Arc::clone(&incoming);
            thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let incoming = Arc::clone(&incoming);
                    thread::spawn(move || {
                        if let Ok(envelope) = read_envelope(stream) {
                            incoming.lock().unwrap().push_back(envelope);
                        }
                    });
                }
            });
        }

        // Start mDNS daemon
        let mdns = ServiceDaemon::new().map_err(|e| e.to_string())?;

        // Register our service with the actual local IP so cross-platform discovery works
        let local_ip = get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
        // Use hostname distinct from the OS hostname to avoid conflicts with system mDNSResponder
        let hostname = format!("ferry-{}.local.", user_name);
        let service_info = ServiceInfo::new(
            SERVICE_TYPE,
            user_name,
            &hostname,
            local_ip.as_str(),
            port,
            None,
        )
        .map_err(|e| e.to_string())?;
        mdns.register(service_info).map_err(|e| e.to_string())?;

        // Browse for peers
        let receiver = mdns.browse(SERVICE_TYPE).map_err(|e| e.to_string())?;
        let peers_bg = Arc::clone(&peers);
        let my_name = user_name.to_string();
        thread::spawn(move || {
            while let Ok(event) = receiver.recv() {
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        // fullname = "username._ferry._tcp.local."
                        let fullname = info.get_fullname();
                        let name = fullname
                            .strip_suffix(&format!(".{}", SERVICE_TYPE))
                            .unwrap_or_else(|| {
                                // fallback: take the part before the first '.'
                                fullname.split('.').next().unwrap_or(fullname)
                            })
                            .to_string();
                        if name != my_name {
                            if let Some(addr) = info.get_addresses().iter().next() {
                                let sa = SocketAddr::new(*addr, info.get_port());
                                peers_bg.lock().unwrap().insert(name, sa);
                            }
                        }
                    }
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        let name = fullname
                            .strip_suffix(&format!(".{}", SERVICE_TYPE))
                            .unwrap_or_else(|| fullname.split('.').next().unwrap_or(&fullname))
                            .to_string();
                        // Only remove if it was an mDNS peer (don't remove manually-added peers)
                        peers_bg.lock().unwrap().remove(&name);
                    }
                    _ => {}
                }
            }
        });

        Ok(Self {
            user_name: user_name.to_string(),
            tcp_port: port,
            peers,
            incoming,
            _mdns: mdns,
        })
    }

    /// Manually register a peer's address (fallback when mDNS doesn't work cross-platform).
    pub fn add_peer(&self, name: &str, addr: SocketAddr) {
        self.peers.lock().unwrap().insert(name.to_string(), addr);
    }

    /// Try to send. Returns Ok(true) if sent, Ok(false) if peer not discovered yet.
    pub fn try_send(&self, to_user: &str, data: Vec<u8>) -> Result<bool, String> {
        let addr = self.peers.lock().unwrap().get(to_user).copied();
        match addr {
            Some(addr) => {
                let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))
                    .map_err(|e| format!("TCP connect to {} ({}): {}", to_user, addr, e))?;
                let envelope = MessageEnvelope {
                    from: self.user_name.clone(),
                    data,
                    timestamp: now_ms(),
                };
                write_envelope(&mut stream, &envelope).map_err(|e| e.to_string())?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    pub fn try_recv(&self) -> Option<MessageEnvelope> {
        self.incoming.lock().unwrap().pop_front()
    }

    pub fn list_peers(&self) -> Vec<String> {
        self.peers.lock().unwrap().keys().cloned().collect()
    }

    pub fn list_peers_with_addrs(&self) -> Vec<(String, String)> {
        self.peers
            .lock()
            .unwrap()
            .iter()
            .map(|(name, addr)| (name.clone(), addr.to_string()))
            .collect()
    }
}

fn write_envelope(stream: &mut TcpStream, envelope: &MessageEnvelope) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(envelope)?;
    let len = (bytes.len() as u32).to_be_bytes();
    stream.write_all(&len)?;
    stream.write_all(&bytes)?;
    stream.flush()
}

fn read_envelope(mut stream: TcpStream) -> std::io::Result<MessageEnvelope> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf)?;
    serde_json::from_slice(&buf).map_err(std::io::Error::other)
}

fn get_local_ip() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(ip) => Some(ip.to_string()),
        IpAddr::V6(ip) => Some(ip.to_string()),
    }
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
