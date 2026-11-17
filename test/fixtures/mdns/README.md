# mDNS packets

- `avahi_legacy_answer.bin`: Avahi 0.8's answer to a legacy unicast PTR query (from a port other than 5353) for `_adbdirect-test._tcp.local`, recorded on 2026-11-17 with `tool/mdns_publish.py` publishing `adb-TESTSERIAL01-AbC123` on port 40123 with TXT `v=1`. The host name label was replaced by `h` repeated to the same length and the IPv4 address by 192.168.0.20, so offsets and compression pointers are untouched. Legacy answers echo the question and cap TTLs at 10 s.
