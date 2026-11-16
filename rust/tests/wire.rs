//! At the network card, on made-up networks: a machine that takes the gateway's place, and one that tries door
//! after door.

use garrett::lan::{opening, read_linux, read_listing, GatewayWatch, Neighbours, ScanWatch, SCAN_PORTS};

const T: f64 = 1_800_000_000.0;

fn network(pairs: &[(&str, &str)]) -> Neighbours {
    Neighbours { gateway: "192.168.1.1".into(), table: pairs.iter().map(|(address, hardware)| (address.to_string(), hardware.to_string())).collect() }
}

#[test]
fn a_machine_that_takes_the_gateways_place_is_reported_once_and_a_new_router_is_not() {
    let router = "aa:aa:aa:aa:aa:01";
    let mut watch = GatewayWatch::default();
    let quiet = network(&[("192.168.1.1", router), ("192.168.1.20", "bb:bb:bb:bb:bb:20"), ("192.168.1.30", "cc:cc:cc:cc:cc:30")]);
    assert_eq!(watch.take(&quiet), None, "the first reading is the starting point");
    assert_eq!(watch.take(&quiet), None);
    // The machine at .30 starts answering for the gateway.
    let taken = network(&[("192.168.1.1", "cc:cc:cc:cc:cc:30"), ("192.168.1.20", "bb:bb:bb:bb:bb:20"), ("192.168.1.30", "cc:cc:cc:cc:cc:30")]);
    let found = watch.take(&taken).expect("reported");
    assert_eq!((found.signal, found.points, found.address.as_str()), ("gateway_impersonated", 6, "192.168.1.30"));
    assert!(found.evidence.contains("192.168.1.1") && found.evidence.contains("192.168.1.30"));
    assert_eq!(watch.take(&taken), None, "said once while it lasts");
    assert_eq!(watch.take(&quiet), None, "and nothing when the network is put right");
    assert_eq!(watch.take(&taken), None, "nor when the same machine does it again");
    // A new router: a hardware address nobody else on the network has.
    let mut other = GatewayWatch::default();
    assert_eq!(other.take(&quiet), None);
    let replaced = network(&[("192.168.1.1", "dd:dd:dd:dd:dd:02"), ("192.168.1.20", "bb:bb:bb:bb:bb:20")]);
    assert_eq!(other.take(&replaced), None);
    assert_eq!(other.take(&replaced), None);
    // A router that has two addresses of its own from the start is how that network is.
    let mut two = GatewayWatch::default();
    let both = network(&[("192.168.1.1", router), ("192.168.1.254", router)]);
    assert_eq!(two.take(&both), None);
    assert_eq!(two.take(&both), None);
    // Nothing is known about a gateway that has not answered yet.
    assert_eq!(GatewayWatch::default().take(&network(&[("192.168.1.20", "bb:bb:bb:bb:bb:20")])), None);
}

#[test]
fn the_systems_own_tables_are_read_on_linux_and_from_a_listing() {
    let root = std::env::temp_dir().join(format!("garrett-wire-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("proc/net")).unwrap();
    std::fs::write(root.join("proc/net/route"), "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\neth0\t0001A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\neth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n").unwrap();
    std::fs::write(root.join("proc/net/arp"), "IP address       HW type     Flags       HW address            Mask     Device\n192.168.1.1      0x1         0x2         AA:AA:AA:AA:AA:01     *        eth0\n192.168.1.20     0x1         0x2         bb:bb:bb:bb:bb:20     *        eth0\n192.168.1.99     0x1         0x0         00:00:00:00:00:00     *        eth0\n").unwrap();
    let seen = read_linux(&root).expect("read");
    assert_eq!(seen.gateway, "192.168.1.1");
    assert_eq!(seen.table.get("192.168.1.1").map(String::as_str), Some("aa:aa:aa:aa:aa:01"));
    assert_eq!(seen.table.len(), 2, "an address still being asked about has no hardware address");
    let _ = std::fs::remove_dir_all(&root);
    let listed = read_listing("? (192.168.1.1) at aa:aa:aa:aa:aa:1 on en0 ifscope [ethernet]\n? (192.168.1.20) at bb:bb:bb:bb:bb:20 on en0 ifscope [ethernet]\n? (192.168.1.99) at (incomplete) on en0 ifscope [ethernet]\n? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]\n",
        "   route to: default\ndestination: default\n       mask: default\n    gateway: 192.168.1.1\n  interface: en0\n").expect("read");
    assert_eq!(listed.gateway, "192.168.1.1");
    assert_eq!(listed.table.get("192.168.1.1").map(String::as_str), Some("aa:aa:aa:aa:aa:01"), "written out in full");
    assert!(!listed.table.contains_key("192.168.1.99"));
    assert_eq!(read_listing("", "route: writing to routing socket: not in table\n"), None, "a machine with no way out has no gateway to watch");
}

#[test]
fn a_neighbour_that_tries_door_after_door_is_a_scan_and_ordinary_traffic_is_not() {
    let mut watch = ScanWatch::default();
    // A neighbour that opens many connections to the same few services.
    for attempt in 0..400 {
        assert_eq!(watch.attempt("192.168.1.20", [22, 80, 443][attempt % 3], T + attempt as f64 * 0.1), None);
    }
    // One that walks the ports.
    let mut found = None;
    for port in 1..=SCAN_PORTS as u16 {
        found = watch.attempt("192.168.1.30", port, T + f64::from(port) * 0.01);
        assert_eq!(found.is_some(), usize::from(port) == SCAN_PORTS, "port {port}");
    }
    let found = found.unwrap();
    assert_eq!((found.signal, found.points, found.address.as_str()), ("port_scan", 5, "192.168.1.30"));
    for port in 1000..1200 {
        assert_eq!(watch.attempt("192.168.1.30", port, T + 10.0), None, "said once an hour");
    }
    // The same number of ports spread over an hour is not a scan.
    for port in 1..=200u16 {
        assert_eq!(watch.attempt("192.168.1.40", port, T + f64::from(port) * 20.0), None);
    }
    // The open internet scans every machine all day: nothing is said, and this machine is not its own neighbour.
    for port in 1..=500u16 {
        assert_eq!(watch.attempt("93.184.216.34", port, T), None);
        assert_eq!(watch.attempt("127.0.0.1", port, T), None);
    }
}

#[test]
fn only_the_first_packet_of_an_attempt_is_read_and_only_its_sender_and_port() {
    // An IPv4 header of twenty bytes, then the start of a TCP header.
    let packet = |flags: u8, protocol: u8, piece: u16| {
        let mut data = vec![0u8; 40];
        data[0] = 0x45;
        data[6..8].copy_from_slice(&piece.to_be_bytes());
        data[9] = protocol;
        data[12..16].copy_from_slice(&[192, 168, 1, 30]);
        data[16..20].copy_from_slice(&[192, 168, 1, 5]);
        data[20..22].copy_from_slice(&51000u16.to_be_bytes());
        data[22..24].copy_from_slice(&8443u16.to_be_bytes());
        data[33] = flags;
        data
    };
    assert_eq!(opening(&packet(0x02, 6, 0)), Some(("192.168.1.30".to_string(), 8443)));
    assert_eq!(opening(&packet(0x12, 6, 0)), None, "an answer to this machine's own attempt");
    assert_eq!(opening(&packet(0x10, 6, 0)), None, "a packet of a connection that is already open");
    assert_eq!(opening(&packet(0x02, 17, 0)), None, "not TCP");
    assert_eq!(opening(&packet(0x02, 6, 0x00b9)), None, "a later piece of a split packet");
    assert_eq!(opening(&packet(0x02, 6, 0)[..30]), None, "cut short");
    assert_eq!(opening(&[]), None);
    let mut longer = packet(0x02, 6, 0);
    longer[0] = 0x46; // a header with options: four bytes more
    longer.splice(20..20, [0u8; 4]);
    assert_eq!(opening(&longer), Some(("192.168.1.30".to_string(), 8443)));
}
