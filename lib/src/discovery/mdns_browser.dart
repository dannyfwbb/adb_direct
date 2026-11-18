// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import 'adb_service.dart';
import 'dns_message.dart';

/// How mDNS packets come and go. Internal: tests replace it.
@internal
abstract interface class MdnsTransport {
  /// Starts receiving; [onPacket] gets every datagram from port 5353 and who sent it; [onError] a failure of the
  /// socket.
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  );

  /// Sends a query to the mDNS group.
  void send(Uint8List packet);

  /// Whether it hears multicast (announcements and goodbyes), or only the unicast answers to its own queries.
  bool get hearsMulticast;

  /// Joins the group on interfaces that came up since the last call.
  Future<void> refreshInterfaces();

  /// Stops.
  Future<void> close();
}

/// A DNS-SD browser on `dart:io` multicast (RFC 6762, 6763): desktop and Android.
///
/// It listens on port 5353 next to the system's responder (sharing the port) and hears announcements and goodbyes;
/// where the port cannot be shared it falls back to asking from a port of its own, and then notices a device leaving
/// only when its records expire. It asks again at growing intervals (1 s, 2 s, 4 s, … up to [maxQueryInterval]),
/// refreshes records at 80 % and 90 % of their TTL, resolves what a PTR names (SRV, TXT, addresses), and keeps only
/// records that belong to the browsed types.
///
/// IPv4 only; queries leave through the system's default multicast interface. On Android the app must hold a
/// `WifiManager.MulticastLock` while browsing, or Wi-Fi drivers drop multicast. On iOS raw multicast needs an
/// entitlement: use a platform browser through [AdbServiceBrowser] instead.
final class AdbMdnsBrowser implements AdbServiceBrowser {
  /// Creates a browser.
  AdbMdnsBrowser({
    this.maxQueryInterval = const Duration(seconds: 60),
    AdbClock clock = AdbClock.system,
    @visibleForTesting MdnsTransport? transport,
  }) : _clock = clock,
       _transport = transport;

  /// The longest pause between two rounds of questions.
  final Duration maxQueryInterval;

  final AdbClock _clock;
  final MdnsTransport? _transport;

  @override
  Stream<AdbServiceEvent> browse(List<String> types) {
    if (types.isEmpty) throw ArgumentError.value(types, 'types', 'is empty');
    late final _Session session;
    // Synchronous: events come from packet and timer callbacks, never from inside a caller's own call. Ends when the
    // subscriber cancels.
    // ignore: close_sinks
    final controller = StreamController<AdbServiceEvent>(
      sync: true,
      onListen: () => session.start(),
      onCancel: () => session.stop(),
    );
    session = _Session(
      types: {for (final t in types) _normalType(t)},
      transport: _transport ?? _IoTransport(),
      clock: _clock,
      maxInterval: maxQueryInterval,
      emit: controller.add,
      fail: controller.addError,
    );
    return controller.stream;
  }

  static String _normalType(String type) {
    var t = type.toLowerCase();
    while (t.endsWith('.')) {
      t = t.substring(0, t.length - 1);
    }
    return fullType(t);
  }
}

/// A cached record from one sender.
final class _Entry {
  _Entry(this.record, this.received, this.expires, this.from);

  final DnsRecord record;
  final Duration received;
  Duration expires;
  final String from;

  /// Refresh questions already sent for this lifetime (at 80 %, 90 %).
  int refreshes = 0;

  Duration get lifetime => Duration(seconds: record.ttl);
}

/// Bounds against a noisy or hostile network.
const int _maxEntries = 1024;
const int _maxTtl = 4500; // 75 minutes, Android's PTR TTL.

final class _Session {
  _Session({
    required this.types,
    required this.transport,
    required this.clock,
    required this.maxInterval,
    required this.emit,
    required this.fail,
  });

  final Set<String> types;
  final MdnsTransport transport;
  final AdbClock clock;
  final Duration maxInterval;
  final void Function(AdbServiceEvent) emit;
  final void Function(Object) fail;

  /// (lowercase name, type, data key, sender) → entry.
  final Map<(String, int, String, String), _Entry> _cache = {};

  /// Lowercase instance full name → service reported.
  final Map<String, AdbService> _reported = {};

  /// Question (lowercase name, type) → (when it may be asked again, gap).
  final Map<(String, int), (Duration, Duration)> _asked = {};

  Timer? _queryTimer;
  Timer? _tick;
  Timer? _reportTimer;
  Duration _interval = const Duration(seconds: 1);
  bool _stopped = false;
  int _ticks = 0;

  /// Legacy answers live 10 s: ask at least this often then.
  static const Duration _legacyCap = Duration(seconds: 5);

  Duration get _cap => transport.hearsMulticast || maxInterval <= _legacyCap ? maxInterval : _legacyCap;

  Future<void> start() async {
    try {
      await transport.start(_onPacket, _onError);
    } on Object catch (e) {
      fail(e);
      return;
    }
    if (_stopped) {
      // Cancelled while the socket was being bound.
      await transport.close();
      return;
    }
    _round();
    _scheduleTick();
  }

  Future<void> stop() async {
    _stopped = true;
    _queryTimer?.cancel();
    _tick?.cancel();
    _reportTimer?.cancel();
    await transport.close();
  }

  void _onError(Object error) {
    if (!_stopped) fail(error);
  }

  void _scheduleTick() {
    _tick = clock.timer(const Duration(seconds: 1), () {
      if (_stopped) return;
      _maintain();
      if (++_ticks % 30 == 0) {
        transport.refreshInterfaces().then((_) {}, onError: _onError).ignore();
      }
      _scheduleTick();
    });
  }

  /// One round of PTR questions, then the next one later.
  void _round() {
    if (_stopped) return;
    _send([for (final t in types) DnsQuestion(t, DnsType.ptr)]);
    final wait = _interval;
    _interval = _interval * 2 > _cap ? _cap : _interval * 2;
    _queryTimer = clock.timer(wait, _round);
  }

  void _send(List<DnsQuestion> questions) {
    if (questions.isEmpty || _stopped) return;
    try {
      transport.send(DnsMessage.query(questions));
    } on Object {
      // A network that went away; the next round tries again.
    }
  }

  /// A question unless it was asked recently; each repeat waits twice as long, up to a minute (RFC 6762 5.2).
  DnsQuestion? _limited(String name, int type) {
    final now = clock.elapsed;
    final key = (name.toLowerCase(), type);
    final (next, gap) = _asked[key] ?? (Duration.zero, Duration.zero);
    if (now < next) return null;
    final newGap = gap == Duration.zero
        ? const Duration(seconds: 1)
        : (gap * 2 > const Duration(seconds: 60) ? const Duration(seconds: 60) : gap * 2);
    _asked[key] = (now + newGap, newGap);
    return DnsQuestion(name, type);
  }

  /// SRV/TXT of instances without an SRV, addresses of targets without one, each rate-limited.
  List<DnsQuestion> _missing() {
    final questions = <DnsQuestion>[];
    for (final instance in _instances()) {
      final srv = _srv(instance);
      if (srv == null) {
        questions.addAll([?_limited(instance, DnsType.srv), ?_limited(instance, DnsType.txt)]);
      } else if (_addresses(srv.target).isEmpty) {
        questions.addAll([?_limited(srv.target, DnsType.a), ?_limited(srv.target, DnsType.aaaa)]);
      }
    }
    // Forget limits for what is no longer asked.
    if (_asked.length > 4 * _maxEntries) _asked.clear();
    return questions;
  }

  void _onPacket(Uint8List packet, InternetAddress from) {
    if (_stopped) return;
    final DnsMessage message;
    try {
      message = DnsMessage.decode(packet);
    } on FormatException {
      return; // Somebody's malformed packet: not ours to fail on.
    }
    if (!message.isResponse || message.answers.isEmpty) return;
    final now = clock.elapsed;
    final sender = from.address;

    // Only what belongs to the browsed types: their PTRs, the instances those name (in the cache or in this packet),
    // and the hosts their SRVs name. Everything else on the network is ignored.
    final answers = message.answers;
    final instances = {
      ..._instances().map((i) => i.toLowerCase()),
      for (final r in answers)
        if (r.type == DnsType.ptr && types.contains(r.name.toLowerCase())) (r.data as String).toLowerCase(),
    };
    final hosts = {
      for (final e in _cache.values)
        if (e.record.type == DnsType.srv) (e.record.data as DnsSrv).target.toLowerCase(),
      for (final r in answers)
        if (r.type == DnsType.srv && instances.contains(r.name.toLowerCase())) (r.data as DnsSrv).target.toLowerCase(),
    };
    bool relevant(DnsRecord r) => switch (r.type) {
      DnsType.ptr => types.contains(r.name.toLowerCase()),
      DnsType.srv || DnsType.txt => instances.contains(r.name.toLowerCase()),
      DnsType.a || DnsType.aaaa => hosts.contains(r.name.toLowerCase()),
      _ => false,
    };

    var changed = false;
    // Cache-flush: the bit replaces the older records of the set from the same sender that are more than a second old
    // (RFC 6762 10.2).
    for (final r in answers) {
      if (!r.cacheFlush || r.ttl == 0 || !relevant(r)) continue;
      final name = r.name.toLowerCase();
      final before = _cache.length;
      _cache.removeWhere(
        (key, e) =>
            key.$1 == name && key.$2 == r.type && e.from == sender && e.received < now - const Duration(seconds: 1),
      );
      changed |= _cache.length != before;
    }
    for (final r in answers) {
      if (!relevant(r)) continue;
      final key = (r.name.toLowerCase(), r.type, _dataKey(r), sender);
      if (r.ttl == 0) {
        // A goodbye: this sender's record goes in a second (RFC 6762 10.1); the same record from another interface
        // stays.
        final entry = _cache[key];
        if (entry != null) {
          entry
            ..expires = now + const Duration(seconds: 1)
            ..refreshes = 2;
        }
        continue;
      }
      final ttl = r.ttl > _maxTtl ? _maxTtl : r.ttl;
      final record = ttl == r.ttl
          ? r
          : DnsRecord(name: r.name, type: r.type, ttl: ttl, cacheFlush: r.cacheFlush, data: r.data);
      _cache[key] = _Entry(record, now, now + Duration(seconds: ttl), sender);
      changed = true;
    }
    _bound();
    if (changed) _scheduleReport();
    _send(_missing());
  }

  /// Drops the oldest entries beyond the bound.
  void _bound() {
    if (_cache.length <= _maxEntries) return;
    final oldest = _cache.entries.toList()..sort((a, b) => a.value.received.compareTo(b.value.received));
    for (final e in oldest.take(_cache.length - _maxEntries)) {
      _cache.remove(e.key);
    }
  }

  /// Once a second: expiry, refresh questions at 80 % and 90 % of a record's TTL (RFC 6762 5.2), questions for what is
  /// still missing.
  void _maintain() {
    final now = clock.elapsed;
    final before = _cache.length;
    _cache.removeWhere((_, e) => e.expires <= now);
    final refresh = <DnsQuestion>[];
    final asked = <(String, int)>{};
    for (final e in _cache.values) {
      final age = now - e.received;
      final due = switch (e.refreshes) {
        0 => e.lifetime * 0.8,
        1 => e.lifetime * 0.9,
        _ => null,
      };
      if (due == null || age < due) continue;
      e.refreshes++;
      final name = e.record.name;
      if (asked.add((name.toLowerCase(), e.record.type))) {
        refresh.add(DnsQuestion(name, e.record.type));
      }
    }
    _send(refresh);
    _send(_missing());
    if (_cache.length != before) _scheduleReport();
  }

  /// Reports a little later, so the records of one announcement (often several packets, one per interface) arrive
  /// together.
  void _scheduleReport() {
    _reportTimer ??= clock.timer(const Duration(milliseconds: 100), () {
      _reportTimer = null;
      if (!_stopped) _report();
    });
  }

  Iterable<String> _instances() sync* {
    final seen = <String>{};
    for (final e in _cache.values) {
      final r = e.record;
      if (r.type == DnsType.ptr && types.contains(r.name.toLowerCase())) {
        final instance = r.data as String;
        if (seen.add(instance.toLowerCase())) yield instance;
      }
    }
  }

  /// The newest record of [type] for [name].
  _Entry? _newest(String name, int type) {
    _Entry? newest;
    final lower = name.toLowerCase();
    for (final e in _cache.values) {
      if (e.record.type == type &&
          e.record.name.toLowerCase() == lower &&
          (newest == null || e.received >= newest.received)) {
        newest = e;
      }
    }
    return newest;
  }

  DnsSrv? _srv(String instance) => _newest(instance, DnsType.srv)?.record.data as DnsSrv?;

  /// The host's addresses, most useful first: IPv4 before IPv6, routable before link-local, loopback last; no
  /// duplicates.
  List<InternetAddress> _addresses(String host) {
    final lower = host.toLowerCase();
    final found = {
      for (final e in _cache.values)
        if ((e.record.type == DnsType.a || e.record.type == DnsType.aaaa) && e.record.name.toLowerCase() == lower)
          e.record.data as InternetAddress,
    }.toList();
    int rank(InternetAddress a) =>
        (a.isLoopback ? 4 : 0) + (a.isLinkLocal ? 2 : 0) + (a.type == InternetAddressType.IPv4 ? 0 : 1);
    found.sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.address.compareTo(b.address));
    return found;
  }

  /// The pairs of the newest TXT record (RFC 6763 6.4: keys compare without case, the first occurrence wins, an empty
  /// key is ignored).
  Map<String, String> _txt(String instance) {
    final strings = _newest(instance, DnsType.txt)?.record.data as List<String>? ?? const [];
    final txt = <String, String>{};
    for (final s in strings) {
      final eq = s.indexOf('=');
      final key = (eq < 0 ? s : s.substring(0, eq)).toLowerCase();
      if (key.isEmpty || txt.containsKey(key)) continue;
      txt[key] = eq < 0 ? '' : s.substring(eq + 1);
    }
    return txt;
  }

  /// Compares what the cache says now with what was reported.
  void _report() {
    final now = <String, AdbService>{};
    for (final e in _cache.values) {
      final r = e.record;
      if (r.type != DnsType.ptr || !types.contains(r.name.toLowerCase())) {
        continue;
      }
      final instanceFull = r.data as String;
      if (now.containsKey(instanceFull.toLowerCase())) continue;
      final srv = _srv(instanceFull);
      if (srv == null) continue;
      final addresses = _addresses(srv.target);
      if (addresses.isEmpty) continue;
      final type = r.name.toLowerCase();
      final suffix = '.$type';
      final instance = instanceFull.toLowerCase().endsWith(suffix)
          ? instanceFull.substring(0, instanceFull.length - suffix.length)
          : instanceFull;
      now[instanceFull.toLowerCase()] = AdbService(
        type: type.substring(0, type.length - '.local'.length),
        instance: instance,
        port: srv.port,
        host: srv.target,
        addresses: addresses,
        txt: _txt(instanceFull),
      );
    }
    for (final MapEntry(:key, :value) in now.entries) {
      final before = _reported[key];
      if (before == null) {
        emit(AdbServiceFound(value));
      } else if (!before.sameAs(value)) {
        emit(AdbServiceUpdated(value));
      }
    }
    for (final MapEntry(:key, :value) in _reported.entries) {
      if (!now.containsKey(key)) emit(AdbServiceLost(value));
    }
    _reported
      ..clear()
      ..addAll(now);
  }

  static String _dataKey(DnsRecord r) => switch (r.data) {
    final String s => s.toLowerCase(),
    final DnsSrv s => '${s.target.toLowerCase()}:${s.port}',
    final List<String> l => l.join('\u0000'),
    final InternetAddress a => a.address,
    final Object o => o.toString(),
  };
}

/// mDNS over `dart:io`: port 5353 shared with the system responder when possible, else a port of its own (legacy
/// unicast answers, RFC 6762 6.7).
final class _IoTransport implements MdnsTransport {
  static final InternetAddress _group = InternetAddress('224.0.0.251');
  RawDatagramSocket? _socket;
  bool _multicast = false;
  final Set<String> _joined = {};

  @override
  bool get hearsMulticast => _multicast;

  @override
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  ) async {
    RawDatagramSocket? shared;
    try {
      shared = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5353, reusePort: !Platform.isWindows);
      _socket = shared;
      _multicast = true;
      await refreshInterfaces();
      if (_joined.isEmpty) shared.joinMulticast(_group);
    } on SocketException {
      shared?.close();
      _joined.clear();
      _multicast = false;
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    final socket = _socket!..multicastLoopback = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final datagram = socket.receive();
        if (datagram == null) break;
        // Responses come from port 5353 (RFC 6762 6).
        if (datagram.port != 5353) continue;
        try {
          onPacket(datagram.data, datagram.address);
        } on Object catch (e) {
          // A packet's problems never end the isolate.
          onError(e);
        }
      }
    }, onError: onError);
  }

  @override
  Future<void> refreshInterfaces() async {
    final socket = _socket;
    if (socket == null || !_multicast) return;
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (_joined.contains(nic.name)) continue;
      try {
        socket.joinMulticast(_group, nic);
        _joined.add(nic.name);
      } on SocketException {
        // An interface without multicast.
      }
    }
  }

  @override
  void send(Uint8List packet) => _socket?.send(packet, _group, 5353);

  @override
  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }
}
