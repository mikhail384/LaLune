// A local, deterministic UDP echo core for disposable VM tunnel tests only.
use std::io::{self, Write};
use std::net::UdpSocket;
use std::convert::TryInto;

fn checksum(bytes: &[u8]) -> u16 {
    let mut sum = 0u32;
    for chunk in bytes.chunks(2) {
        sum += ((chunk[0] as u16) << 8 | chunk.get(1).copied().unwrap_or(0) as u16) as u32;
    }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16); }
    !(sum as u16)
}

fn tcp_reply(packet: &[u8]) -> Option<Vec<u8>> {
    let ihl = (packet.first()? & 15) as usize * 4;
    if ihl < 20 || packet.len() < ihl + 20 { return None; }
    let tcp_len = (packet[ihl + 12] >> 4) as usize * 4;
    if tcp_len < 20 || packet.len() < ihl + tcp_len { return None; }
    let flags = packet[ihl + 13];
    let data_len = packet.len() - ihl - tcp_len;
    let syn = flags & 0x02 != 0 && flags & 0x10 == 0;
    if !syn && data_len == 0 { return None; }
    let body: &[u8] = if syn { b"" } else { b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\nlalune-tunnel" };
    let mut result = vec![0u8; 40 + body.len()];
    result[0] = 0x45;
    let total = result.len() as u16;
    result[2..4].copy_from_slice(&total.to_be_bytes());
    result[8] = 64;
    result[9] = 6;
    result[12..16].copy_from_slice(&packet[16..20]);
    result[16..20].copy_from_slice(&packet[12..16]);
    result[20..22].copy_from_slice(&packet[ihl + 2..ihl + 4]);
    result[22..24].copy_from_slice(&packet[ihl..ihl + 2]);
    result[24..28].copy_from_slice(&(if syn { 1000u32 } else { 1001u32 }).to_be_bytes());
    let incoming_seq = u32::from_be_bytes(packet[ihl + 4..ihl + 8].try_into().ok()?);
    let ack = incoming_seq.wrapping_add(if syn { 1 } else { data_len as u32 });
    result[28..32].copy_from_slice(&ack.to_be_bytes());
    result[32] = 5 << 4;
    result[33] = if syn { 0x12 } else { 0x18 };
    result[34..36].copy_from_slice(&65535u16.to_be_bytes());
    result[40..].copy_from_slice(body);
    let ip_sum = checksum(&result[..20]);
    result[10..12].copy_from_slice(&ip_sum.to_be_bytes());
    let mut pseudo = Vec::with_capacity(12 + result.len() - 20);
    pseudo.extend_from_slice(&result[12..20]);
    pseudo.extend_from_slice(&[0, 6]);
    pseudo.extend_from_slice(&((result.len() - 20) as u16).to_be_bytes());
    pseudo.extend_from_slice(&result[20..]);
    let tcp_sum = checksum(&pseudo);
    result[36..38].copy_from_slice(&tcp_sum.to_be_bytes());
    Some(result)
}

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
        let (mut size, peer) = socket.recv_from(&mut packet)?;
        if size < 28 || packet[0] >> 4 != 4 { continue; }
        if packet[9] == 6 {
            if let Some(reply) = tcp_reply(&packet[..size]) { socket.send_to(&reply, peer)?; }
            continue;
        }
        if packet[9] != 17 { continue; }
        let header = (packet[0] as usize & 15) * 4;
        if header < 20 || size < header + 8 { continue; }
        let destination_port = u16::from_be_bytes([packet[header + 2], packet[header + 3]]);
        // A deterministic A-record DNS server for split-routing tests. All
        // other UDP destinations retain the original echo behavior.
        if destination_port == 53 && size >= header + 20 {
            let dns = header + 8;
            let mut cursor = dns + 12;
            while cursor < size && packet[cursor] != 0 {
                let len = packet[cursor] as usize;
                if len > 63 || cursor + len + 1 >= size { break; }
                cursor += len + 1;
            }
            if cursor + 5 <= size && packet[cursor] == 0 && size + 16 <= packet.len() {
                let question_end = cursor + 5;
                packet[dns + 2] = 0x81;
                packet[dns + 3] = 0x80;
                packet[dns + 6] = 0;
                packet[dns + 7] = 1;
                packet[dns + 8..dns + 12].fill(0);
                let answer = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 1, 1, 1, 1];
                packet[question_end..question_end + answer.len()].copy_from_slice(&answer);
                size = question_end + answer.len();
                packet[2..4].copy_from_slice(&(size as u16).to_be_bytes());
                packet[header + 4..header + 6].copy_from_slice(&((size - header) as u16).to_be_bytes());
            }
        }
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
