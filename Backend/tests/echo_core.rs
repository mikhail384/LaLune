// A local, deterministic UDP echo core for disposable VM tunnel tests only.
use std::io::{self, Write};
use std::net::UdpSocket;

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let address = args.windows(2)
        .find(|p| p[0] == "--listen" || p[0] == "--socks5")
        .map(|p| p[1].as_str()).unwrap_or("127.0.0.1:52230");
    let socket = UdpSocket::bind(address)?;
    println!("[КЛИЕНТ] Tunnel IP: 10.66.67.2/32 | DNS: 1.1.1.1");
    for _ in 0..3 { println!("[СТАТИСТИКА] Активных: 1 | Трафик: 0.00 МБ"); }
    io::stdout().flush()?;
    let mut packet = [0u8; 65535];
    loop {
        let (size, peer) = socket.recv_from(&mut packet)?;
        if size < 28 || packet[0] >> 4 != 4 || packet[9] != 17 { continue; }
        let header = (packet[0] as usize & 15) * 4;
        if header < 20 || size < header + 8 { continue; }
        for i in 0..4 { packet.swap(12 + i, 16 + i); }
        packet.swap(header, header + 2);
        packet.swap(header + 1, header + 3);
        packet[header + 6] = 0;
        packet[header + 7] = 0;
        packet[10] = 0;
        packet[11] = 0;
        let mut sum = 0u32;
        for pair in packet[..header].chunks_exact(2) {
            sum += u16::from_be_bytes([pair[0], pair[1]]) as u32;
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16); }
        let checksum = (!(sum as u16)).to_be_bytes();
        packet[10..12].copy_from_slice(&checksum);
        socket.send_to(&packet[..size], peer)?;
    }
}
