# Finding devices

## mDNS

Devices announce themselves with DNS-SD over multicast DNS:

| Type | `AdbServiceType` | When |
| --- | --- | --- |
| `_adb._tcp` | `connect` | Classic network debugging is on (port 5555 usually) |
| `_adb-tls-connect._tcp` | `tlsConnect` | Wireless debugging is on (Android 11+) |
| `_adb-tls-pairing._tcp` | `tlsPairing` | The pairing screen is open |

```dart
final sub = AdbMdnsBrowser().browse(AdbServiceType.all).listen((event) {
  switch (event) {
    case AdbServiceFound(:final service):
      print('${service.serial} at ${service.address}:${service.port}');
    case AdbServiceUpdated(:final service):
      print('${service.instance} now on port ${service.port}');
    case AdbServiceLost(:final service):
      print('${service.instance} left');
  }
});
```

`AdbService` carries the instance name and its parts (`adb-<serial>-<suffix>`: `serial`, `suffix`), the port, the host name, the addresses (IPv4 and routable first, loopback last) and the TXT pairs. The serial identifies a device across address changes; the suffix changes with each announcement.

`AdbMdnsBrowser` shares port 5353 with the system's responder and hears announcements and goodbyes, so a device that turns debugging off is lost within about two seconds (a goodbye takes effect after a second, per RFC 6762). Where it cannot share the port it asks from a port of its own and notices a departure when the records expire (within about ten seconds then, as such answers live 10 s). It asks again at 1, 2, 4 … 60 s, refreshes records at 80 % and 90 % of their lifetime, resolves what is missing (SRV, TXT, addresses) without asking the same question more than once a second, and reports changes a tenth of a second after the packets of one announcement (a host answers once per network interface).

It keeps only the records of the types it browses (their instances and hosts), at most 1024 of them and none longer than 75 minutes, so a busy or hostile network cannot grow it. Malformed packets are ignored. IPv4 only: questions leave through the system's default multicast interface, and IPv6 addresses arrive when a device announces them over IPv4. Types match without case.

Platform notes:

- **Android:** hold a `WifiManager.MulticastLock` while browsing, or many Wi-Fi drivers drop multicast.
- **iOS:** raw multicast needs Apple's multicast entitlement. Use `NWBrowser` (with `NSBonjourServices` and the Local Network permission) and hand its results over through `AdbServiceBrowser`; `example/platform_browser.dart` shows an adapter.

## QR pairing

`browser.pairingServices()` turns any `AdbServiceBrowser` into the stream `AdbPairingQr.pair` waits on:

```dart
final qr = AdbPairingQr.random();
showQrCode(qr.text);
final paired = await qr.pair(services: AdbMdnsBrowser().pairingServices(), key: key);
```

## Scanning

Some devices do not announce (many TVs with classic network debugging). `AdbProbe.scan` probes many addresses at once, at most `concurrency` connections together, and reports those where adbd answers:

```dart
final targets = [for (var i = 1; i < 255; i++) ('192.168.0.$i', 5555)];
await for (final hit in AdbProbe.scan(targets, timeout: const Duration(milliseconds: 800))) {
  print('${hit.host}: ${hit.endpoint.kind}');
}
```

A probe sends `CNXN` and reads one header; it never sends a key, so no device shows "Allow debugging?". Which addresses to try, and whether to scan at all, is the app's decision.
